// save_skill / run_skill / list_skills / delete_skill — the teach/replay
// surface. An agent performs a task once, saves it as a skill (element ids
// are frozen into durable locators at save time), and from then on run_skill
// replays it at engine speed through the normal dispatch funnel: every
// safety gate applies per step, and a failing step returns a structured
// report the agent can repair with one save_skill call.

import Foundation
import MCP

func performSkillMutation<T>(_ primitive: () throws -> T) throws -> T {
    try checkCancellationBeforeDelivery()
    return try primitive()
}

func successfulSkillMutationResult(_ text: String, summary: String) -> CallTool.Result {
    CallTool.Result.text(text)
        .withActionOutcome(.success(summary).withDispatchSucceeded(true))
        .withCommittedEvidence()
}

// MARK: - save_skill

func saveSkillImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let name = try args.requireString("name")
    let description = try args.requireString("description")
    let appName = try args.requireString("app")
    let overwrite = args.bool("overwrite") == true
    if SkillStore.exists(name), !overwrite {
        throw ToolError.invalidArguments(
            "A skill named \"\(name)\" already exists. Pass overwrite:true to replace it.")
    }

    var params: [SkillParam] = []
    if case .array(let rawParams)? = args["params"] {
        for raw in rawParams {
            guard case .object(let fields) = raw,
                let paramName = fields["name"]?.stringValue
            else {
                throw ToolError.invalidArguments("Each param needs {\"name\": …, \"description\": …}.")
            }
            params.append(SkillParam(name: paramName, description: fields["description"]?.stringValue ?? ""))
        }
    }

    guard case .array(let rawSteps)? = args["steps"] else {
        throw ToolError.invalidArguments("\"steps\" (array of {\"tool\": …, …} objects) is required.")
    }

    // Element ids are frozen only from a fresh, full-window, unwindowed tree,
    // so uniqueness is not inferred from a scoped or truncated view.
    var latest: AppSnapshot?
    let needsElementFreeze = rawSteps.contains { raw in
        guard case .object(let fields) = raw else { return false }
        return fields["element_id"]?.stringValue != nil
    }
    if needsElementFreeze {
        let resolvedApp = try resolveApp(appName)
        try await refreshSkillSnapshot(app: resolvedApp)
        latest = await SnapshotStore.shared.load(forPid: resolvedApp.pid)
        guard let latest, latest.scoped != true, latest.effectiveCoverage.isComplete else {
            throw ToolError.failed(
                "Could not build a complete full-window tree to prove saved-skill anchor "
                    + "uniqueness. Retry after the app settles.")
        }
    }

    var steps: [SkillStep] = []
    for (index, raw) in rawSteps.enumerated() {
        guard case .object(var fields) = raw else {
            throw ToolError.invalidArguments("steps[\(index)] must be an object with a \"tool\" key.")
        }
        guard let tool = fields.removeValue(forKey: "tool")?.stringValue else {
            throw ToolError.invalidArguments("steps[\(index)] is missing \"tool\".")
        }
        fields.removeValue(forKey: "app")  // the skill's app applies to every step

        var locator: SkillLocator?
        if let elementID = fields.removeValue(forKey: "element_id")?.stringValue {
            guard let latest, let element = latest.element(withID: elementID) else {
                throw ToolError.invalidArguments(
                    "steps[\(index)]: element_id \"\(elementID)\" is not in the latest \(appName) state. "
                        + "Call get_app_state and use current ids, or provide a locator {role, label} instead.")
            }
            let frozen = SkillLocator(
                role: element.role, label: element.fingerprint.stableLabel ?? element.label)
            switch resolveSkillLocator(frozen, in: latest) {
            case .found(let match) where match.id == element.id:
                locator = frozen
            case .found:
                throw ToolError.invalidArguments(
                    "steps[\(index)]: element_id \"\(elementID)\" does not freeze to its own unique "
                        + "role+label anchor. Use a different target.")
            case .failed(let reason):
                throw ToolError.invalidArguments(
                    "steps[\(index)]: element_id \"\(elementID)\" cannot be saved safely: \(reason).")
            }
        } else if case .object(let rawLocator)? = fields.removeValue(forKey: "locator") {
            guard let role = rawLocator["role"]?.stringValue else {
                throw ToolError.invalidArguments("steps[\(index)]: a locator needs at least {\"role\": …}.")
            }
            locator = SkillLocator(role: role, label: rawLocator["label"]?.stringValue)
        }

        var expect: SkillExpectation?
        if case .object(let rawExpect)? = fields.removeValue(forKey: "expect") {
            expect = SkillExpectation(
                role: rawExpect["role"]?.stringValue,
                label: rawExpect["label"]?.stringValue,
                valueContains: rawExpect["value_contains"]?.stringValue,
                gone: rawExpect["gone"]?.boolValue,
                timeoutSeconds: rawExpect["timeout_seconds"]?.doubleValue
            )
        }

        steps.append(SkillStep(tool: tool, locator: locator, arguments: fields, expect: expect))
    }

    let skill = Skill(
        name: name, description: description, app: appName,
        params: params, steps: steps, updatedAt: Date()
    )
    do {
        try performSkillMutation { try SkillStore.save(skill) }
    } catch let error as SkillValidationError {
        throw ToolError.invalidArguments(error.description)
    }
    let paramNote = params.isEmpty
        ? "" : " Params: \(params.map { "{{\($0.name)}}" }.joined(separator: ", "))."
    return successfulSkillMutationResult(
        "Saved skill \"\(name)\" (\(steps.count) step(s), app \(appName)).\(paramNote) "
            + "Run it with run_skill.",
        summary: "Skill saved.")
}

// MARK: - run_skill

func runSkillImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let name = try args.requireString("name")
    let skill = try SkillStore.load(name)
    var compositeDefinitelyCommitted = CompositeCommitContext.priorMutationCommitted
    var compositeCommitUnknown = false
    var hasCompositeCommitEvidence: Bool {
        compositeDefinitelyCommitted || compositeCommitUnknown
    }
    func compositeError(_ message: String) -> CallTool.Result {
        let result = CallTool.Result.text(message, isError: true)
        return applyingCompositeCommitEvidence(
            to: result,
            definitePriorCommit: compositeDefinitelyCommitted,
            ambiguousCommit: compositeCommitUnknown)
    }
    // Launch the target app in the BACKGROUND when it is not running, instead
    // of failing — a hard failure here taught agents to "fix" it with
    // open_app activate:true and steal the user's focus. The launch keeps
    // open_app's confirm gate: an unconfirmed run gets a recoverable error.
    var app: ResolvedApp
    do {
        app = try resolveApp(skill.app)
    } catch {
        guard SafetyPolicy.confirmed(args) || !SafetyPolicy.isEnabled else {
            throw SafetyError(
                reason: "\"\(skill.app)\" is not running; run_skill will launch it in the "
                    + "background (no focus change).")
        }
        let launch = await dispatchTool(
            name: "open_app", arguments: ["app": .string(skill.app), "confirm": .bool(true)])
        if launch.isError == true {
            throw ToolError.failed(
                "Skill \"\(name)\" could not launch \(skill.app): " + batchResultText(launch))
        }
        compositeDefinitelyCommitted = true
        // The running-apps scan is cached ~1s, so a resolve right after launch
        // can still miss the new process; retry briefly until it registers.
        let deadline = Date().addingTimeInterval(5)
        while true {
            if let resolved = try? resolveApp(skill.app) {
                app = resolved
                break
            }
            guard Date() < deadline else {
                return compositeError(
                    "Skill \"\(name)\" launched \(skill.app) but it did not become controllable in time.")
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }
    do {
        try requireAccessibilityTrusted()
        try requireAppAlive(app)
    } catch {
        if hasCompositeCommitEvidence {
            return compositeError("\(error)")
        }
        throw error
    }

    var provided: [String: String] = [:]
    if case .object(let rawParams)? = args["params"] {
        for (key, value) in rawParams {
            provided[key] = value.stringValue
                ?? value.intValue.map(String.init)
                ?? value.doubleValue.map { String($0) }
                ?? ""
        }
    }
    let missing = skill.params.map(\.name).filter { provided[$0] == nil }
    guard missing.isEmpty else {
        let described = skill.params.map { "\($0.name) (\($0.description))" }.joined(separator: "; ")
        if hasCompositeCommitEvidence {
            return compositeError(
                "Skill \"\(name)\" needs params: \(missing.joined(separator: ", ")). "
                    + "All params: \(described).")
        }
        throw ToolError.invalidArguments(
            "Skill \"\(name)\" needs params: \(missing.joined(separator: ", ")). All params: \(described).")
    }

    let startAtStep = args.integer("start_at_step") ?? 1
    guard startAtStep >= 1, startAtStep <= skill.steps.count else {
        if hasCompositeCommitEvidence {
            return compositeError(
                "start_at_step must be between 1 and \(skill.steps.count) for \"\(name)\".")
        }
        throw ToolError.invalidArguments(
            "start_at_step must be between 1 and \(skill.steps.count) for \"\(name)\".")
    }

    // Locators resolve against the latest snapshot; make sure one exists.
    do {
        try await refreshSkillSnapshot(app: app)
    } catch {
        if hasCompositeCommitEvidence {
            return compositeError("\(error)")
        }
        throw error
    }

    var replayRecorder = ReplayVerdictRecorder(skill: skill, startAtStep: startAtStep)
    var summary: [String] =
        startAtStep > 1 ? ["(steps 1-\(startAtStep - 1) skipped via start_at_step)"] : []
    func failure(
        step: Int,
        tool: String,
        reason: String,
        failureKind: ReplayFailureKind,
        result: CallTool.Result? = nil
    ) -> CallTool.Result {
        replayRecorder.recordFailure(
            step: step,
            result: result,
            reason: reason,
            failureKind: failureKind
        )
        var text = "Skill \"\(name)\" stopped at step \(step) of \(skill.steps.count) (\(tool)): \(reason)\n"
        text += replayFailureGuidance(
            name: name, app: skill.app, step: step, completedSteps: summary,
            currentLeafEvidence: result.map(leafCommitEvidence) ?? .none)
        var failed = CallTool.Result.text(text, isError: true)
        if let result {
            failed._meta = result._meta
        }
        let withVerdict = failed.withReplayVerdict(replayRecorder.verdict)
        return applyingCompositeCommitEvidence(
            to: withVerdict,
            definitePriorCommit: compositeDefinitelyCommitted,
            ambiguousCommit: compositeCommitUnknown)
    }

    let steps = skill.steps
    var extracts: [String] = []
    var lastResult: CallTool.Result?
    for (index, step) in steps.enumerated() where index + 1 >= startAtStep {
        var arguments = step.arguments.mapValues { substituteParams($0, params: provided) }
        let leftover = arguments.values.flatMap(unresolvedPlaceholders)
        guard leftover.isEmpty else {
            return failure(
                step: index + 1, tool: step.tool,
                reason: "unresolved placeholders \(Set(leftover).sorted().map { "{{\($0)}}" }.joined(separator: ", ")) — pass them in params",
                failureKind: .arguments
            )
        }
        arguments["app"] = .string(skill.app)
        arguments["include_screenshot"] = .bool(false)

        if let locator = step.locator {
            guard let snapshot = await SnapshotStore.shared.load(forPid: app.pid) else {
                return failure(
                    step: index + 1,
                    tool: step.tool,
                    reason: "no app state available for locator resolution",
                    failureKind: .locator
                )
            }
            switch resolveSkillLocator(locator, in: snapshot) {
            case .found(let element):
                arguments["element_id"] = .string(element.id)
            case .failed(let why):
                return failure(
                    step: index + 1,
                    tool: step.tool,
                    reason: why,
                    failureKind: .locator
                )
            }
        }

        let expectationArguments = step.expect.map {
            replayWaitArguments(for: $0, app: skill.app, params: provided)
        }
        var expectationWasUnmetBeforeStep = false
        if var expectationArguments {
            expectationArguments["timeout_seconds"] = .double(1)
            let beforeExpectation = await dispatchTool(name: "wait_for", arguments: expectationArguments)
            expectationWasUnmetBeforeStep = beforeExpectation.isError != true
                && replayExpectationTimedOut(beforeExpectation)
        }

        let result = await dispatchTool(name: step.tool, arguments: arguments)
        if result.isError == true {
            if isMutatingTool(step.tool) {
                switch leafCommitEvidence(result) {
                case .definite: compositeDefinitelyCommitted = true
                case .unknown: compositeCommitUnknown = true
                case .none: break
                }
            }
            return failure(
                step: index + 1,
                tool: step.tool,
                reason: batchResultText(result),
                failureKind: .toolError,
                result: result
            )
        }
        if isMutatingTool(step.tool) {
            switch leafCommitEvidence(result) {
            case .definite: compositeDefinitelyCommitted = true
            case .unknown: compositeCommitUnknown = true
            case .none: break
            }
        }
        if step.tool == "wait_for", replayExpectationTimedOut(result) {
            return failure(
                step: index + 1,
                tool: step.tool,
                reason: batchResultText(result),
                failureKind: .expectation,
                result: result
            )
        }

        let outcome = replayStepOutcome(from: result)
        let needsExpectationProof = outcome.map { $0.classification != .success }
            ?? isMutatingTool(step.tool)
        let canExpectationProveOutcome = needsExpectationProof
            && expectationArguments != nil
            && expectationWasUnmetBeforeStep
        if let outcome, replayOutcomeFailsBeforeExpectation(outcome, canExpectationProve: canExpectationProveOutcome) {
            return failure(
                step: index + 1,
                tool: step.tool,
                reason: outcome.summary ?? "step outcome was \(outcome.classification.rawValue)",
                failureKind: .outcome,
                result: result
            )
        }
        if outcome == nil, replayMissingOutcomeFails(tool: step.tool, canExpectationProve: canExpectationProveOutcome) {
            return failure(
                step: index + 1,
                tool: step.tool,
                reason: "step returned no verifier outcome; add an expect postcondition to prove it",
                failureKind: .outcome,
                result: result
            )
        }
        if step.tool == "read_text" {
            extracts.append("— step \(index + 1):\n" + batchResultText(result))
        }
        lastResult = result
        var replaySuccessResult = result

        if let waitArguments = expectationArguments {
            let waitResult = await dispatchTool(name: "wait_for", arguments: waitArguments)
            if waitResult.isError == true || replayExpectationTimedOut(waitResult) {
                let expectationFailure = replayExpectationFailureEvidence(
                    stepResult: result, waitResult: waitResult)
                return failure(
                    step: index + 1, tool: step.tool,
                    reason: "the step ran but its expectation was not met — " + batchResultText(waitResult),
                    failureKind: .expectation,
                    result: expectationFailure
                )
            }
            lastResult = waitResult
            if canExpectationProveOutcome {
                replaySuccessResult = waitResult
            }
        }
        replayRecorder.recordSuccess(step: index + 1, result: replaySuccessResult)
        summary.append("✓ step \(index + 1) \(step.tool)")
    }

    var header = "Skill \"\(name)\" completed \(skill.steps.count - startAtStep + 1) step(s):\n"
    header += summary.joined(separator: "\n") + "\n"
    if !extracts.isEmpty {
        header += "\nExtracted:\n" + extracts.joined(separator: "\n") + "\n"
    }
    header += "\nFinal state below.\n\n"
    guard let lastResult else {
        return CallTool.Result.text(header).withReplayVerdict(replayRecorder.verdict)
    }
    var content = lastResult.content
    if case .text(let existing, let annotations, let meta)? = content.first {
        content[0] = .text(text: header + existing, annotations: annotations, _meta: meta)
    } else {
        content.insert(.text(text: header, annotations: nil, _meta: nil), at: 0)
    }
    let completed = CallTool.Result(content: content, isError: lastResult.isError, _meta: lastResult._meta)
        .withReplayVerdict(replayRecorder.verdict)
    if compositeDefinitelyCommitted {
        return applyingSuccessfulCompositeCommitEvidence(
            to: completed, definiteCommit: true, ambiguousCommit: compositeCommitUnknown)
    }
    guard leafCommitEvidence(lastResult) == .none else { return completed }
    return applyingSuccessfulCompositeCommitEvidence(
        to: completed,
        definiteCommit: compositeDefinitelyCommitted,
        ambiguousCommit: compositeCommitUnknown)
}

func replayFailureGuidance(
    name: String,
    app: String,
    step: Int,
    completedSteps: [String],
    currentLeafEvidence: LeafCommitEvidence
) -> String {
    if currentLeafEvidence != .none {
        let commitment = currentLeafEvidence == .definite
            ? "reports that its mutation was delivered"
            : "may have delivered its mutation"
        var text = completedSteps.isEmpty
            ? "The current failing step \(commitment); its resulting app state must be reconciled.\n"
            : "Steps completed before the failure:\n" + completedSteps.joined(separator: "\n")
                + "\nThe current failing step \(commitment); its resulting app state must be reconciled.\n"
        text += "Call get_app_state on \(app), confirm what the current step changed, and only then "
            + "resume from the appropriate next step. Do not replay step \(step) until you have confirmed "
            + "that doing so will not duplicate its effect."
        return text
    }
    let prior = completedSteps.isEmpty
        ? "No earlier steps ran.\n"
        : "Steps already run:\n" + completedSteps.joined(separator: "\n") + "\n"
    return prior
        + "To repair: call get_skill \"\(name)\" for the saved definition and get_app_state on \(app) "
        + "for current state; fix this step, re-save with save_skill overwrite:true, then rerun with "
        + "start_at_step: \(step) to continue without redoing the earlier steps."
}

func replayExpectationTimedOut(_ result: CallTool.Result) -> Bool {
    batchResultText(result).hasPrefix("TIMED OUT after ")
}

func replayExpectationFailureEvidence(
    stepResult: CallTool.Result,
    waitResult: CallTool.Result
) -> CallTool.Result {
    switch leafCommitEvidence(stepResult) {
    case .definite:
        return waitResult.withCommittedEvidence()
    case .unknown:
        return waitResult.withUnknownCommitEvidence()
    case .none:
        return waitResult
    }
}

func replayOutcomeFailsBeforeExpectation(_ outcome: ReplayStepOutcome, canExpectationProve: Bool) -> Bool {
    outcome.classification == .unsupported || (outcome.classification != .success && !canExpectationProve)
}

func replayMissingOutcomeFails(tool: String, canExpectationProve: Bool) -> Bool {
    isMutatingTool(tool) && !canExpectationProve
}

func replayWaitArguments(
    for expectation: SkillExpectation,
    app: String,
    params: [String: String]
) -> [String: Value] {
    var arguments: [String: Value] = ["app": .string(app)]
    if let role = expectation.role { arguments["role"] = .string(role) }
    if let label = expectation.label {
        arguments["label"] = .string(substituteParams(in: label, params: params))
    }
    if let value = expectation.valueContains {
        arguments["value_contains"] = .string(substituteParams(in: value, params: params))
    }
    if expectation.gone == true { arguments["gone"] = .bool(true) }
    if let timeout = expectation.timeoutSeconds { arguments["timeout_seconds"] = .double(timeout) }
    return arguments
}

/// Capture a fresh snapshot for locator resolution (mirrors find's capture:
/// no screenshot, deep tree).
private func refreshSkillSnapshot(app: ResolvedApp) async throws {
    let window = try targetWindow(for: app, title: nil)
    let pixelsPerPoint = await SnapshotStore.shared.load(forPid: app.pid)
        .map(\.pixelsPerPoint).flatMap { $0 > 0 ? $0 : nil } ?? 1
    await AssistiveAccess.shared.enable(pid: app.pid)
    _ = await SnapshotStore.shared.capture(
        pid: app.pid,
        bundleIdentifier: app.bundleIdentifier,
        windowTitle: window.title,
        windowID: windowID(for: window.element),
        windowElement: window.element,
        windowOrigin: window.frame.origin,
        pixelsPerPoint: pixelsPerPoint,
        windowSize: [window.frame.width * pixelsPerPoint, window.frame.height * pixelsPerPoint],
        createdAt: Date()
    ) { generation in
        buildTree(
            window: window.element,
            windowOrigin: window.frame.origin,
            pixelsPerPoint: pixelsPerPoint,
            generation: generation,
            maxElements: 5000,
            // Skill locator resolution must see every element, not a viewport slice.
            windowCollections: false
        )
    }
}

// MARK: - get_skill / list_skills / delete_skill

func getSkillImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let name = try args.requireString("name")
    let skill = try SkillStore.load(name)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let json = String(data: try encoder.encode(skill), encoding: .utf8) ?? "{}"
    return .text(
        "Skill \"\(name)\" as saved (edit steps and re-save with save_skill overwrite:true):\n" + json)
}

func listSkillsImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let skills = SkillStore.list()
    guard !skills.isEmpty else {
        return .text("No skills saved yet. Perform a task once, then save it with save_skill.")
    }
    let lines = skills.map { skill in
        let params = skill.params.isEmpty
            ? "" : " — params: " + skill.params.map { "\($0.name) (\($0.description))" }.joined(separator: ", ")
        return "\(skill.name) [\(skill.app), \(skill.steps.count) steps]: \(skill.description)\(params)"
    }
    return .text("Saved skills:\n" + lines.joined(separator: "\n"))
}

func deleteSkillImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let name = try args.requireString("name")
    guard SafetyPolicy.confirmed(args) || !SafetyPolicy.isEnabled else {
        throw SafetyError(reason: "deleting skill \"\(name)\" is irreversible.")
    }
    try performSkillMutation { try SkillStore.delete(name) }
    return successfulSkillMutationResult("Deleted skill \"\(name)\".", summary: "Skill deleted.")
}

// MARK: - record_skill_start / record_skill_stop (teach mode)

func recordSkillStartImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    do {
        try performSkillMutation { try SkillRecorder.shared.start(app: app) }
    } catch let error as RecorderError {
        throw ToolError.failed(error.description)
    }
    await AgentCursor.shared.setRecording(true)
    return successfulSkillMutationResult(
        "Recording your actions in \(app.name). Demonstrate the task now — clicks, typing, "
            + "and shortcuts are captured; recording pauses automatically during password entry. "
            + "Call record_skill_stop when done to get the draft steps, then save_skill.",
        summary: "Skill recording started.")
}

func recordSkillStopImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let result: (app: String, steps: [SkillStep])
    do {
        result = try performSkillMutation { try SkillRecorder.shared.stop() }
    } catch let error as RecorderError {
        throw ToolError.failed(error.description)
    }
    await AgentCursor.shared.setRecording(false)

    guard !result.steps.isEmpty else {
        return successfulSkillMutationResult(
            "Recording stopped — no actions were captured in \(result.app). Nothing to save.",
            summary: "Skill recording stopped.")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let stepsJSON = String(data: (try? encoder.encode(result.steps)) ?? Data(), encoding: .utf8) ?? "[]"
    return successfulSkillMutationResult(
        "Recorded \(result.steps.count) step(s) in \(result.app). Review and refine these "
            + "(add {{params}} for values that vary, drop stray clicks, add expect assertions), "
            + "then persist with save_skill:\n" + stepsJSON,
        summary: "Skill recording stopped.")
}
