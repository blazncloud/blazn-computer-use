import ApplicationServices
import Foundation
import Testing

@testable import computer_use_mcp

private func diffNode(
    _ id: String, handleToken: pid_t, role: String = "AXButton", label: String = "Save"
) -> CapturedNode {
    CapturedNode(
        id: id, role: role, label: label,
        fingerprint: ElementFingerprint(
            role: role, subrole: nil, identifier: nil, stableLabel: label),
        frame: [0, 0, 80, 24], handle: AXUIElementCreateApplication(handleToken))
}

private func diffSnapshot(tree: BuiltTree) -> AppSnapshot {
    AppSnapshot(
        pid: 1, bundleIdentifier: "com.example", windowTitle: "Document",
        windowOrigin: [0, 0], pixelsPerPoint: 1, windowSize: [400, 300],
        createdAt: Date(), generation: "s1", treeFingerprint: treeFingerprint(tree.text),
        treeText: tree.text, scoped: false, partial: false, coverage: .complete,
        lineage: nil, root: tree.root, elements: tree.elements)
}

@Suite struct HandleBasedSnapshotDiffTests {
    @Test func reorderedSameHandlesKeepIDs() throws {
        let a = diffNode("e0@s1", handleToken: 90_001, label: "A")
        let b = diffNode("e1@s1", handleToken: 90_002, label: "B")
        let previousTree = BuiltTree(
            text: "e0@s1 AXButton \"A\"\ne1@s1 AXButton \"B\"",
            elements: [a, b])
        let freshB = diffNode("e0@s2", handleToken: 90_002, label: "B")
        let freshA = diffNode("e1@s2", handleToken: 90_001, label: "A")
        let fresh = BuiltTree(
            text: "e0@s2 AXButton \"B\"\ne1@s2 AXButton \"A\"",
            elements: [freshB, freshA])

        let result = try #require(stabilizeTree(fresh, against: diffSnapshot(tree: previousTree)))
        #expect(result.tree.elements.map(\.id) == ["e1@s1", "e0@s1"])
        #expect(result.diff.added.isEmpty)
        #expect(result.diff.removed.isEmpty)
    }

    @Test func samePositionDifferentHandleDoesNotStealID() throws {
        let old = diffNode("e0@s1", handleToken: 90_003)
        let previous = BuiltTree(text: "e0@s1 AXButton \"Save\"", elements: [old])
        let replacement = diffNode("e0@s2", handleToken: 90_004)
        let fresh = BuiltTree(text: "e0@s2 AXButton \"Save\"", elements: [replacement])

        let result = try #require(stabilizeTree(fresh, against: diffSnapshot(tree: previous)))
        #expect(result.tree.elements[0].id == "e0@s2")
        #expect(result.diff.added.count == 1)
        #expect(result.diff.removed.count == 1)
    }
}
