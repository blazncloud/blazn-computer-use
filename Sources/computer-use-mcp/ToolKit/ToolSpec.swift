// Internal tool abstraction shared by the MCP server (`serve`) and the
// shell harness (`call`).

import MCP

struct ToolSpec: Sendable {
    let name: String
    let description: String
    let inputSchema: Value
    let handler: @Sendable ([String: Value]) async throws -> CallTool.Result
}

/// Tools with side effects on apps, windows, the system clipboard, launched
/// processes, or URL/file handlers. These must go through the daemon unless
/// the user explicitly opts into in-process operation with no_daemon.
let mutatingToolNames: Set<String> = [
    "click", "type_text", "press_key", "scroll", "drag", "set_value",
    "select_text", "perform_secondary_action", "open_app", "open_url",
    "manage_window", "click_menu_item", "write_clipboard", "batch",
    "run_skill", "save_skill", "delete_skill",
    // The recorder owns a single event tap on a daemon run-loop thread, so
    // both ends must run in the daemon, not per-shim in-process.
    "record_skill_start", "record_skill_stop",
]

/// Mutating tools scoped to a target app — the canonical set behind three
/// gates: daemon app leases (two sessions must not interleave inside one
/// app), the human-interference yield, and the browser URL policy. Removing
/// a tool here silently removes it from all three.
let appScopedToolNames: Set<String> = [
    "click", "type_text", "press_key", "scroll", "drag", "set_value",
    "select_text", "perform_secondary_action", "click_menu_item", "manage_window",
    "batch", "run_skill",
]

func isMutatingTool(_ name: String) -> Bool {
    mutatingToolNames.contains(name)
}

enum ToolError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case notImplemented(String)
    case failed(String)

    var description: String {
        switch self {
        case .invalidArguments(let message): return "Invalid arguments: \(message)"
        case .notImplemented(let name): return "Tool \(name) is not implemented yet."
        case .failed(let message): return message
        }
    }
}

extension CallTool.Result {
    static func text(_ message: String, isError: Bool = false) -> CallTool.Result {
        .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: isError)
    }
}

// Typed argument accessors. JSON numbers may arrive as int or double; accept both.
extension [String: Value] {
    func string(_ key: String) -> String? {
        self[key]?.stringValue
    }

    func number(_ key: String) -> Double? {
        if let double = self[key]?.doubleValue { return double }
        if let int = self[key]?.intValue { return Double(int) }
        return nil
    }

    func integer(_ key: String) -> Int? {
        if let int = self[key]?.intValue { return int }
        if let double = self[key]?.doubleValue, double == double.rounded() { return Int(double) }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        self[key]?.boolValue
    }

    func requireString(_ key: String) throws -> String {
        guard let value = string(key), !value.isEmpty else {
            throw ToolError.invalidArguments("\"\(key)\" (string) is required.")
        }
        return value
    }

    func requireNumber(_ key: String) throws -> Double {
        guard let value = number(key) else {
            throw ToolError.invalidArguments("\"\(key)\" (number) is required.")
        }
        return value
    }
}
