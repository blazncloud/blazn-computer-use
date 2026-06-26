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
    "manage_window", "click_menu_item", "write_clipboard",
]

/// Mutating tools that are scoped to an app and should participate in daemon
/// app leases to avoid two sessions interleaving actions inside one app.
let appLeaseToolNames: Set<String> = [
    "click", "type_text", "press_key", "scroll", "drag", "set_value",
    "select_text", "perform_secondary_action", "click_menu_item", "manage_window",
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
