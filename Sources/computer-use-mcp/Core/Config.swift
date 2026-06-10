// Layered configuration: environment variables win, then
// ~/.config/computer-use-mcp.json, then built-in defaults.
//
// File keys are lowercase snake_case; the matching env var is the key
// uppercased with the COMPUTER_USE_MCP_ prefix (e.g. "cursor_idle_fade" ↔
// COMPUTER_USE_MCP_CURSOR_IDLE_FADE). JSON values may be strings, numbers,
// booleans, or arrays of strings (joined with commas).

import Foundation

enum Config {
    private static let fileValues: [String: String] = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/computer-use-mcp.json")
        guard let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var values: [String: String] = [:]
        for (key, value) in object {
            switch value {
            case let string as String: values[key] = string
            case let array as [String]: values[key] = array.joined(separator: ",")
            case let number as NSNumber: values[key] = number.stringValue
            default: break
            }
        }
        return values
    }()

    static func string(_ key: String) -> String? {
        ProcessInfo.processInfo.environment["COMPUTER_USE_MCP_" + key.uppercased()]
            ?? fileValues[key]
    }

    static func bool(_ key: String) -> Bool? {
        guard let raw = string(key)?.lowercased() else { return nil }
        return raw == "1" || raw == "true" ? true : raw == "0" || raw == "false" ? false : nil
    }

    static func double(_ key: String) -> Double? {
        string(key).flatMap(Double.init)
    }

    /// Comma-separated list value, trimmed and lowercased.
    static func list(_ key: String) -> [String] {
        (string(key) ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }
}
