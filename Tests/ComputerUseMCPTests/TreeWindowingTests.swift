import ApplicationServices
import Foundation
import Testing

@testable import computer_use_mcp

// An in-memory node so the generic traversal core can be exercised without a
// live accessibility tree. Mirrors just the facts the outline reads.
private final class FakeNode {
    var role: String
    var label: String?
    var value: String?
    var frame: CGRect?
    var children: [FakeNode]
    /// When set, stands in for AXVisibleRows: the app's own on-screen slice.
    var visibleChildren: [FakeNode]?
    /// When set, stands in for AXRows.count: total items regardless of how many
    /// children are realized.
    var collectionTotal: Int?

    init(
        _ role: String, label: String? = nil, value: String? = nil, frame: CGRect? = nil,
        children: [FakeNode] = []
    ) {
        self.role = role
        self.label = label
        self.value = value
        self.frame = frame
        self.children = children
    }
}

private func fakeAccessors() -> TreeNodeAccessors<FakeNode> {
    TreeNodeAccessors<FakeNode>(
        facts: { node in
            NodeFacts(
                role: node.role, label: node.label, identifier: nil, value: node.value,
                selectedText: nil, enabled: nil, focused: nil, selected: nil,
                actions: [], frame: node.frame)
        },
        role: { $0.role },
        frame: { $0.frame },
        children: { $0.children },
        visibleCollectionChildren: { $0.visibleChildren },
        collectionTotal: { $0.collectionTotal },
        equals: { $0 === $1 },
        handle: { node in
            let token = UInt(bitPattern: ObjectIdentifier(node)) % UInt(Int32.max)
            return AXUIElementCreateApplication(pid_t(token))
        }
    )
}

/// Builds a window → group → group → outline("row-list") tree of `rowCount`
/// rows, each an AXRow → AXCell → AXStaticText "Row NNN", matching the fixture.
private func rowListTree(rowCount: Int, visible: Range<Int>? = nil, total: Int? = nil) -> FakeNode {
    var rows: [FakeNode] = []
    for i in 1...rowCount {
        let label = String(format: "Row %03d", i)
        let text = FakeNode("AXStaticText", value: label, frame: CGRect(x: 0, y: Double(i) * 24, width: 200, height: 24))
        let cell = FakeNode("AXCell", frame: text.frame, children: [text])
        let row = FakeNode("AXRow", frame: text.frame, children: [cell])
        rows.append(row)
    }
    let outline = FakeNode(
        "AXOutline", label: "row-list", frame: CGRect(x: 0, y: 0, width: 300, height: 300),
        children: rows)
    outline.collectionTotal = total ?? rowCount
    if let visible { outline.visibleChildren = Array(rows[visible]) }
    let inner = FakeNode("AXScrollArea", children: [outline])
    let outer = FakeNode("AXScrollArea", children: [inner])
    return FakeNode("AXWindow", label: "Fixture", children: [outer])
}

private func build(
    _ root: FakeNode, generation: String, maxElements: Int = defaultMaxTreeElements,
    skeleton: Bool = false, windowCollections: Bool = true
) -> BuiltTree {
    buildTreeCore(
        root: root, accessors: fakeAccessors(),
        windowOrigin: .zero, pixelsPerPoint: 1, generation: generation,
        maxElements: maxElements, skeleton: skeleton,
        windowCollections: windowCollections)
}

@Suite struct ViewportVisibleIndicesTests {
    @Test func keepsChildrenIntersectingTheViewportPlusMargin() {
        let viewport = CGRect(x: 0, y: 100, width: 300, height: 100)  // 100..200
        let frames: [CGRect?] = [
            CGRect(x: 0, y: 0, width: 10, height: 10),  // 0..10, far above
            CGRect(x: 0, y: 90, width: 10, height: 10),  // 90..100, inside margin
            CGRect(x: 0, y: 140, width: 10, height: 10),  // in viewport
            CGRect(x: 0, y: 400, width: 10, height: 10),  // far below
        ]
        let included = viewportVisibleIndices(childFrames: frames, viewport: viewport, margin: 20)
        #expect(included == [1, 2])
    }

    @Test func unknownFrameIsAlwaysIncluded() {
        let viewport = CGRect(x: 0, y: 100, width: 300, height: 100)
        let included = viewportVisibleIndices(
            childFrames: [nil, CGRect(x: 0, y: 9000, width: 1, height: 1)], viewport: viewport, margin: 0)
        // The nil-frame child survives; the far-off one is dropped.
        #expect(included.contains(0))
        #expect(!included.contains(1))
    }
}

@Suite struct DenseCollectionWindowingTests {
    @Test func visibleRowsSliceIsMaterializedAsCapturedChildren() {
        // 500 rows, app reports rows 200..212 (0-based) on screen.
        let tree = rowListTree(rowCount: 500, visible: 200..<213, total: 500)
        let built = build(tree, generation: "s1")

        let rows = built.elements.filter { $0.role == "AXRow" }
        #expect(rows.count == 13)

        // The materialized rows are the visible slice, not a Row-001 prefix.
        let values = built.text
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard let range = line.range(of: #"Row \d\d\d"#, options: .regularExpression) else {
                    return nil
                }
                return String(line[range])
            }
        #expect(values.first == "Row 201")
        #expect(values.last == "Row 213")

        #expect(rows.first?.parent?.role == "AXOutline")

        // Off-screen rows are summarized, not silently dropped.
        #expect(built.text.contains("487 more rows off-screen"))
    }

    @Test func smallCollectionsAreNotWindowed() {
        let tree = rowListTree(rowCount: 20, total: 20)
        let built = build(tree, generation: "s1")
        #expect(built.elements.filter { $0.role == "AXRow" }.count == 20)
        #expect(!built.text.contains("off-screen"))
    }

    @Test func frameFallbackWindowsWhenNoVisibleRowsProvided() {
        // No visibleChildren set → viewport-frame intersection. Rows are 24pt
        // tall stacked from y=24; the outline viewport is y 0..300 (+150
        // margin), so rows up to ~y=450 survive.
        let tree = rowListTree(rowCount: 300, total: 300)
        let built = build(tree, generation: "s1")
        let rows = built.elements.filter { $0.role == "AXRow" }
        #expect(rows.count < 300)  // windowed
        #expect(rows.count > 0)
        #expect(rows.first?.parent?.role == "AXOutline")
        #expect(built.text.contains("off-screen"))
    }

    @Test func windowingDisabledMaterializesEveryRowUpToBudget() {
        // Non-windowed callers (find / skill-replay) are bounded only by the
        // element budget, not the per-node cap: every one of the 500 rows must
        // materialize so a deep row is reachable, and no viewport summary.
        let tree = rowListTree(rowCount: 500, visible: 0..<13, total: 500)
        let built = build(tree, generation: "s1", maxElements: 5000, windowCollections: false)
        let rows = built.elements.filter { $0.role == "AXRow" }
        #expect(rows.count == 500)
        // The last row is present in the nested captured tree and text.
        #expect(rows.last?.parent?.role == "AXOutline")
        #expect(built.text.contains("Row 500"))
        #expect(!built.text.contains("off-screen"))
    }

    @Test func windowingDisabledStillHonorsTheElementBudget() {
        // The budget, not the per-node cap, is the bound: a tight budget stops
        // materialization partway rather than letting one node run unbounded.
        let tree = rowListTree(rowCount: 500, visible: 0..<13, total: 500)
        let built = build(tree, generation: "s1", maxElements: 60, windowCollections: false)
        #expect(built.elements.count <= 60)
        #expect(built.text.contains("tree truncated at 60 elements"))
    }
}

@Suite struct SkeletonTraversalTests {
    @Test func deepCollectionCollapsesToChildrenCountDrillTarget() {
        let tree = rowListTree(rowCount: 500, visible: 0..<13, total: 500)
        let skeleton = build(tree, generation: "s1", skeleton: true)

        // The outline is emitted but its rows are not.
        let outline = try! #require(skeleton.elements.first { $0.role == "AXOutline" })
        #expect(outline.label == "row-list")
        #expect(skeleton.elements.allSatisfy { $0.role != "AXRow" })

        // It carries a children_count so the agent knows to drill in.
        let outlineLine = try! #require(
            skeleton.text.split(separator: "\n").first { $0.contains(outline.id) })
        #expect(outlineLine.contains("children_count=500"))
    }

    @Test func skeletonThenScopedRoundTripYieldsValidDeepIDs() {
        let tree = rowListTree(rowCount: 500, visible: 200..<213, total: 500)

        // 1) Skeleton overview: find the collapsed captured container.
        let skeleton = build(tree, generation: "s1", skeleton: true)
        let outline = try! #require(skeleton.elements.first { $0.role == "AXOutline" })
        #expect(outline.parent?.role == "AXScrollArea")

        // 2) Scope to the retained handle's corresponding source subtree.
        let scopeRoot = tree.children[0].children[0].children[0]
        #expect(scopeRoot.role == "AXOutline")

        let scoped = build(scopeRoot, generation: "s2")

        // 3) A row is now materialized under a valid current-generation id, and
        //    it is a child of the scoped root.
        let row = try! #require(scoped.elements.first { $0.role == "AXRow" })
        #expect(row.id.hasSuffix("@s2"))
        #expect(row.parent === scoped.root)
    }
}

@Suite struct WindowedResnapshotIdentityTests {
    /// Re-snapshotting an unchanged windowed list must carry every id forward
    /// so references the agent already holds stay valid by AX handle identity.
    @Test func unchangedWindowedListKeepsIDs() throws {
        let tree = rowListTree(rowCount: 500, visible: 100..<113, total: 500)
        let first = build(tree, generation: "s1")

        let previous = AppSnapshot(
            pid: 1, bundleIdentifier: "com.example", windowTitle: "Fixture",
            windowOrigin: [0, 0], pixelsPerPoint: 1, windowSize: [300, 300],
            createdAt: Date(timeIntervalSince1970: 0), generation: "s1",
            treeFingerprint: treeFingerprint(first.text), treeText: first.text, scoped: false,
            elements: first.elements)

        // A fresh capture of the same tree mints s2 ids; stabilization must
        // restore the s1 ids for every surviving element and report no changes.
        let second = build(tree, generation: "s2")
        let result = try #require(stabilizeTree(second, against: previous))

        #expect(result.tree.elements.count == first.elements.count)
        for (new, old) in zip(result.tree.elements, first.elements) {
            #expect(new.id == old.id)
            #expect(CFEqual(new.handle, old.handle))
        }
        #expect(result.diff.entryCount == 0)
    }
}

/// Wraps a non-windowed BuiltTree in an AppSnapshot, exactly as find and
/// refreshSkillSnapshot do, so the real resolveSkillLocator can be exercised.
private func snapshot(from tree: BuiltTree) -> AppSnapshot {
    AppSnapshot(
        pid: 1, bundleIdentifier: "com.example", windowTitle: "Fixture",
        windowOrigin: [0, 0], pixelsPerPoint: 1, windowSize: [300, 300],
        createdAt: Date(timeIntervalSince1970: 0), generation: "s1",
        treeFingerprint: treeFingerprint(tree.text), treeText: tree.text, scoped: false,
        elements: tree.elements)
}

@Suite struct FindAndReplayDeepRowTests {
    /// find builds a non-windowed tree and matches against its text lines; a
    /// deep collection row must appear so `find "Row 400"` can hit it.
    @Test func findMatchesADeepCollectionRow() {
        let tree = rowListTree(rowCount: 500, total: 500)
        let built = build(tree, generation: "s1", maxElements: 5000, windowCollections: false)
        let matchingLines = built.text
            .split(separator: "\n")
            .filter { $0.lowercased().contains("row 400") }
        #expect(!matchingLines.isEmpty)
    }

    @Test func unlabeledDeepRowsRemainAmbiguousForDurableSkills() {
        let tree = rowListTree(rowCount: 500, total: 500)
        let built = build(tree, generation: "s1", maxElements: 5000, windowCollections: false)

        let resolution = resolveSkillLocator(
            SkillLocator(role: "AXRow"), in: snapshot(from: built))
        guard case .failed(let reason) = resolution else {
            Issue.record("expected unlabeled rows to remain ambiguous")
            return
        }
        #expect(reason.contains("ambiguous"))
    }

    /// The regression guard: with the old per-node cap a row past 150 would be
    /// absent and resolution would fail. Prove that a windowed snapshot (the
    /// wrong build for replay) indeed cannot resolve a deep row — documenting
    /// why find/skill-replay must build non-windowed.
    @Test func windowedSnapshotCannotResolveAnOffscreenRow() {
        let tree = rowListTree(rowCount: 500, visible: 0..<13, total: 500)
        let windowed = build(tree, generation: "s1")  // windowed: only 13 rows
        let locator = SkillLocator(role: "AXRow", label: "Row 300")
        guard case .failed = resolveSkillLocator(locator, in: snapshot(from: windowed)) else {
            Issue.record("windowed snapshot unexpectedly resolved an off-screen row")
            return
        }
    }
}
