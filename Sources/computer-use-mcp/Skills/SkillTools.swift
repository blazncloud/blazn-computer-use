// save_skill / run_skill / list_skills / delete_skill — the teach/replay
// surface. An agent performs a task once, saves it as a skill (element ids
// are frozen into durable locators at save time), and from then on run_skill
// replays it at engine speed through the normal dispatch funnel: every
// safety gate applies per step, and a failing step returns a structured
// report the agent can repair with one save_skill call.

import Foundation
import MCP

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

    // element_id anchors are frozen into durable locators against the app's
    // latest snapshot — ids expire, locators re-resolve.
    var latest: AppSnapshot?
    if let resolvedApp = try? resolveApp(appName) {
        latest = await SnapshotStore.shared.load(forPid: resolvedApp.pid)
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
            locator = SkillLocator(role: element.role, label: element.label, path: element.path)
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
        try SkillStore.save(skill)
    } catch let error as SkillValidationError {
        throw ToolError.invalidArguments(error.description)
    }
    let paramNote = params.isEmpty
        ? "" : " Params: \(params.map { "{{\($0.name)}}" }.joined(separator: ", "))."
    return .text(
        "Saved skill \"\(name)\" (\(steps.count) step(s), app \(appName)).\(paramNote) "
            + "Run it with run_skill.")
}

// MARK: - run_skill

func runSkillImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let name = try args.requireString("name")
    let skill = try SkillStore.load(name)
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
        // The running-apps scan is cached ~1s, so a resolve right after launch
        // can still miss the new process; retry briefly until it registers.
        let deadline = Date().addingTimeInterval(5)
        while true {
            if let resolved = try? resolveApp(skill.app) {
                app = resolved
                break
            }
            guard Date() < deadline else {
                throw ToolError.failed(
                    "Skill \"\(name)\" launched \(skill.app) but it did not become controllable in time.")
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }
    try requireAccessibilityTrusted()
    try requireAppAlive(app)

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
        throw ToolError.invalidArguments(
            "Skill \"\(name)\" needs params: \(missing.joined(separator: ", ")). All params: \(described).")
    }

    let startAtStep = args.integer("start_at_step") ?? 1
    guard startAtStep >= 1, startAtStep <= skill.steps.count else {
        throw ToolError.invalidArguments(
            "start_at_step must be between 1 and \(skill.steps.count) for \"\(name)\".")
    }

    // Locators resolve against the latest snapshot; make sure one exists.
    try await refreshSkillSnapshot(app: app)

    var summary: [String] =
        startAtStep > 1 ? ["(steps 1-\(startAtStep - 1) skipped via start_at_step)"] : []
    func failure(step: Int, tool: String, reason: String) -> CallTool.Result {
        var text = "Skill \"\(name)\" stopped at step \(step) of \(skill.steps.count) (\(tool)): \(reason)\n"
        text += summary.isEmpty
            ? "No earlier steps ran.\n" : "Steps already run:\n" + summary.joined(separator: "\n") + "\n"
        text +=
            "To repair: call get_skill \"\(name)\" for the saved definition and get_app_state on "
            + "\(skill.app) for current state; fix this step, re-save with save_skill "
            + "overwrite:true, then rerun with start_at_step: \(step) to continue without "
            + "redoing the earlier steps."
        return .text(text, isError: true)
    }

    var steps = skill.steps
    var healedSteps: [Int] = []
    var extracts: [String] = []
    var lastResult: CallTool.Result?
    for (index, step) in steps.enumerated() where index + 1 >= startAtStep {
        var arguments = step.arguments.mapValues { substituteParams($0, params: provided) }
        let leftover = arguments.values.flatMap(unresolvedPlaceholders)
        guard leftover.isEmpty else {
            return failure(
                step: index + 1, tool: step.tool,
                reason: "unresolved placeholders \(Set(leftover).sorted().map { "{{\($0)}}" }.joined(separator: ", ")) — pass them in params")
        }
        arguments["app"] = .string(skill.app)
        arguments["include_screenshot"] = .bool(false)

        if let locator = step.locator {
            guard let snapshot = await SnapshotStore.shared.load(forPid: app.pid) else {
                return failure(step: index + 1, tool: step.tool, reason: "no app state available for locator resolution")
            }
            switch resolveSkillLocator(locator, in: snapshot) {
            case .found(let element, let viaFallback):
                arguments["element_id"] = .string(element.id)
                if viaFallback {
                    // The element moved; remember its new address so future
                    // runs hit the fast, precise path again.
                    steps[index].locator?.path = element.path
                    healedSteps.append(index + 1)
                }
            case .failed(let why):
                return failure(step: index + 1, tool: step.tool, reason: why)
            }
        }

        let result = await dispatchTool(name: step.tool, arguments: arguments)
        if result.isError == true {
            return failure(step: index + 1, tool: step.tool, reason: batchResultText(result))
        }
        if step.tool == "read_text" {
            extracts.append("— step \(index + 1):\n" + batchResultText(result))
        }
        lastResult = result

        if let expect = step.expect {
            var waitArguments: [String: Value] = ["app": .string(skill.app)]
            if let role = expect.role { waitArguments["role"] = .string(role) }
            if let label = expect.label {
                waitArguments["label"] = .string(substituteParams(in: label, params: provided))
            }
            if let value = expect.valueContains {
                waitArguments["value_contains"] = .string(substituteParams(in: value, params: provided))
            }
            if expect.gone == true { waitArguments["gone"] = .bool(true) }
            if let timeout = expect.timeoutSeconds { waitArguments["timeout_seconds"] = .double(timeout) }
            let waitResult = await dispatchTool(name: "wait_for", arguments: waitArguments)
            if waitResult.isError == true {
                return failure(
                    step: index + 1, tool: step.tool,
                    reason: "the step ran but its expectation was not met — " + batchResultText(waitResult))
            }
            lastResult = waitResult
        }
        summary.append("✓ step \(index + 1) \(step.tool)")
    }

    // Persist healed locator paths (best-effort) so the skill tracks the
    // app's evolution without a repair round.
    if !healedSteps.isEmpty {
        try? SkillStore.save(
            Skill(
                name: skill.name, description: skill.description, app: skill.app,
                params: skill.params, steps: steps, updatedAt: Date()
            ))
    }

    var header = "Skill \"\(name)\" completed \(skill.steps.count - startAtStep + 1) step(s):\n"
    header += summary.joined(separator: "\n") + "\n"
    if !healedSteps.isEmpty {
        header +=
            "Self-healed the locator path of step(s) \(healedSteps.map(String.init).joined(separator: ", ")) "
            + "(element moved; new address saved).\n"
    }
    if !extracts.isEmpty {
        header += "\nExtracted:\n" + extracts.joined(separator: "\n") + "\n"
    }
    header += "\nFinal state below.\n\n"
    guard let lastResult else { return .text(header) }
    var content = lastResult.content
    if case .text(let existing, let annotations, let meta)? = content.first {
        content[0] = .text(text: header + existing, annotations: annotations, _meta: meta)
    } else {
        content.insert(.text(text: header, annotations: nil, _meta: nil), at: 0)
    }
    return CallTool.Result(content: content, isError: lastResult.isError, _meta: lastResult._meta)
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
            maxElements: 5000
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
    try SkillStore.delete(name)
    return .text("Deleted skill \"\(name)\".")
}

// MARK: - record_skill_start / record_skill_stop (teach mode)

func recordSkillStartImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    do {
        try SkillRecorder.shared.start(app: app)
    } catch let error as RecorderError {
        throw ToolError.failed(error.description)
    }
    await AgentCursor.shared.setRecording(true)
    return .text(
        "Recording your actions in \(app.name). Demonstrate the task now — clicks, typing, "
            + "and shortcuts are captured; recording pauses automatically during password entry. "
            + "Call record_skill_stop when done to get the draft steps, then save_skill.")
}

func recordSkillStopImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let result: (app: String, steps: [SkillStep])
    do {
        result = try SkillRecorder.shared.stop()
    } catch let error as RecorderError {
        throw ToolError.failed(error.description)
    }
    await AgentCursor.shared.setRecording(false)

    guard !result.steps.isEmpty else {
        return .text(
            "Recording stopped — no actions were captured in \(result.app). Nothing to save.")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let stepsJSON = String(data: (try? encoder.encode(result.steps)) ?? Data(), encoding: .utf8) ?? "[]"
    return .text(
        "Recorded \(result.steps.count) step(s) in \(result.app). Review and refine these "
            + "(add {{params}} for values that vary, drop stray clicks, add expect assertions), "
            + "then persist with save_skill:\n" + stepsJSON)
}
