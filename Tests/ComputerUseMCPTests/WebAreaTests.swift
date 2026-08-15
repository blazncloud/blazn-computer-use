import Testing

@testable import computer_use_mcp

private func webNode(_ id: Int, role: String, label: String? = nil) -> CapturedNode {
    CapturedNode(id: "e\(id)@s1", role: role, label: label, frame: [0, 0, 10, 10])
}

private func flattened(_ root: CapturedNode) -> [CapturedNode] {
    [root] + root.children.flatMap(flattened)
}

@Suite struct WebAreaTests {
    @Test func webAreaEmptinessUsesCapturedChildren() {
        let window = webNode(0, role: "AXWindow")
        let web = webNode(1, role: "AXWebArea")
        window.appendChild(web)
        #expect(hasEmptyWebArea(flattened(window)))

        web.appendChild(webNode(2, role: "AXStaticText"))
        #expect(!hasEmptyWebArea(flattened(window)))
    }

    @Test func treeWithoutWebAreaIsNotEmpty() {
        let window = webNode(0, role: "AXWindow")
        window.appendChild(webNode(1, role: "AXButton"))
        #expect(!hasEmptyWebArea(flattened(window)))
    }

    @Test func coldStartShapesTriggerBoundedRetryPlan() {
        let window = webNode(0, role: "AXWindow")
        window.appendChild(webNode(1, role: "AXWebArea"))
        #expect(hasColdStartWebContentShape(flattened(window)))
        #expect(webMaterializationRetryBackoffMilliseconds.reduce(0, +) <= 2_500)

        let placeholderWindow = webNode(0, role: "AXWindow")
        placeholderWindow.appendChild(webNode(1, role: "AXGroup", label: "web-pane"))
        #expect(hasColdStartWebContentShape(flattened(placeholderWindow)))
    }

    @Test func capturedAncestryDetectsTargetInsideWebArea() {
        let window = webNode(0, role: "AXWindow")
        let web = webNode(1, role: "AXWebArea")
        let target = webNode(2, role: "AXTextField")
        window.appendChild(web)
        web.appendChild(target)
        #expect(targetIsInWebArea(nil, snapshotElement: target))

        let plain = webNode(3, role: "AXTextField")
        window.appendChild(plain)
        #expect(!targetIsInWebArea(nil, snapshotElement: plain))
    }

    @Test func diffRequiresIndependentTargetSpecificEvidence() {
        let target = webNode(1, role: "AXTextField")
        let targetOnly = TreeDiff(
            changed: ["~ e1@s1 AXTextField value=hello"], added: [], removed: [],
            totalElements: 1)
        let sibling = TreeDiff(
            changed: ["~ e2@s1 AXStaticText value=hello"], added: [], removed: [],
            totalElements: 2)
        #expect(!targetOnly.hasChangeIndependent(of: target))
        #expect(sibling.hasChangeIndependent(of: target, matching: "hello"))
        #expect(!sibling.hasChangeIndependent(of: target, matching: "goodbye"))
    }
}
