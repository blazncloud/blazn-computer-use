// Server-side safety policy.
//
// This MCP server can be driven by any agent, so it does not rely on the
// client's model to restrain itself. Clearly destructive/irreversible actions,
// typing into secure (password) fields, and actions against apps on a
// confirmation list require the caller to pass confirm:true. The model sees a
// clear, recoverable error explaining what to confirm — it never silently
// performs the risky action.
//
// Everything here is configurable and fully disable-able:
//   COMPUTER_USE_MCP_NO_SAFETY=1            disable the policy entirely
//   COMPUTER_USE_MCP_CONFIRM_APPS=a,b,c     apps where every action needs confirm
//   COMPUTER_USE_MCP_DESTRUCTIVE=pat,pat    extra destructive label substrings

import ApplicationServices
import Foundation
import MCP

struct SafetyError: Error, CustomStringConvertible {
    let reason: String
    var description: String {
        "Confirmation required: \(reason) Re-run the same call with \"confirm\": true to proceed."
    }
}

enum SafetyPolicy {
    private static let env = ProcessInfo.processInfo.environment

    static var isEnabled: Bool { env["COMPUTER_USE_MCP_NO_SAFETY"] != "1" }

    /// Default destructive label substrings (case-insensitive), plus any from env.
    private static var destructivePatterns: [String] {
        let defaults = [
            "delete", "remove", "erase", "trash", "discard", "don't save", "dont save",
            "reset", "format", "uninstall", "destroy", "wipe", "shut down", "log out",
        ]
        let extra = (env["COMPUTER_USE_MCP_DESTRUCTIVE"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        return defaults + extra
    }

    /// Apps where every action requires confirmation (none by default).
    private static var confirmApps: Set<String> {
        Set(
            (env["COMPUTER_USE_MCP_CONFIRM_APPS"] ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        )
    }

    static func confirmed(_ args: [String: Value]) -> Bool {
        args.bool("confirm") == true
    }

    /// Gate an action against an app. Throws when confirmation is required and
    /// not given.
    static func check(app: ResolvedApp, confirmed: Bool) throws {
        guard isEnabled, !confirmed else { return }
        if confirmApps.contains(app.name.lowercased()) || confirmApps.contains(app.bundleIdentifier.lowercased()) {
            throw SafetyError(reason: "\(app.name) is on the confirmation list, so all actions against it must be confirmed.")
        }
    }

    /// Gate a click by its element label (destructive button text).
    static func checkClick(label: String?, app: ResolvedApp, confirmed: Bool) throws {
        guard isEnabled, !confirmed, let label, !label.isEmpty else { return }
        let lower = label.lowercased()
        if let hit = destructivePatterns.first(where: { lower.contains($0) }) {
            throw SafetyError(
                reason: "\"\(label)\" in \(app.name) looks destructive or irreversible (matched \"\(hit)\")."
            )
        }
    }

    /// Gate typing into a secure (password) field.
    static func checkTyping(into element: AXUIElement, app: ResolvedApp, confirmed: Bool) throws {
        guard isEnabled, !confirmed else { return }
        let subrole = axString(element, kAXSubroleAttribute)
        if subrole == (kAXSecureTextFieldSubrole as String) {
            throw SafetyError(
                reason: "the target in \(app.name) is a secure text field (password entry)."
            )
        }
    }
}
