import ApplicationServices
import CoreGraphics
import Foundation
import Testing

@testable import computer_use_mcp

private func lineage(
    pid: Int32 = 42,
    bundle: String = "com.example.app",
    start: UInt64? = 1_000_000,
    windowID: UInt32? = 7
) -> SnapshotLineage {
    SnapshotLineage(
        process: SnapshotProcessIdentity(
            pid: pid, bundleIdentifier: bundle, startTimeMicroseconds: start),
        windowID: windowID)
}

@Suite struct SnapshotLineageTests {
    @Test func retainedWindowMustAppearInCurrentAXWindowList() {
        let retained = AXUIElementCreateApplication(101_001)
        let same = AXUIElementCreateApplication(101_001)
        let different = AXUIElementCreateApplication(101_002)

        #expect(containsAXElement(retained, in: [same]))
        #expect(!containsAXElement(retained, in: [different]))
        #expect(!containsAXElement(retained, in: []))
    }

    @Test func pidReuseWithDifferentProcessStartFailsClosed() {
        let decision = compareSnapshotLineage(
            persisted: lineage(start: 1_000_000),
            current: lineage(start: 2_000_000))

        #expect(decision == .conflict("the app process was replaced"))
    }

    @Test func pidReuseByDifferentBundleFailsEvenWithoutStartTimes() {
        let decision = compareSnapshotLineage(
            persisted: lineage(bundle: "com.example.old", start: nil, windowID: nil),
            current: lineage(bundle: "com.example.new", start: nil, windowID: nil))

        #expect(decision == .conflict("pid 42 now belongs to a different app"))
    }

    @Test func sameTitleWindowReplacementFailsOnWindowID() {
        let decision = compareSnapshotLineage(
            persisted: lineage(windowID: 7),
            current: lineage(windowID: 8))

        #expect(decision == .conflict("the target window was replaced"))
    }

    @Test func missingStrongIdentityIsExplicitlyUnavailableAndCompatible() {
        #expect(compareSnapshotLineage(
            persisted: lineage(start: nil, windowID: nil),
            current: lineage(start: nil, windowID: nil)) == .unavailable)
        #expect(compareSnapshotLineage(
            persisted: nil,
            current: lineage()) == .unavailable)
    }

    @Test func matchingStrongIdentityIsCompatible() {
        #expect(compareSnapshotLineage(
            persisted: lineage(),
            current: lineage()) == .compatible)
    }

    @Test func mutationRequiresAvailableStrongIdentity() {
        #expect(throws: ToolError.self) {
            try enforceSnapshotIdentityDecision(
                .unavailable, requirement: .mutation, generation: "s4")
        }
    }

    @Test func readOnlyResolutionAllowsUnavailableStrongIdentity() throws {
        try enforceSnapshotIdentityDecision(
            .unavailable, requirement: .bestEffort, generation: "s4")
    }

    @Test func bothPoliciesRejectPositiveIdentityConflicts() {
        for requirement in [SnapshotIdentityRequirement.bestEffort, .mutation] {
            #expect(throws: ToolError.self) {
                try enforceSnapshotIdentityDecision(
                    .conflict("the target window was replaced"),
                    requirement: requirement, generation: "s4")
            }
        }
    }

    @Test func elementPointContextUsesCapturedWindowAmongDuplicateTitles() {
        let candidates = [
            WindowIdentityCandidate(windowID: 11, title: "Document"),
            WindowIdentityCandidate(windowID: 17, title: "Document"),
        ]

        let selected = exactWindowIdentityIndex(
            snapshotWindowID: 17, candidates: candidates)
        #expect(selected == 1)
        let selectedWindowID = selected.flatMap { candidates[$0].windowID }
        let context = pointDeliveryContext(
            pid: 42, windowNumber: selectedWindowID,
            windowFrame: CGRect(x: 20, y: 20, width: 400, height: 300),
            allowGlobalCursor: false)
        #expect(context.windowNumber == 17)
    }

    @Test func coordinatePointContextUsesCapturedWindowAmongDuplicateTitles() {
        let candidates = [
            WindowIdentityCandidate(windowID: 11, title: "Document"),
            WindowIdentityCandidate(windowID: 17, title: "Document"),
        ]

        let selected = exactWindowIdentityIndex(
            snapshotWindowID: 17, candidates: candidates)
        #expect(selected == 1)
        let selectedWindowID = selected.flatMap { candidates[$0].windowID }
        let context = pointDeliveryContext(
            pid: 42, windowNumber: selectedWindowID,
            windowFrame: CGRect(x: 20, y: 20, width: 400, height: 300),
            allowGlobalCursor: false)
        #expect(context.windowNumber == 17)
    }

    @Test func missingCapturedWindowIdentityDoesNotFallBackByTitle() {
        let candidates = [
            WindowIdentityCandidate(windowID: 11, title: "Document"),
            WindowIdentityCandidate(windowID: 17, title: "Document"),
        ]

        #expect(exactWindowIdentityIndex(
            snapshotWindowID: 23, candidates: candidates) == nil)
        #expect(throws: ToolError.self) {
            _ = try requireExactWindowIdentityIndex(
                snapshotWindowID: 23, candidates: candidates,
                appName: "Example")
        }
    }

    @Test func freshDuplicateTitleSameFrameCaptureKeepsExactWindowIdentity() async {
        let pid: pid_t = 72_017
        await SnapshotStore.shared.clearMemoryForTesting(pid: pid)
        let result = await SnapshotStore.shared.capture(
            pid: pid, bundleIdentifier: "com.example.duplicate", windowTitle: "Document",
            windowID: 17, windowOrigin: .zero, pixelsPerPoint: 1,
            windowSize: [400, 300], createdAt: Date(timeIntervalSince1970: 3)
        ) { generation in
            BuiltTree(
                text: "e0@\(generation) AXWindow Document",
                elements: [
                    CapturedNode(
                        id: "e0@\(generation)", role: "AXWindow", label: "Document",
                        frame: [0, 0, 400, 300])
                ])
        }

        #expect(result.snapshot.lineage?.windowID == 17)
        await SnapshotStore.shared.clearMemoryForTesting(pid: pid)
    }

    @Test func scopedStateKeepsResolvedWindowAmongDuplicateTitles() {
        let candidates = [
            WindowIdentityCandidate(windowID: 11, title: "Document"),
            WindowIdentityCandidate(windowID: 17, title: "Document"),
        ]

        #expect(exactWindowIdentityIndex(
            snapshotWindowID: 17, candidates: candidates) == 1)
        #expect(throws: ToolError.self) {
            _ = try requireExactWindowIdentityIndex(
                snapshotWindowID: 23, candidates: candidates,
                appName: "Example")
        }
    }

    @Test func dragKeepsCapturedWindowAmongDuplicateTitles() {
        let candidates = [
            WindowIdentityCandidate(windowID: 11, title: "Document"),
            WindowIdentityCandidate(windowID: 17, title: "Document"),
        ]

        let selected = exactWindowIdentityIndex(
            snapshotWindowID: 17, candidates: candidates)
        #expect(selected == 1)
        #expect(selected.map { candidates[$0].windowID } == 17)
    }

    @Test func readOnlyResolutionPrefersCapturedWindowAmongDuplicateTitles() {
        let candidates = [
            WindowIdentityCandidate(windowID: 11, title: "Document"),
            WindowIdentityCandidate(windowID: 17, title: "Document"),
        ]

        let selected = exactWindowIdentityIndex(
            snapshotWindowID: 17, candidates: candidates)
        #expect(selected == 1)
        #expect(selected.map { candidates[$0].windowID } == 17)
    }
}
