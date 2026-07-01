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
let batchableToolNames: Set<String> = appScopedToolNames.subtracting(["batch"]).union(["wait_for"])

func batchImpl(_ args: [String: Value]) async throws -> CallTool.Result {
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
        var arguments = fields
        arguments["tool"] = nil
        arguments["app"] = .string(appName)
        steps.append((tool, arguments))
    }

    var summary: [String] = []
    for (index, step) in steps.enumerated() {
        var arguments = step.arguments
        let isLast = index == steps.count - 1
        if !isLast {
            arguments["include_state"] = .bool(false)
        } else if let includeScreenshot = args["include_screenshot"] {
            arguments["include_screenshot"] = includeScreenshot
        }

        let result = await dispatchTool(name: step.tool, arguments: arguments)
        let text = batchResultText(result)
        if result.isError == true {
            summary.append("✗ step \(index + 1) \(step.tool): \(text)")
            return .text(
                "Batch stopped at step \(index + 1) of \(steps.count) — earlier steps already ran:\n"
                    + summary.joined(separator: "\n"),
                isError: true
            )
        }
        if isLast {
            var header = "Batch completed \(steps.count) step(s):\n"
            header += summary.isEmpty ? "" : summary.joined(separator: "\n") + "\n"
            header += "✓ step \(steps.count) \(step.tool) — final state below.\n\n"
            var content = result.content
            if case .text(let existing, let annotations, let meta)? = content.first {
                content[0] = .text(text: header + existing, annotations: annotations, _meta: meta)
            } else {
                content.insert(.text(text: header, annotations: nil, _meta: nil), at: 0)
            }
            var final = CallTool.Result(content: content, isError: result.isError)
            final._meta = result._meta
            return final
        }
        summary.append("✓ step \(index + 1) \(step.tool): \(firstLine(text))")
    }
    return .text("Batch completed.")  // unreachable: the last step returns above
}

private func batchResultText(_ result: CallTool.Result) -> String {
    result.content.compactMap { content in
        if case .text(let text, _, _) = content { return text }
        return nil
    }.joined(separator: "\n")
}

private func firstLine(_ text: String) -> String {
    text.components(separatedBy: "\n").first ?? text
}
