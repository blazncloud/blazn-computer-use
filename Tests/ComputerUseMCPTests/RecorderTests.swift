import MCP
import Testing

@testable import computer_use_mcp

@Suite struct RecorderCompileTests {
    @Test func clickCompilesToDurableRoleLabelLocator() {
        let steps = compileRecordedEvents([
            .click(role: "AXButton", label: "Save", clickCount: 1, button: "left")
        ])
        #expect(steps.count == 1)
        #expect(steps[0].tool == "click")
        #expect(steps[0].locator?.role == "AXButton")
        #expect(steps[0].locator?.label == "Save")
        // A plain single left click carries no extra arguments.
        #expect(steps[0].arguments.isEmpty)
    }

    @Test func doubleAndRightClickCarryArguments() {
        let steps = compileRecordedEvents([
            .click(role: "AXCell", label: "file.txt", clickCount: 2, button: "left"),
            .click(role: "AXRow", label: nil, clickCount: 1, button: "right"),
        ])
        #expect(steps[0].arguments["click_count"]?.intValue == 2)
        #expect(steps[1].arguments["mouse_button"]?.stringValue == "right")
    }

    @Test func textAndKeyAndScrollCompile() {
        let steps = compileRecordedEvents([
            .text("hello world"),
            .key(combo: "cmd+s"),
            .scroll(direction: "down"),
        ])
        #expect(steps.map(\.tool) == ["type_text", "press_key", "scroll"])
        #expect(steps[0].arguments["text"]?.stringValue == "hello world")
        #expect(steps[1].arguments["key"]?.stringValue == "cmd+s")
        #expect(steps[2].arguments["direction"]?.stringValue == "down")
    }

    @Test func emptyTextIsDropped() {
        #expect(compileRecordedEvents([.text("")]).isEmpty)
    }

    @Test func textEntryClicksAnchorByRoleWithoutLabel() {
        // A text field's clickable label is its description/placeholder/
        // content — all churn as the user types, so no label is recorded.
        #expect(recordedClickLabel(role: "AXTextArea", label: "text entry area") == nil)
        #expect(recordedClickLabel(role: "AXTextField", label: "hello world") == nil)
        #expect(recordedClickLabel(role: "AXButton", label: "Save") == "Save")
    }

    @Test func shortcutClassification() {
        #expect(keyComboIsShortcut(commandDown: true, controlDown: false, optionDown: false))
        #expect(keyComboIsShortcut(commandDown: false, controlDown: true, optionDown: false))
        // Shift-only (capitalization) is typed text, not a shortcut.
        #expect(!keyComboIsShortcut(commandDown: false, controlDown: false, optionDown: false))
    }

    @Test func controlCharactersMapToKeyNames() {
        #expect(controlKeyName("\r") == "Return")
        #expect(controlKeyName("\t") == "Tab")
        #expect(controlKeyName("\u{1b}") == "Escape")
        #expect(controlKeyName("a") == nil)
        #expect(controlKeyName("!") == nil)
    }

    @Test func recorderToolsRouteThroughDaemon() {
        #expect(isMutatingTool("record_skill_start"))
        #expect(isMutatingTool("record_skill_stop"))
        // Recording is passive: it is not an app-scoped action, so it does
        // not participate in leases / interference / URL gates.
        #expect(!appScopedToolNames.contains("record_skill_start"))
    }
}
