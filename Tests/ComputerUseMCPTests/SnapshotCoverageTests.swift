import CoreGraphics
import Foundation
import Testing

@testable import computer_use_mcp

private struct CoverageNode {}

private func oneNodeAccessors(
    coverage: SnapshotCoverage = .complete,
    diagnostic: String? = nil
) -> TreeNodeAccessors<CoverageNode> {
    TreeNodeAccessors(
        facts: { _ in
            NodeFacts(
                role: "AXWindow", label: "Document", identifier: nil, value: nil,
                selectedText: nil, enabled: true, focused: false, selected: nil,
                actions: [], frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        },
        role: { _ in "AXWindow" },
        frame: { _ in nil },
        children: { _ in [] },
        visibleCollectionChildren: { _ in nil },
        collectionTotal: { _ in nil },
        equals: { _, _ in true },
        coverage: { coverage },
        coverageDiagnostic: { diagnostic })
}

private func coverageLineage(pid: pid_t) -> SnapshotLineage {
    SnapshotLineage(
        process: SnapshotProcessIdentity(
            pid: pid, bundleIdentifier: "com.example.coverage",
            startTimeMicroseconds: 4_000_000),
        windowID: 71)
}

private func coverageTree(
    generation: String, labels: [String], coverage: SnapshotCoverage = .complete
) -> BuiltTree {
    let elements = labels.enumerated().map { index, label in
        SnapshotElement(
            id: "e\(index)@\(generation)",
            role: index == 0 ? "AXWindow" : "AXButton",
            label: label,
            path: index == 0 ? [] : [LocatorStep(role: "AXButton", indexOfRole: index - 1)],
            frame: [Double(index * 20), 0, 80, 24])
    }
    let text = elements.map { "\($0.id) \($0.role) \"\($0.label ?? "")\"" }
        .joined(separator: "\n")
    return BuiltTree(text: text, elements: elements, coverage: coverage)
}

@Suite struct SnapshotCoverageTests {
    @Test func optionalAXSparsityDoesNotDegradeCoverage() {
        let recorder = AXTreeReadCoverageRecorder()

        recorder.record(.api(.attributeUnsupported), required: false)
        recorder.record(.api(.noValue), required: false)

        #expect(recorder.coverage == .complete)
    }

    @Test func failedRequiredOrRuntimeAXReadsDegradeCoverage() {
        let required = AXTreeReadCoverageRecorder()
        required.record(.api(.attributeUnsupported), required: true)
        #expect(required.coverage == .degraded)

        let runtime = AXTreeReadCoverageRecorder()
        runtime.record(.api(.cannotComplete), required: false)
        #expect(runtime.coverage == .degraded)
    }

    @Test func traversalCarriesReadCoverageAndDiagnostic() {
        let tree = buildTreeCore(
            root: CoverageNode(),
            accessors: oneNodeAccessors(
                coverage: .degraded, diagnostic: "AX read failed"),
            windowOrigin: .zero, pixelsPerPoint: 1, generation: "s1",
            pathPrefix: [], maxElements: 1, skeleton: false, windowCollections: true)

        #expect(tree.coverage == .degraded)
        #expect(tree.isPartial)
        #expect(tree.text.contains("AX read failed"))
    }

    @Test func revisionRaceRetriesOnceAndReturnsStableSecondTree() {
        var revisions: [UInt64] = [0, 1, 1, 1]
        var builds = 0
        let tree = buildTreeWithRevisionRetry(
            generation: "s1",
            revision: { revisions.removeFirst() },
            build: { generation in
                builds += 1
                return coverageTree(generation: generation, labels: ["build \(builds)"])
            })

        #expect(builds == 2)
        #expect(tree.coverage == .complete)
        #expect(tree.text.contains("build 2"))
    }

    @Test func secondRevisionRaceReturnsUnstableWithoutMoreRetries() {
        var revisions: [UInt64] = [0, 1, 1, 2]
        var builds = 0
        let tree = buildTreeWithRevisionRetry(
            generation: "s1",
            revision: { revisions.removeFirst() },
            build: { generation in
                builds += 1
                return coverageTree(generation: generation, labels: ["build \(builds)"])
            })

        #expect(builds == 2)
        #expect(tree.coverage == .unstable)
        #expect(tree.text.contains("changed during both capture attempts"))
    }

    @Test func incompleteCaptureIsNotChangeEvidence() {
        #expect(observedTreeChange(unchanged: false, coverage: .complete) == true)
        #expect(observedTreeChange(unchanged: true, coverage: .complete) == false)
        #expect(observedTreeChange(unchanged: false, coverage: .partial) == nil)
        #expect(observedTreeChange(unchanged: false, coverage: .degraded) == nil)
        #expect(observedTreeChange(unchanged: false, coverage: .unstable) == nil)
    }

    @Test func degradedCaptureCannotEmitRemovalDiffOrInvalidatePriorID() async throws {
        let pid: pid_t = -31_071
        await SnapshotStore.shared.resetForTesting(pid: pid)
        defer { Task { await SnapshotStore.shared.resetForTesting(pid: pid) } }
        let lineage = coverageLineage(pid: pid)

        let first = await SnapshotStore.shared.capture(
            pid: pid, bundleIdentifier: "com.example.coverage", windowTitle: "Document",
            windowID: 71, windowOrigin: .zero, pixelsPerPoint: 1,
            windowSize: [400, 300], createdAt: Date(timeIntervalSince1970: 1),
            lineageOverrideForTesting: lineage
        ) { generation in
            coverageTree(generation: generation, labels: ["Document", "Save"])
        }
        let saveID = try #require(first.tree.elements.last?.id)

        let degraded = await SnapshotStore.shared.capture(
            pid: pid, bundleIdentifier: "com.example.coverage", windowTitle: "Document",
            windowID: 71, windowOrigin: .zero, pixelsPerPoint: 1,
            windowSize: [400, 300], createdAt: Date(timeIntervalSince1970: 2),
            lineageOverrideForTesting: lineage
        ) { generation in
            coverageTree(
                generation: generation, labels: ["Document"], coverage: .degraded)
        }

        #expect(degraded.snapshot.coverage == .degraded)
        #expect(degraded.diff == nil)
        #expect(!degraded.unchanged)
        let resolved = await SnapshotStore.shared.resolveElementSnapshot(
            forPid: pid, elementID: saveID)
        #expect(resolved?.element.label == "Save")

        await SnapshotStore.shared.clearMemoryForTesting(pid: pid)
        let reloaded = try #require(await SnapshotStore.shared.load(forPid: pid))
        #expect(reloaded.effectiveCoverage == .degraded)
    }
}
