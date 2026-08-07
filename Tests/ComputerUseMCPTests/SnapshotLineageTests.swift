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

private func lineageSnapshot(_ lineage: SnapshotLineage?) -> AppSnapshot {
    AppSnapshot(
        pid: 42,
        bundleIdentifier: "com.example.app",
        windowTitle: "Document",
        windowOrigin: [0, 0],
        pixelsPerPoint: 2,
        windowSize: [800, 600],
        createdAt: Date(timeIntervalSince1970: 1),
        generation: "s1",
        treeFingerprint: "fingerprint",
        treeText: "e0@s1 AXWindow",
        scoped: false,
        partial: false,
        lineage: lineage,
        elements: [])
}

@Suite struct SnapshotLineageTests {
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
        #expect(snapshotLineagesAreCompatible(nil, lineage()))
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

    @Test func legacySnapshotWithoutLineageStillDecodes() throws {
        let encoded = try JSONEncoder().encode(lineageSnapshot(lineage()))
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "lineage")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppSnapshot.self, from: legacyData)

        #expect(decoded.lineage == nil)
        #expect(decoded.pid == 42)
        #expect(decoded.generation == "s1")
    }

    @Test func identicalFreshCaptureReplacesLegacyIDsBeforeAssigningStrongLineage() async throws {
        let pid: pid_t = -20_001
        await SnapshotStore.shared.resetForTesting(pid: pid)
        defer { Task { await SnapshotStore.shared.resetForTesting(pid: pid) } }

        let path = [LocatorStep(role: "AXButton", indexOfRole: 0)]
        let elements = [
            SnapshotElement(
                id: "e0@s1", role: "AXWindow", label: "Document",
                path: [], frame: [0, 0, 400, 300]),
            SnapshotElement(
                id: "e1@s1", role: "AXButton", label: "Save",
                path: path, frame: [20, 20, 80, 24]),
        ]
        let legacyText =
            "e0@s1 AXWindow \"Document\" (0,0,400,300)\n"
            + "\te1@s1 AXButton \"Save\" (20,20,80,24)"
        let legacy = AppSnapshot(
            pid: pid, bundleIdentifier: "com.example.app", windowTitle: "Document",
            windowOrigin: [0, 0], pixelsPerPoint: 1, windowSize: [400, 300],
            createdAt: Date(timeIntervalSince1970: 1), generation: "s1",
            treeFingerprint: treeFingerprint(legacyText), treeText: legacyText,
            scoped: false, partial: false, lineage: nil, elements: elements)
        await SnapshotStore.shared.seedForTesting(legacy)

        let strong = lineage(pid: pid, start: 3_000_000, windowID: 17)
        let result = await SnapshotStore.shared.capture(
            pid: pid, bundleIdentifier: "com.example.app", windowTitle: "Document",
            windowID: 17,
            windowOrigin: .zero, pixelsPerPoint: 1, windowSize: [400, 300],
            createdAt: Date(timeIntervalSince1970: 2),
            lineageOverrideForTesting: strong
        ) { generation in
            let freshText =
                "e0@\(generation) AXWindow \"Document\" (0,0,400,300)\n"
                + "\te1@\(generation) AXButton \"Save\" (20,20,80,24)"
            return BuiltTree(
                text: freshText,
                elements: [
                    SnapshotElement(
                        id: "e0@\(generation)", role: "AXWindow", label: "Document",
                        path: [], frame: [0, 0, 400, 300]),
                    SnapshotElement(
                        id: "e1@\(generation)", role: "AXButton", label: "Save",
                        path: path, frame: [20, 20, 80, 24]),
                ])
        }

        #expect(!result.unchanged)
        #expect(result.snapshot.generation == "s2")
        #expect(result.tree.elements.map(\.id) == ["e0@s2", "e1@s2"])
        #expect(result.snapshot.lineage == strong)
        let oldInMemory = await SnapshotStore.shared.resolveElementSnapshot(
            forPid: pid, elementID: "e1@s1")
        #expect(oldInMemory?.element.id == nil)

        await SnapshotStore.shared.clearMemoryForTesting(pid: pid)
        let reloaded = try #require(await SnapshotStore.shared.load(forPid: pid))
        #expect(reloaded.generation == "s2")
        #expect(reloaded.elements.map(\.id) == ["e0@s2", "e1@s2"])
        #expect(reloaded.lineage == strong)
        let oldReloaded = await SnapshotStore.shared.resolveElementSnapshot(
            forPid: pid, elementID: "e1@s1")
        #expect(oldReloaded?.element.id == nil)
        try enforceSnapshotIdentityDecision(
            compareSnapshotLineage(persisted: reloaded.lineage, current: strong),
            requirement: .mutation, generation: reloaded.generation)
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
                    SnapshotElement(
                        id: "e0@\(generation)", role: "AXWindow", label: "Document",
                        path: [], frame: [0, 0, 400, 300])
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
