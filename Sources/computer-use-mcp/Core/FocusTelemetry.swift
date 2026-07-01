import AppKit
import Foundation
import MCP

private let focusTelemetryMetaKey = "computer-use-mcp/focus"

struct FrontmostAppSnapshot: Equatable {
    let name: String
    let bundleIdentifier: String
    let pid: pid_t

    static func current() -> FrontmostAppSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontmostAppSnapshot(
            name: app.localizedName ?? "unknown",
            bundleIdentifier: app.bundleIdentifier ?? "",
            pid: app.processIdentifier
        )
    }

    var value: Value {
        .object([
            "name": .string(name),
            "bundle_identifier": .string(bundleIdentifier),
            "pid": .int(Int(pid)),
        ])
    }
}

struct FocusTelemetry: Equatable {
    let before: FrontmostAppSnapshot?
    let after: FrontmostAppSnapshot?
    let deliveryTier: String?
    let focusChangeAllowed: Bool
    let cursorMovementAllowed: Bool

    var focusChanged: Bool {
        before != after
    }

    var value: Value {
        var fields: [String: Value] = [
            "focus_changed": .bool(focusChanged),
            "focus_change_allowed": .bool(focusChangeAllowed),
            "cursor_movement_allowed": .bool(cursorMovementAllowed),
        ]
        if let before {
            fields["frontmost_before"] = before.value
        }
        if let after {
            fields["frontmost_after"] = after.value
        }
        if let deliveryTier {
            fields["delivery_tier"] = .string(deliveryTier)
        }
        return .object(fields)
    }

    var metadata: Metadata {
        Metadata(additionalFields: [focusTelemetryMetaKey: value])
    }
}

struct FocusChangeTracker {
    let before: FrontmostAppSnapshot?
    let focusChangeAllowed: Bool
    let cursorMovementAllowed: Bool

    static func start(focusChangeAllowed: Bool = false, cursorMovementAllowed: Bool = false) -> FocusChangeTracker {
        FocusChangeTracker(
            before: FrontmostAppSnapshot.current(),
            focusChangeAllowed: focusChangeAllowed,
            cursorMovementAllowed: cursorMovementAllowed
        )
    }

    func finish(deliveryTier: String? = nil) -> FocusTelemetry {
        FocusTelemetry(
            before: before,
            after: FrontmostAppSnapshot.current(),
            deliveryTier: deliveryTier,
            focusChangeAllowed: focusChangeAllowed,
            cursorMovementAllowed: cursorMovementAllowed
        )
    }
}

func allowGlobalCursorArgument(_ args: [String: Value]) throws -> Bool {
    let allowGlobalCursor = args.bool("allow_global_cursor") == true
    if allowGlobalCursor && args.bool("allow_focus_change") != true {
        throw ToolError.invalidArguments(
            "\"allow_global_cursor\" may move the real cursor and change foreground focus. "
                + "Retry with \"allow_focus_change\": true when that escalation is intentional."
        )
    }
    return allowGlobalCursor
}

func allowGlobalKeyboardArgument(_ args: [String: Value]) throws -> Bool {
    let allowGlobalKeyboard = args.bool("allow_global_cursor") == true
    if allowGlobalKeyboard && args.bool("allow_focus_change") != true {
        throw ToolError.invalidArguments(
            "\"allow_global_cursor\" sends keyboard input through the global session tap and may change focus. "
                + "Retry with \"allow_focus_change\": true when that escalation is intentional."
        )
    }
    return allowGlobalKeyboard
}

func requireFocusChangeAllowed(_ args: [String: Value], reason: String) throws {
    guard args.bool("allow_focus_change") == true else {
        throw ToolError.invalidArguments(
            "\(reason) Retry with \"allow_focus_change\": true when changing foreground focus is intentional."
        )
    }
}

extension CallTool.Result {
    func withFocusTelemetry(_ telemetry: FocusTelemetry?) -> CallTool.Result {
        guard let telemetry else { return self }
        var result = self
        var fields = result._meta?.fields ?? [:]
        fields[focusTelemetryMetaKey] = telemetry.value
        result._meta = Metadata(additionalFields: fields)
        return result
    }
}
