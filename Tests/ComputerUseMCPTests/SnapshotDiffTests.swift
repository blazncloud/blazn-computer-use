import Foundation
import Testing

@testable import computer_use_mcp

private let windowStep: [LocatorStep] = []
private let fieldPath = [LocatorStep(role: "AXTextField", indexOfRole: 0)]
private let buttonPath = [LocatorStep(role: "AXButton", indexOfRole: 0)]
private let sheetPath = [LocatorStep(role: "AXSheet", indexOfRole: 0)]

private func previousSnapshot() -> AppSnapshot {
    let elements = [
        SnapshotElement(id: "e0@s1", role: "AXWindow", label: "Doc", path: windowStep, frame: [0, 0, 800, 600]),
        SnapshotElement(id: "e1@s1", role: "AXTextField", label: nil, path: fieldPath, frame: [10, 10, 200, 30]),
        SnapshotElement(id: "e2@s1", role: "AXButton", label: "Save", path: buttonPath, frame: [10, 50, 80, 30]),
    ]
    let lines = [
        "e0@s1 AXWindow \"Doc\" (0,0,800,600)",
        "\te1@s1 AXTextField (10,10,200,30) value=\"old\"",
        "\te2@s1 AXButton \"Save\" (10,50,80,30) actions=Press",
    ]
    return AppSnapshot(
        pid: 1, bundleIdentifier: "com.example", windowTitle: "Doc",
        windowOrigin: [0, 0], pixelsPerPoint: 2, windowSize: [800, 600],
        createdAt: Date(timeIntervalSince1970: 0), generation: "s1",
        treeFingerprint: "x", treeText: lines.joined(separator: "\n"), scoped: false,
        elements: elements
    )
}

/// New capture: field value changed, Save button gone, a sheet appeared.
private func newTree() -> BuiltTree {
    let elements = [
        SnapshotElement(id: "e0@s2", role: "AXWindow", label: "Doc", path: windowStep, frame: [0, 0, 800, 600]),
        SnapshotElement(id: "e1@s2", role: "AXTextField", label: nil, path: fieldPath, frame: [10, 10, 200, 30]),
        SnapshotElement(id: "e2@s2", role: "AXSheet", label: "Export", path: sheetPath, frame: [100, 100, 400, 300]),
    ]
    let lines = [
        "e0@s2 AXWindow \"Doc\" (0,0,800,600)",
        "\te1@s2 AXTextField (10,10,200,30) value=\"new\"",
        "\te2@s2 AXSheet \"Export\" (100,100,400,300)",
    ]
    return BuiltTree(text: lines.joined(separator: "\n"), elements: elements)
}

@Suite struct SnapshotDiffTests {
    @Test func survivingElementsCarryTheirIDs() throws {
        let result = try #require(stabilizeTree(newTree(), against: previousSnapshot()))
        #expect(result.tree.elements[0].id == "e0@s1")
        #expect(result.tree.elements[1].id == "e1@s1")
        // The new sheet keeps its fresh generation id.
        #expect(result.tree.elements[2].id == "e2@s2")
        // The rendered text carries the same ids.
        #expect(result.tree.text.contains("e1@s1 AXTextField"))
        #expect(!result.tree.text.contains("e1@s2"))
    }

    @Test func diffReportsChangedAddedAndRemoved() throws {
        let result = try #require(stabilizeTree(newTree(), against: previousSnapshot()))
        let diff = result.diff
        // Value change on the carried field.
        #expect(diff.changed.count == 1)
        #expect(diff.changed[0].hasPrefix("~ e1@s1"))
        #expect(diff.changed[0].contains("value=\"new\""))
        // The sheet is new; the button is gone.
        #expect(diff.added.count == 1)
        #expect(diff.added[0].hasPrefix("+ e2@s2 AXSheet"))
        #expect(diff.removed.count == 1)
        #expect(diff.removed[0].hasPrefix("- e2@s1 AXButton \"Save\""))
        // The unchanged window appears nowhere.
        #expect(!diff.text.contains("AXWindow"))
        #expect(diff.totalElements == 3)
        #expect(diff.entryCount == 3)
    }

    @Test func identityChangeAtSamePathIsAddPlusRemove() throws {
        var tree = newTree()
        // Replace the text field with a button at the same locator path.
        let swapped = SnapshotElement(
            id: "e1@s2", role: "AXButton", label: "Clear",
            path: fieldPath, frame: [10, 10, 200, 30]
        )
        var elements = tree.elements
        elements[1] = swapped
        var lines = tree.text.components(separatedBy: "\n")
        lines[1] = "\te1@s2 AXButton \"Clear\" (10,10,200,30) actions=Press"
        tree = BuiltTree(text: lines.joined(separator: "\n"), elements: elements)

        let result = try #require(stabilizeTree(tree, against: previousSnapshot()))
        // Role mismatch at the path: no id carry, previous field reported gone.
        #expect(result.tree.elements[1].id == "e1@s2")
        #expect(result.diff.added.contains { $0.contains("AXButton \"Clear\"") })
        #expect(result.diff.removed.contains { $0.contains("e1@s1 AXTextField") })
    }

    @Test func missingPreviousTextMeansNoDiff() {
        var previous = previousSnapshot()
        previous.treeText = nil
        #expect(stabilizeTree(newTree(), against: previous) == nil)
    }
}
