import ApplicationServices
import Foundation
import Testing

@testable import computer_use_mcp

private func liveTestHandle(_ token: pid_t) -> AXUIElement {
    AXUIElementCreateApplication(token)
}

private func liveTestFingerprint(role: String = "AXButton", label: String? = "Save") -> ElementFingerprint {
    ElementFingerprint(role: role, subrole: nil, identifier: nil, stableLabel: label)
}

private func liveTestTree(
    generation: String, handle: AXUIElement, role: String = "AXButton",
    label: String? = "Save", value: String? = nil
) -> BuiltTree {
    let node = CapturedNode(
        id: "e0@\(generation)", role: role, label: label,
        fingerprint: liveTestFingerprint(role: role, label: label),
        frame: [0, 0, 80, 24], handle: handle)
    var line = "e0@\(generation) \(role)"
    if let label { line += " \"\(label)\"" }
    if let value { line += " value=\"\(value)\"" }
    return BuiltTree(text: line, root: node, elements: [node])
}

private func liveTestLineage(pid: pid_t, windowID: UInt32?) -> SnapshotLineage {
    SnapshotLineage(
        process: SnapshotProcessIdentity(
            pid: pid, bundleIdentifier: "com.example.live-snapshot",
            startTimeMicroseconds: 123),
        windowID: windowID)
}

@Suite(.serialized) struct LiveSnapshotStoreTests {
    @Test func captureIndexesNodesByIDAndHandle() async throws {
        let pid: pid_t = 71_001
        let handle = AXHandleKey(element: liveTestHandle(81_001))
        let store = SnapshotStore.shared
        await store.resetForTesting(pid: pid)

        let result = await store.capture(
            pid: pid, bundleIdentifier: "com.example.live-snapshot", windowTitle: "Document",
            windowID: 10, windowElement: liveTestHandle(pid),
            windowOrigin: .zero, pixelsPerPoint: 2, windowSize: [800, 600],
            createdAt: Date(), lineageOverrideForTesting: liveTestLineage(pid: pid, windowID: 10)
        ) { generation in
            liveTestTree(generation: generation, handle: handle.element)
        }

        let node = try #require(result.snapshot.element(withID: result.tree.elements[0].id))
        #expect(CFEqual(node.handle, handle.element))
        #expect(result.snapshot.idsByHandle[handle] == node.id)
    }

    @Test func sameHandleCarriesIDAcrossCaptures() async throws {
        let pid: pid_t = 71_002
        let handle = AXHandleKey(element: liveTestHandle(81_002))
        let store = SnapshotStore.shared
        await store.resetForTesting(pid: pid)
        let lineage = liveTestLineage(pid: pid, windowID: 11)

        let first = await store.capture(
            pid: pid, bundleIdentifier: "com.example.live-snapshot", windowTitle: "Document",
            windowID: 11, windowElement: liveTestHandle(pid),
            windowOrigin: .zero, pixelsPerPoint: 2, windowSize: [800, 600],
            createdAt: Date(), lineageOverrideForTesting: lineage
        ) { generation in
            liveTestTree(generation: generation, handle: handle.element, value: "before")
        }
        let second = await store.capture(
            pid: pid, bundleIdentifier: "com.example.live-snapshot", windowTitle: "Document",
            windowID: 11, windowElement: liveTestHandle(pid),
            windowOrigin: .zero, pixelsPerPoint: 2, windowSize: [800, 600],
            createdAt: Date(), lineageOverrideForTesting: lineage
        ) { generation in
            liveTestTree(generation: generation, handle: handle.element, value: "after")
        }

        #expect(second.tree.elements[0].id == first.tree.elements[0].id)
        #expect(second.diff?.changed.count == 1)
        #expect(second.diff?.added.isEmpty == true)
        #expect(second.diff?.removed.isEmpty == true)
    }

    @Test func recreatedHandleIsRemoveAddAndOldIDExpires() async throws {
        let pid: pid_t = 71_003
        let store = SnapshotStore.shared
        await store.resetForTesting(pid: pid)
        let lineage = liveTestLineage(pid: pid, windowID: 12)

        let first = await store.capture(
            pid: pid, bundleIdentifier: "com.example.live-snapshot", windowTitle: "Document",
            windowID: 12, windowElement: liveTestHandle(pid),
            windowOrigin: .zero, pixelsPerPoint: 1, windowSize: [400, 300],
            createdAt: Date(), lineageOverrideForTesting: lineage
        ) { generation in
            liveTestTree(generation: generation, handle: liveTestHandle(81_003))
        }
        let oldID = first.tree.elements[0].id
        let second = await store.capture(
            pid: pid, bundleIdentifier: "com.example.live-snapshot", windowTitle: "Document",
            windowID: 12, windowElement: liveTestHandle(pid),
            windowOrigin: .zero, pixelsPerPoint: 1, windowSize: [400, 300],
            createdAt: Date(), lineageOverrideForTesting: lineage
        ) { generation in
            liveTestTree(generation: generation, handle: liveTestHandle(81_004))
        }

        #expect(second.tree.elements[0].id != oldID)
        #expect(second.diff?.added.count == 1)
        #expect(second.diff?.removed.count == 1)
        #expect(await store.resolveElementSnapshot(forPid: pid, elementID: oldID) == nil)
    }

    @Test func screenshotScaleChangeKeepsHandleIdentityButReturnsFullTree() async throws {
        let pid: pid_t = 71_005
        let handle = AXHandleKey(element: liveTestHandle(81_005))
        let store = SnapshotStore.shared
        await store.resetForTesting(pid: pid)
        let lineage = liveTestLineage(pid: pid, windowID: 13)

        let first = await store.capture(
            pid: pid, bundleIdentifier: "com.example.live-snapshot", windowTitle: "Document",
            windowID: 13, windowElement: liveTestHandle(pid),
            windowOrigin: .zero, pixelsPerPoint: 1, windowSize: [400, 300],
            createdAt: Date(), lineageOverrideForTesting: lineage
        ) { generation in
            liveTestTree(generation: generation, handle: handle.element)
        }
        let second = await store.capture(
            pid: pid, bundleIdentifier: "com.example.live-snapshot", windowTitle: "Document",
            windowID: 13, windowElement: liveTestHandle(pid),
            windowOrigin: .zero, pixelsPerPoint: 2, windowSize: [800, 600],
            createdAt: Date(), lineageOverrideForTesting: lineage
        ) { generation in
            liveTestTree(generation: generation, handle: handle.element)
        }

        #expect(second.tree.elements[0].id == first.tree.elements[0].id)
        #expect(second.diff == nil)
        #expect(second.unchanged == false)
    }

    @Test func partialCaptureRetainsUnobservedLiveIDsForLaterValidation() async throws {
        let pid: pid_t = 71_007
        let store = SnapshotStore.shared
        await store.resetForTesting(pid: pid)
        let lineage = liveTestLineage(pid: pid, windowID: 14)
        let window = AXHandleKey(element: liveTestHandle(91_008))
        let save = AXHandleKey(element: liveTestHandle(82_008))
        let cancel = AXHandleKey(element: liveTestHandle(82_009))

        func tree(_ generation: String, includeCancel: Bool, coverage: SnapshotCoverage) -> BuiltTree {
            let saveNode = CapturedNode(
                id: "e0@\(generation)", role: "AXButton", label: "Save",
                fingerprint: liveTestFingerprint(label: "Save"), frame: [0, 0, 80, 24],
                handle: save.element)
            var nodes = [saveNode]
            if includeCancel {
                nodes.append(CapturedNode(
                    id: "e1@\(generation)", role: "AXButton", label: "Cancel",
                    fingerprint: liveTestFingerprint(label: "Cancel"), frame: [90, 0, 80, 24],
                    handle: cancel.element))
            }
            return BuiltTree(
                text: nodes.map { "\($0.id) \($0.role) \"\($0.label!)\"" }.joined(separator: "\n"),
                root: saveNode, elements: nodes, coverage: coverage)
        }

        let first = await store.capture(
            pid: pid, bundleIdentifier: "com.example.live-snapshot", windowTitle: "Document",
            windowID: 14, windowElement: window.element,
            windowOrigin: .zero, pixelsPerPoint: 1, windowSize: [400, 300],
            createdAt: Date(), lineageOverrideForTesting: lineage
        ) { generation in tree(generation, includeCancel: true, coverage: .complete) }
        let cancelID = first.tree.elements[1].id

        _ = await store.capture(
            pid: pid, bundleIdentifier: "com.example.live-snapshot", windowTitle: "Document",
            windowID: 14, windowElement: window.element,
            windowOrigin: .zero, pixelsPerPoint: 1, windowSize: [400, 300],
            createdAt: Date(), lineageOverrideForTesting: lineage
        ) { generation in tree(generation, includeCancel: false, coverage: .partial) }
        #expect(await store.resolveElementSnapshot(forPid: pid, elementID: cancelID) != nil)

        let completeAgain = await store.capture(
            pid: pid, bundleIdentifier: "com.example.live-snapshot", windowTitle: "Document",
            windowID: 14, windowElement: window.element,
            windowOrigin: .zero, pixelsPerPoint: 1, windowSize: [400, 300],
            createdAt: Date(), lineageOverrideForTesting: lineage
        ) { generation in tree(generation, includeCancel: true, coverage: .complete) }
        #expect(completeAgain.tree.elements[1].id == cancelID)
    }

    @Test func processWindowPairsKeepIndependentCurrentSnapshots() async throws {
        let pid: pid_t = 71_004
        let store = SnapshotStore.shared
        await store.resetForTesting(pid: pid)

        let first = await store.capture(
            pid: pid, bundleIdentifier: "com.example.live-snapshot", windowTitle: "One",
            windowID: 20, windowElement: liveTestHandle(91_001),
            windowOrigin: .zero, pixelsPerPoint: 1, windowSize: [100, 100],
            createdAt: Date(), lineageOverrideForTesting: liveTestLineage(pid: pid, windowID: 20)
        ) { generation in
            liveTestTree(generation: generation, handle: liveTestHandle(82_001), label: "One")
        }
        let second = await store.capture(
            pid: pid, bundleIdentifier: "com.example.live-snapshot", windowTitle: "Two",
            windowID: 21, windowElement: liveTestHandle(91_002),
            windowOrigin: .zero, pixelsPerPoint: 1, windowSize: [100, 100],
            createdAt: Date(), lineageOverrideForTesting: liveTestLineage(pid: pid, windowID: 21)
        ) { generation in
            liveTestTree(generation: generation, handle: liveTestHandle(82_002), label: "Two")
        }

        #expect(await store.load(forPid: pid)?.generation == second.snapshot.generation)
        #expect(await store.resolveElementSnapshot(
            forPid: pid, elementID: first.tree.elements[0].id) != nil)
    }

    @Test func windowsWithoutCGIDsUseTheirExactWindowHandlesAsKeys() async throws {
        let pid: pid_t = 71_006
        let store = SnapshotStore.shared
        await store.resetForTesting(pid: pid)
        let lineage = liveTestLineage(pid: pid, windowID: nil)

        let first = await store.capture(
            pid: pid, bundleIdentifier: "com.example.live-snapshot", windowTitle: "One",
            windowID: nil, windowElement: liveTestHandle(91_006),
            windowOrigin: .zero, pixelsPerPoint: 1, windowSize: [100, 100],
            createdAt: Date(), lineageOverrideForTesting: lineage
        ) { generation in
            liveTestTree(generation: generation, handle: liveTestHandle(82_006), label: "One")
        }
        let second = await store.capture(
            pid: pid, bundleIdentifier: "com.example.live-snapshot", windowTitle: "Two",
            windowID: nil, windowElement: liveTestHandle(91_007),
            windowOrigin: .zero, pixelsPerPoint: 1, windowSize: [100, 100],
            createdAt: Date(), lineageOverrideForTesting: lineage
        ) { generation in
            liveTestTree(generation: generation, handle: liveTestHandle(82_007), label: "Two")
        }

        #expect(await store.load(forPid: pid)?.generation == second.snapshot.generation)
        #expect(await store.resolveElementSnapshot(
            forPid: pid, elementID: first.tree.elements[0].id) != nil)
    }
}
