import Testing

@testable import computer_use_mcp

@Suite struct SessionPowerTests {
    @Test func lockedScreenPausesMutatingToolsOnly() {
        #expect(lockedScreenMessage(toolName: "click", isLocked: true) != nil)
        #expect(lockedScreenMessage(toolName: "type_text", isLocked: true) != nil)
        #expect(lockedScreenMessage(toolName: "open_app", isLocked: true) != nil)
        // Read-only perception stays available behind the lock.
        #expect(lockedScreenMessage(toolName: "get_app_state", isLocked: true) == nil)
        #expect(lockedScreenMessage(toolName: "get_app_state", isLocked: true) == nil)
        #expect(lockedScreenMessage(toolName: "read_clipboard", isLocked: true) == nil)
    }

    @Test func unlockedScreenNeverPauses() {
        #expect(lockedScreenMessage(toolName: "click", isLocked: false) == nil)
        #expect(lockedScreenMessage(toolName: "get_app_state", isLocked: false) == nil)
    }

    @Test func missingSessionDictionaryFailsClosedAsLocked() {
        #expect(screenIsLocked(session: nil))
    }

    @Test func unlockedSessionDictionaryIsDetected() {
        #expect(!screenIsLocked(session: ["CGSSessionScreenIsLocked": false]))
        // Key absent on a present dictionary means unlocked (normal desktop).
        #expect(!screenIsLocked(session: [:]))
    }

    @Test func lockedSessionDictionaryIsDetected() {
        #expect(screenIsLocked(session: ["CGSSessionScreenIsLocked": true]))
    }
}
