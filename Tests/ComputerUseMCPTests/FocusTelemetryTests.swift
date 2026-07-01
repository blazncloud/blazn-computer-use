import MCP
import Testing

@testable import computer_use_mcp

@Suite struct FocusTelemetryTests {
    @Test func focusTelemetryReportsStableFrontmostApp() throws {
        let app = FrontmostAppSnapshot(name: "Finder", bundleIdentifier: "com.apple.finder", pid: 42)
        let telemetry = FocusTelemetry(
            before: app,
            after: app,
            deliveryTier: InputTier.accessibilityAttribute.rawValue,
            focusChangeAllowed: false,
            cursorMovementAllowed: false
        )

        guard case let .object(fields) = telemetry.value else {
            Issue.record("expected object telemetry")
            return
        }
        #expect(fields["focus_changed"]?.boolValue == false)
        #expect(fields["focus_change_allowed"]?.boolValue == false)
        #expect(fields["cursor_movement_allowed"]?.boolValue == false)
        #expect(fields["delivery_tier"]?.stringValue == InputTier.accessibilityAttribute.rawValue)
    }

    @Test func focusTelemetryReportsChangedFrontmostApp() throws {
        let before = FrontmostAppSnapshot(name: "Finder", bundleIdentifier: "com.apple.finder", pid: 42)
        let after = FrontmostAppSnapshot(name: "Fixture", bundleIdentifier: "dev.computer-use.fixture", pid: 99)
        let telemetry = FocusTelemetry(
            before: before,
            after: after,
            deliveryTier: InputTier.globalCursor.rawValue,
            focusChangeAllowed: true,
            cursorMovementAllowed: true
        )

        guard case let .object(fields) = telemetry.value else {
            Issue.record("expected object telemetry")
            return
        }
        #expect(fields["focus_changed"]?.boolValue == true)
        #expect(fields["focus_change_allowed"]?.boolValue == true)
        #expect(fields["cursor_movement_allowed"]?.boolValue == true)
    }

    @Test func globalCursorRequiresExplicitFocusChangeAllowance() throws {
        let message = invalidArgumentMessage {
            _ = try allowGlobalCursorArgument(["allow_global_cursor": .bool(true)])
        }
        #expect(message.contains("\"allow_global_cursor\""))
        #expect(message.contains("\"allow_focus_change\""))

        #expect(try allowGlobalCursorArgument(["allow_global_cursor": .bool(true), "allow_focus_change": .bool(true)]))
        #expect(try allowGlobalCursorArgument([:]) == false)
    }

    @Test func globalKeyboardRequiresExplicitFocusChangeAllowance() throws {
        let message = invalidArgumentMessage {
            _ = try allowGlobalKeyboardArgument(["allow_global_cursor": .bool(true)])
        }
        #expect(message.contains("\"allow_global_cursor\""))
        #expect(message.contains("\"allow_focus_change\""))

        #expect(try allowGlobalKeyboardArgument(["allow_global_cursor": .bool(true), "allow_focus_change": .bool(true)]))
        #expect(try allowGlobalKeyboardArgument([:]) == false)
    }

    @Test func focusMutatingToolsRequireExplicitFocusChangeAllowance() throws {
        let message = invalidArgumentMessage {
            try requireFocusChangeAllowed([:], reason: "This may change focus.")
        }
        #expect(message.contains("allow_focus_change"))

        try requireFocusChangeAllowed(["allow_focus_change": .bool(true)], reason: "This may change focus.")
    }

    @Test func resultMetadataMergesFocusTelemetry() {
        let app = FrontmostAppSnapshot(name: "Finder", bundleIdentifier: "com.apple.finder", pid: 42)
        let telemetry = FocusTelemetry(
            before: app,
            after: app,
            deliveryTier: InputTier.accessibilityAction.rawValue,
            focusChangeAllowed: false,
            cursorMovementAllowed: false
        )

        let result = CallTool.Result.text("ok").withFocusTelemetry(telemetry)
        #expect(result._meta?["computer-use-mcp/focus"] != nil)
    }

    @Test func focusTrackerUsesExplicitPolicyNotRawArguments() {
        let tracker = FocusChangeTracker.start()
        let telemetry = tracker.finish()

        guard case let .object(fields) = telemetry.value else {
            Issue.record("expected object telemetry")
            return
        }
        #expect(fields["focus_change_allowed"]?.boolValue == false)
        #expect(fields["cursor_movement_allowed"]?.boolValue == false)
    }
}

private func invalidArgumentMessage(_ body: () throws -> Void) -> String {
    do {
        try body()
    } catch let error as ToolError {
        if case .invalidArguments(let message) = error {
            return message
        }
        return String(describing: error)
    } catch {
        return String(describing: error)
    }
    return ""
}
