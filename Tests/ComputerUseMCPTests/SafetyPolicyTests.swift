import Testing

@testable import computer_use_mcp

private let app = ResolvedApp(pid: 1, name: "TestApp", bundleIdentifier: "com.example.test")

@Suite struct SafetyPolicyTests {
    @Test func destructiveLabelsRequireConfirmation() {
        for label in ["Delete", "Move to Trash", "Erase All Content", "Don't Save", "Reset Settings"] {
            #expect(throws: SafetyError.self, "\(label) should be gated") {
                try SafetyPolicy.checkClick(label: label, app: app, confirmed: false)
            }
        }
    }

    @Test func benignLabelsPass() throws {
        for label in ["OK", "Save", "Open", "7", "All Clear"] {
            try SafetyPolicy.checkClick(label: label, app: app, confirmed: false)
        }
    }

    @Test func confirmationBypassesGate() throws {
        try SafetyPolicy.checkClick(label: "Delete", app: app, confirmed: true)
    }

    @Test func clearingValueIsGated() {
        #expect(throws: SafetyError.self) {
            try SafetyPolicy.checkValueChange(currentValue: "existing text", newValue: "", app: app, confirmed: false)
        }
    }

    @Test func settingValueOnEmptyFieldPasses() throws {
        try SafetyPolicy.checkValueChange(currentValue: "", newValue: "hello", app: app, confirmed: false)
        try SafetyPolicy.checkValueChange(currentValue: "old", newValue: "new", app: app, confirmed: false)
    }

    @Test func closingWindowRequiresConfirmation() {
        #expect(throws: SafetyError.self) {
            try SafetyPolicy.checkWindowAction(
                action: "close", targetDescription: "window \"Draft\" of TestApp", app: app, confirmed: false
            )
        }
    }

    @Test func confirmedWindowClosePasses() throws {
        try SafetyPolicy.checkWindowAction(
            action: "close", targetDescription: "window \"Draft\" of TestApp", app: app, confirmed: true
        )
    }

    @Test func nonClosingWindowActionPasses() throws {
        try SafetyPolicy.checkWindowAction(
            action: "minimize", targetDescription: "window \"Draft\" of TestApp", app: app, confirmed: false
        )
    }

    @Test func destructiveShortcutIsGated() throws {
        let chord = try Keymap.parse("cmd+Delete")
        #expect(throws: SafetyError.self) {
            try SafetyPolicy.checkKey(combo: "cmd+Delete", chord: chord, focused: nil, app: app, confirmed: false)
        }
    }

    @Test func plainKeyPasses() throws {
        let chord = try Keymap.parse("Tab")
        try SafetyPolicy.checkKey(combo: "Tab", chord: chord, focused: nil, app: app, confirmed: false)
    }

    @Test func safetyErrorExplainsRecovery() {
        let error = SafetyError(reason: "test reason.")
        #expect(error.description.contains("confirm"))
        #expect(error.description.contains("test reason."))
    }
}
