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
