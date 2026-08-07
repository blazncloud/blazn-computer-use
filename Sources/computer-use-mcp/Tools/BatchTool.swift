// batch — run a short sequence of actions against one app in a single call.
//
// Each step goes through the normal dispatch funnel, so every per-step
// guarantee holds: safety confirmation, interference yield, URL policy,
// element re-resolution. Intermediate steps skip state for speed; the final
// step returns fresh state (a compact diff when little changed). The batch
// stops at the first failing step — a stale element id is the built-in
// "the UI didn't do what I expected" brake — and reports what already ran.

import Foundation
import MCP

let maxBatchActions = 10

/// Tools a batch may contain: the app-scoped action set plus wait_for (for
/// sequences that trigger loading). Never batch itself, and nothing that
/// targets a different app — one app per batch keeps lease arbitration and
/// the URL/interference gates coherent.
let batchableToolNames: Set<String> = appScopedToolNames.subtracting(["batch", "run_skill"]).union(["wait_for"])
let batchIntermediateToolNames: Set<String> = [
    "type_text", "scroll", "set_value", "perform_secondary_action",
    "click_menu_item", "page", "manage_window", "wait_for",
]

func batchImpl(
    _ args: [String: Value],
    dispatcher: LocalToolDispatcher = dispatchTool
) async throws -> CallTool.Result {
    let appName = try args.requireString("app")
    guard case .array(let rawActions)? = args["actions"] else {
        throw ToolError.invalidArguments("\"actions\" (array of {\"tool\": …, …} objects) is required.")
    }
    guard !rawActions.isEmpty else {
        throw ToolError.invalidArguments("\"actions\" must contain at least one step.")
    }
    guard rawActions.count <= maxBatchActions else {
        throw ToolError.invalidArguments(
            "\"actions\" is limited to \(maxBatchActions) steps; split longer sequences.")
    }

    // Validate every step before running any: a typo in step 4 must not
    // leave steps 1-3 already performed.
    var steps: [(tool: String, arguments: [String: Value])] = []
    for (index, raw) in rawActions.enumerated() {
        guard case .object(let fields) = raw else {
            throw ToolError.invalidArguments("actions[\(index)] must be an object with a \"tool\" key.")
        }
        guard let tool = fields["tool"]?.stringValue else {
            throw ToolError.invalidArguments("actions[\(index)] is missing \"tool\".")
        }
        guard batchableToolNames.contains(tool) else {
            throw ToolError.invalidArguments(
                "actions[\(index)]: \"\(tool)\" cannot run in a batch. Allowed steps: "
                    + batchableToolNames.sorted().joined(separator: ", ") + ".")
        }
        if index < rawActions.count - 1, !batchIntermediateToolNames.contains(tool) {
            throw ToolError.invalidArguments(
                "actions[\(index)]: \"\(tool)\" cannot be an intermediate batch step because it "
                    + "does not emit structured success evidence. Put it last, or run the next "
                    + "dependent action in a separate call.")
        }
        var arguments = fields
        arguments["tool"] = nil
        arguments["app"] = .string(appName)
        steps.append((tool, arguments))
    }

    var summary: [String] = []
    var definitePriorCommit = false
    var ambiguousCommit = false
    func stopped(atStep step: Int, tool: String, error: String) -> CallTool.Result {
        batchStoppedResult(
            step: step, stepCount: steps.count, tool: tool, error: error,
            summary: summary, definitePriorCommit: definitePriorCommit,
            ambiguousCommit: ambiguousCommit
        )
    }

    for (index, step) in steps.dropLast().enumerated() {
        var arguments = step.arguments
        if isMutatingTool(step.tool) {
            // A dependent mutation may only advance after a structured
            // verifier success. Keep state recapture, but suppress the
            // intermediate screenshot to avoid needless payload cost.
            arguments["include_state"] = .bool(true)
            arguments["include_screenshot"] = .bool(false)
        } else {
            arguments["include_state"] = .bool(false)
        }
        let result = await dispatcher(step.tool, arguments)
        let text = batchResultText(result)
        if !leafResultSucceeded(result, isMutating: isMutatingTool(step.tool)) {
            if isMutatingTool(step.tool) {
                updateCompositeEvidence(
                    leafCommitEvidence(result),
                    definite: &definitePriorCommit,
                    ambiguous: &ambiguousCommit)
            }
            return stopped(atStep: index + 1, tool: step.tool, error: text)
        }
        if isMutatingTool(step.tool) {
            updateCompositeEvidence(
                leafCommitEvidence(result),
                definite: &definitePriorCommit,
                ambiguous: &ambiguousCommit)
        }
        summary.append("✓ step \(index + 1) \(step.tool): \(firstLine(text))")
    }

    let last = steps[steps.count - 1]
    var lastArguments = last.arguments
    if let includeScreenshot = args["include_screenshot"] {
        lastArguments["include_screenshot"] = includeScreenshot
    }
    let result = await dispatcher(last.tool, lastArguments)
    if !finalLeafResultAccepted(result) {
        if isMutatingTool(last.tool) {
            updateCompositeEvidence(
                leafCommitEvidence(result),
                definite: &definitePriorCommit,
                ambiguous: &ambiguousCommit)
        }
        return stopped(atStep: steps.count, tool: last.tool, error: batchResultText(result))
    }
    if isMutatingTool(last.tool) {
        updateCompositeEvidence(
            leafCommitEvidence(result),
            definite: &definitePriorCommit,
            ambiguous: &ambiguousCommit)
    }

    var header = "Batch completed \(steps.count) step(s):\n"
    header += summary.isEmpty ? "" : summary.joined(separator: "\n") + "\n"
    header += "✓ step \(steps.count) \(last.tool) — final state below.\n\n"
    var content = result.content
    if case .text(let existing, let annotations, let meta)? = content.first {
        content[0] = .text(text: header + existing, annotations: annotations, _meta: meta)
    } else {
        content.insert(.text(text: header, annotations: nil, _meta: nil), at: 0)
    }
    let completed = CallTool.Result(content: content, isError: result.isError, _meta: result._meta)
    // The final leaf's metadata describes only that leaf. Always merge prior
    // composite evidence so a successful no-op/unknown tail cannot erase an
    // earlier committed or ambiguous mutation.
    return applyingSuccessfulCompositeCommitEvidence(
        to: completed,
        definiteCommit: definitePriorCommit,
        ambiguousCommit: ambiguousCommit)
}

func batchStoppedResult(
    step: Int,
    stepCount: Int,
    tool: String,
    error: String,
    summary: [String],
    definitePriorCommit: Bool,
    ambiguousCommit: Bool
) -> CallTool.Result {
    let result = CallTool.Result.text(
        "Batch stopped at step \(step) of \(stepCount) — earlier steps already ran:\n"
            + (summary + ["✗ step \(step) \(tool): \(error)"]).joined(separator: "\n"),
        isError: true
    )
    return applyingCompositeCommitEvidence(
        to: result,
        definitePriorCommit: definitePriorCommit,
        ambiguousCommit: ambiguousCommit)
}

private func updateCompositeEvidence(
    _ evidence: LeafCommitEvidence,
    definite: inout Bool,
    ambiguous: inout Bool
) {
    switch evidence {
    case .definite: definite = true
    case .unknown: ambiguous = true
    case .none: break
    }
}

func batchResultText(_ result: CallTool.Result) -> String {
    result.content.compactMap { content in
        if case .text(let text, _, _) = content { return text }
        return nil
    }.joined(separator: "\n")
}

private func firstLine(_ text: String) -> String {
    text.components(separatedBy: "\n").first ?? text
}
