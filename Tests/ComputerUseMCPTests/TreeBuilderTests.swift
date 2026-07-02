import Testing

@testable import computer_use_mcp

@Suite struct TreeBuilderTests {
    @Test func unlabeledActionlessGroupIsWrapper() {
        #expect(isStructuralWrapper(role: "AXGroup", label: nil, value: nil, focused: false, actions: []))
        // ShowMenu and ScrollToVisible are universal web-element noise, not signal.
        #expect(
            isStructuralWrapper(
                role: "AXGroup", label: "", value: nil, focused: false,
                actions: ["AXShowMenu", "AXScrollToVisible"]
            ))
    }

    @Test func labeledGroupIsKept() {
        #expect(!isStructuralWrapper(role: "AXGroup", label: "Sidebar", value: nil, focused: false, actions: []))
    }

    @Test func actionableGroupIsKept() {
        #expect(
            !isStructuralWrapper(
                role: "AXGroup", label: nil, value: nil, focused: false,
                actions: ["AXPress", "AXShowMenu"]
            ))
    }

    @Test func valuedOrFocusedGroupIsKept() {
        #expect(!isStructuralWrapper(role: "AXGroup", label: nil, value: "3", focused: false, actions: []))
        #expect(!isStructuralWrapper(role: "AXGroup", label: nil, value: nil, focused: true, actions: []))
    }

    @Test func nonGroupRolesAreNeverWrappers() {
        for role in ["AXButton", "AXStaticText", "AXWebArea", "AXWindow", "AXList"] {
            #expect(!isStructuralWrapper(role: role, label: nil, value: nil, focused: false, actions: []))
        }
    }
}

@Suite struct RoleDescriptionFallbackTests {
    @Test func descriptionEchoingTheRoleIsDropped() {
        #expect(informativeRoleDescription(role: "AXButton", description: "button") == nil)
        #expect(informativeRoleDescription(role: "AXStaticText", description: "text") == nil)
        #expect(informativeRoleDescription(role: "AXPopUpButton", description: "pop up button") == nil)
        #expect(informativeRoleDescription(role: "AXCheckBox", description: "Check Box") == nil)
    }

    @Test func contextBeyondTheRoleIsKept() {
        #expect(informativeRoleDescription(role: "AXButton", description: "close button") == "close button")
        #expect(informativeRoleDescription(role: "AXCheckBox", description: "switch") == "switch")
        #expect(informativeRoleDescription(role: "AXGroup", description: "banner") == "banner")
    }

    @Test func genericDefaultsAreDropped() {
        #expect(informativeRoleDescription(role: "AXWindow", description: "standard window") == nil)
        #expect(informativeRoleDescription(role: "AXWebArea", description: "HTML content") == nil)
        #expect(informativeRoleDescription(role: "AXRow", description: "outline row") == nil)
    }

    @Test func missingOrEmptyDescriptionIsDropped() {
        #expect(informativeRoleDescription(role: "AXButton", description: nil) == nil)
        #expect(informativeRoleDescription(role: "AXButton", description: "") == nil)
        #expect(informativeRoleDescription(role: "AXButton", description: " ") == nil)
    }
}

@Suite struct DisplayableIdentifierTests {
    @Test func developerIdentifiersPassThrough() {
        #expect(displayableIdentifier("AddAccountButton") == "AddAccountButton")
        #expect(displayableIdentifier("sidebar.search") == "sidebar.search")
    }

    @Test func uuidAndNumericNoiseIsSkipped() {
        // More than half the characters are digits/hyphens: auto-generated.
        #expect(displayableIdentifier("12345678-1234-1234-1234-123456789012") == nil)
        #expect(displayableIdentifier("4211") == nil)
        #expect(displayableIdentifier("row-12-34-56") == nil)
    }

    @Test func halfNoiseIsStillShown() {
        // Exactly half digits is not "more than half".
        #expect(displayableIdentifier("ab12") == "ab12")
    }

    @Test func longIdentifiersTruncateTo40Chars() {
        let long = String(repeating: "a", count: 50)
        let shown = displayableIdentifier(long)
        #expect(shown == String(repeating: "a", count: 40) + "…")
    }

    @Test func missingOrEmptyIdentifierIsSkipped() {
        #expect(displayableIdentifier(nil) == nil)
        #expect(displayableIdentifier("") == nil)
    }
}
