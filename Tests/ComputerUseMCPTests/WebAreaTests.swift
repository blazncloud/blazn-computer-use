import Testing

@testable import computer_use_mcp

private func element(_ id: Int, role: String, path: [LocatorStep]) -> SnapshotElement {
    SnapshotElement(id: "e\(id)@s1", role: role, label: nil, path: path, frame: [0, 0, 10, 10])
}

private let group0 = LocatorStep(role: "AXGroup", indexOfRole: 0)
private let web0 = LocatorStep(role: "AXWebArea", indexOfRole: 0)

@Suite struct WebAreaTests {
    @Test func webAreaWithContentIsNotEmpty() {
        let elements = [
            element(0, role: "AXWindow", path: []),
            element(1, role: "AXWebArea", path: [group0, web0]),
            element(2, role: "AXStaticText", path: [group0, web0, group0, LocatorStep(role: "AXStaticText", indexOfRole: 0)]),
        ]
        #expect(!hasEmptyWebArea(elements))
    }

    @Test func childlessWebAreaIsEmpty() {
        let elements = [
            element(0, role: "AXWindow", path: []),
            element(1, role: "AXWebArea", path: [group0, web0]),
            element(2, role: "AXButton", path: [LocatorStep(role: "AXButton", indexOfRole: 0)]),
        ]
        #expect(hasEmptyWebArea(elements))
    }

    @Test func trailingWebAreaIsEmpty() {
        let elements = [
            element(0, role: "AXWindow", path: []),
            element(1, role: "AXWebArea", path: [group0, web0]),
        ]
        #expect(hasEmptyWebArea(elements))
    }

    @Test func treeWithoutWebAreaIsNotEmpty() {
        let elements = [
            element(0, role: "AXWindow", path: []),
            element(1, role: "AXButton", path: [LocatorStep(role: "AXButton", indexOfRole: 0)]),
        ]
        #expect(!hasEmptyWebArea(elements))
    }
}
