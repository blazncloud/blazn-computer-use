import CoreGraphics
import Foundation
import Testing

@testable import computer_use_mcp

private func fingerprint(
    role: String = "AXButton",
    subrole: String? = nil,
    identifier: String? = "save-button",
    label: String? = "Save"
) -> ElementFingerprint {
    ElementFingerprint(
        role: role, subrole: subrole,
        identifier: identifier, stableLabel: label)
}

private final class LocatorNode {
    let fingerprint: ElementFingerprint
    let children: [LocatorNode]

    init(_ fingerprint: ElementFingerprint, children: [LocatorNode] = []) {
        self.fingerprint = fingerprint
        self.children = children
    }
}

private func fingerprintTree(
    generation: String, buttonFingerprint: ElementFingerprint,
    renderedSuffix: String = ""
) -> BuiltTree {
    let rootFingerprint = ElementFingerprint(
        role: "AXWindow", subrole: "AXStandardWindow",
        identifier: nil, stableLabel: nil)
    return BuiltTree(
        text: "e0@\(generation) AXWindow \"Document\"\n"
            + "\te1@\(generation) AXButton \"Save\"\(renderedSuffix)",
        elements: [
            SnapshotElement(
                id: "e0@\(generation)", role: "AXWindow", label: "Document",
                fingerprint: rootFingerprint, path: [], frame: [0, 0, 400, 300]),
            SnapshotElement(
                id: "e1@\(generation)", role: "AXButton", label: "Save",
                fingerprint: buttonFingerprint,
                path: [LocatorStep(role: "AXButton", indexOfRole: 0)],
                frame: [20, 20, 80, 24]),
        ])
}

@Suite struct ElementFingerprintTests {
    @Test func sameCapturedFingerprintMatchesARecreatedHandle() {
        let expected = fingerprint(subrole: "AXDefaultButton")
        let recreated = fingerprint(subrole: "AXDefaultButton")

        #expect(validateElementFingerprint(
            expected: expected, live: recreated,
            requireIdentityEvidence: true) == .match)
    }

    @Test func everyCapturedFingerprintFieldMustStillMatch() {
        let expected = fingerprint(subrole: "AXDefaultButton")

        #expect(validateElementFingerprint(
            expected: expected,
            live: fingerprint(role: "AXCheckBox", subrole: "AXDefaultButton"),
            requireIdentityEvidence: true) != .match)
        #expect(validateElementFingerprint(
            expected: expected,
            live: fingerprint(subrole: "AXCancelButton"),
            requireIdentityEvidence: true) != .match)
        #expect(validateElementFingerprint(
            expected: expected,
            live: fingerprint(subrole: "AXDefaultButton", identifier: "delete-button"),
            requireIdentityEvidence: true) != .match)
        #expect(validateElementFingerprint(
            expected: expected,
            live: fingerprint(subrole: "AXDefaultButton", label: "Delete"),
            requireIdentityEvidence: true) != .match)
    }

    @Test func postDeliveryValidationAllowsPresentationLabelToChange() {
        let expected = fingerprint(identifier: "play-pause", label: "Play")
        let changed = fingerprint(identifier: "play-pause", label: "Pause")

        #expect(validateElementFingerprint(
            expected: expected, live: changed,
            requireIdentityEvidence: true) != .match)
        #expect(validateElementFingerprint(
            expected: expected, live: changed,
            requireIdentityEvidence: true,
            comparePresentationEvidence: false) == .match)

        let labelOnly = ElementFingerprint(
            role: "AXButton", subrole: nil, identifier: nil, stableLabel: "Play")
        let changedLabelOnly = ElementFingerprint(
            role: "AXButton", subrole: nil, identifier: nil, stableLabel: "Pause")
        #expect(validateElementFingerprint(
            expected: labelOnly, live: changedLabelOnly,
            requireIdentityEvidence: true,
            comparePresentationEvidence: false) != .match)
    }

    @Test func identifierOrStableLabelCanAuthorizeMutationButSubroleCannot() {
        let weakFingerprints = [
            ElementFingerprint(
                role: "AXButton", subrole: nil, identifier: nil, stableLabel: nil),
            ElementFingerprint(
                role: "AXButton", subrole: "AXDefaultButton", identifier: nil,
                stableLabel: nil),
        ]

        for weak in weakFingerprints {
            #expect(validateElementFingerprint(
                expected: weak, live: weak,
                requireIdentityEvidence: true) == .insufficientEvidence)
            #expect(validateElementFingerprint(
                expected: weak, live: weak,
                requireIdentityEvidence: false) == .match)
        }

        let labeled = ElementFingerprint(
            role: "AXButton", subrole: nil, identifier: nil, stableLabel: "Delete")
        #expect(validateElementFingerprint(
            expected: labeled, live: labeled,
            requireIdentityEvidence: true) == .match)
    }

    @Test func stableLabelPolicyExcludesMutableTextAndGenericGroups() {
        #expect(stableIdentityLabel(
            role: "AXTextField", title: "Search", description: "Current query") == nil)
        #expect(stableIdentityLabel(
            role: "AXTextField", title: nil, description: "Current query",
            associatedTitle: "Search query") == "Search query")
        #expect(stableIdentityLabel(
            role: "AXGroup", title: "Loading", description: nil) == nil)
        #expect(stableIdentityLabel(
            role: "AXButton", title: "Save", description: nil) == "Save")
    }

    @Test func reorderedPeerAtTheOldPathFailsFingerprintValidation() throws {
        let save = LocatorNode(fingerprint(identifier: "save", label: "Save"))
        let delete = LocatorNode(fingerprint(identifier: "delete", label: "Delete"))
        let path = [LocatorStep(role: "AXButton", indexOfRole: 0)]

        let before = LocatorNode(
            fingerprint(role: "AXWindow", subrole: "AXStandardWindow", identifier: nil, label: nil),
            children: [save, delete])
        let after = LocatorNode(
            before.fingerprint,
            children: [delete, save])
        let captured = try #require(walkLocatorPath(
            path, from: before, children: { $0.children }, role: { $0.fingerprint.role }))
        let resolved = try #require(walkLocatorPath(
            path, from: after, children: { $0.children }, role: { $0.fingerprint.role }))

        #expect(captured === save)
        #expect(resolved === delete)
        #expect(validateElementFingerprint(
            expected: captured.fingerprint, live: resolved.fingerprint,
            requireIdentityEvidence: true) != .match)
    }

    @Test func fingerprintMismatchPreventsUnchangedReuseAndIDCarry() async {
        let pid: pid_t = -32_071
        await SnapshotStore.shared.resetForTesting(pid: pid)
        defer { Task { await SnapshotStore.shared.resetForTesting(pid: pid) } }
        let lineage = SnapshotLineage(
            process: SnapshotProcessIdentity(
                pid: pid, bundleIdentifier: "com.example.fingerprint",
                startTimeMicroseconds: 5_000_000),
            windowID: 81)

        let first = await SnapshotStore.shared.capture(
            pid: pid, bundleIdentifier: "com.example.fingerprint", windowTitle: "Document",
            windowID: 81, windowOrigin: .zero, pixelsPerPoint: 1,
            windowSize: [400, 300], createdAt: Date(timeIntervalSince1970: 1),
            lineageOverrideForTesting: lineage
        ) { generation in
            fingerprintTree(
                generation: generation,
                buttonFingerprint: fingerprint(identifier: "save-v1"))
        }
        let priorID = first.tree.elements[1].id

        let changed = await SnapshotStore.shared.capture(
            pid: pid, bundleIdentifier: "com.example.fingerprint", windowTitle: "Document",
            windowID: 81, windowOrigin: .zero, pixelsPerPoint: 1,
            windowSize: [400, 300], createdAt: Date(timeIntervalSince1970: 2),
            lineageOverrideForTesting: lineage
        ) { generation in
            fingerprintTree(
                generation: generation,
                buttonFingerprint: fingerprint(identifier: "save-v2"))
        }

        #expect(!changed.unchanged)
        #expect(changed.tree.elements[1].id != priorID)
        #expect(changed.diff?.added.count == 1)
        #expect(changed.diff?.removed.count == 1)
    }

    @Test func fingerprintPersistsAndLegacySnapshotStillDecodes() throws {
        let element = SnapshotElement(
            id: "e1@s1", role: "AXButton", label: "Save",
            fingerprint: fingerprint(),
            path: [LocatorStep(role: "AXButton", indexOfRole: 0)],
            frame: [0, 0, 80, 24])
        let encoded = try JSONEncoder().encode(element)
        let decoded = try JSONDecoder().decode(SnapshotElement.self, from: encoded)
        #expect(decoded.fingerprint == fingerprint())

        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "fingerprint")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(SnapshotElement.self, from: legacyData)
        #expect(legacy.fingerprint == nil)
    }

    @Test func newerLegacyElementCannotEraseValidatedFingerprint() {
        let previous = SnapshotElement(
            id: "e1@s1", role: "AXButton", label: "Save",
            fingerprint: fingerprint(identifier: "save-a"),
            path: [LocatorStep(role: "AXButton", indexOfRole: 0)],
            frame: [0, 0, 80, 24])
        let newerLegacy = SnapshotElement(
            id: "e1@s2", role: "AXButton", label: "Save",
            path: previous.path, frame: previous.frame)

        #expect(!snapshotElementsMatchIdentity(newerLegacy, previous))
    }

    @Test func legacySnapshotGetsFreshIDsBeforeFingerprintCanAuthorizeMutation() async throws {
        let pid: pid_t = -32_072
        await SnapshotStore.shared.resetForTesting(pid: pid)
        defer { Task { await SnapshotStore.shared.resetForTesting(pid: pid) } }
        let lineage = SnapshotLineage(
            process: SnapshotProcessIdentity(
                pid: pid, bundleIdentifier: "com.example.fingerprint",
                startTimeMicroseconds: 5_000_001),
            windowID: 82)

        let legacy = await SnapshotStore.shared.capture(
            pid: pid, bundleIdentifier: "com.example.fingerprint", windowTitle: "Document",
            windowID: 82, windowOrigin: .zero, pixelsPerPoint: 1,
            windowSize: [400, 300], createdAt: Date(timeIntervalSince1970: 1),
            lineageOverrideForTesting: lineage
        ) { generation in
            var tree = fingerprintTree(
                generation: generation,
                buttonFingerprint: fingerprint(identifier: "save-button"))
            tree = BuiltTree(
                text: tree.text,
                elements: tree.elements.map { element in
                    var legacy = element
                    legacy.fingerprint = nil
                    return legacy
                })
            return tree
        }
        let legacyIDs = legacy.snapshot.elements.map(\.id)
        #expect(legacy.snapshot.elements.allSatisfy { $0.fingerprint == nil })

        let upgraded = await SnapshotStore.shared.capture(
            pid: pid, bundleIdentifier: "com.example.fingerprint", windowTitle: "Document",
            windowID: 82, windowOrigin: .zero, pixelsPerPoint: 1,
            windowSize: [400, 300], createdAt: Date(timeIntervalSince1970: 2),
            lineageOverrideForTesting: lineage
        ) { generation in
            fingerprintTree(
                generation: generation,
                buttonFingerprint: fingerprint(identifier: "save-button"))
        }

        #expect(!upgraded.unchanged)
        #expect(upgraded.snapshot.elements[1].id != legacyIDs[1])
        #expect(upgraded.snapshot.elements[1].fingerprint?.identifier == "save-button")

        await SnapshotStore.shared.clearMemoryForTesting(pid: pid)
        let reloaded = try #require(await SnapshotStore.shared.load(forPid: pid))
        #expect(reloaded.elements[1].fingerprint?.identifier == "save-button")
    }

    @Test func existingLabelOnlyIDDoesNotSilentlyAcquireIdentifier() async {
        let pid: pid_t = -32_075
        await SnapshotStore.shared.resetForTesting(pid: pid)
        defer { Task { await SnapshotStore.shared.resetForTesting(pid: pid) } }
        let lineage = SnapshotLineage(
            process: SnapshotProcessIdentity(
                pid: pid, bundleIdentifier: "com.example.fingerprint",
                startTimeMicroseconds: 5_000_004),
            windowID: 85)
        let labelOnly = fingerprint(identifier: nil, label: "Save")

        let first = await SnapshotStore.shared.capture(
            pid: pid, bundleIdentifier: "com.example.fingerprint", windowTitle: "Document",
            windowID: 85, windowOrigin: .zero, pixelsPerPoint: 1,
            windowSize: [400, 300], createdAt: Date(timeIntervalSince1970: 1),
            lineageOverrideForTesting: lineage
        ) { generation in
            fingerprintTree(generation: generation, buttonFingerprint: labelOnly)
        }
        let originalID = first.snapshot.elements[1].id

        let second = await SnapshotStore.shared.capture(
            pid: pid, bundleIdentifier: "com.example.fingerprint", windowTitle: "Document",
            windowID: 85, windowOrigin: .zero, pixelsPerPoint: 1,
            windowSize: [400, 300], createdAt: Date(timeIntervalSince1970: 2),
            lineageOverrideForTesting: lineage
        ) { generation in
            fingerprintTree(
                generation: generation,
                buttonFingerprint: fingerprint(identifier: "save-button", label: "Save"))
        }

        #expect(second.unchanged)
        #expect(second.snapshot.elements[1].id == originalID)
        #expect(second.snapshot.elements[1].fingerprint == labelOnly)
    }

    @Test func historicalLegacyIDCannotInheritLaterFingerprint() async {
        let pid: pid_t = -32_073
        await SnapshotStore.shared.resetForTesting(pid: pid)
        defer { Task { await SnapshotStore.shared.resetForTesting(pid: pid) } }
        let lineage = SnapshotLineage(
            process: SnapshotProcessIdentity(
                pid: pid, bundleIdentifier: "com.example.fingerprint",
                startTimeMicroseconds: 5_000_002),
            windowID: 83)

        let first = await SnapshotStore.shared.capture(
            pid: pid, bundleIdentifier: "com.example.fingerprint", windowTitle: "Document",
            windowID: 83, windowOrigin: .zero, pixelsPerPoint: 1,
            windowSize: [400, 300], createdAt: Date(timeIntervalSince1970: 1),
            lineageOverrideForTesting: lineage
        ) { generation in
            let fresh = fingerprintTree(
                generation: generation,
                buttonFingerprint: fingerprint(identifier: "save-a"))
            return BuiltTree(
                text: fresh.text,
                elements: fresh.elements.map { element in
                    var legacy = element
                    legacy.fingerprint = nil
                    return legacy
                })
        }
        let historicalID = first.snapshot.elements[1].id

        let upgraded = await SnapshotStore.shared.capture(
            pid: pid, bundleIdentifier: "com.example.fingerprint", windowTitle: "Document",
            windowID: 83, windowOrigin: .zero, pixelsPerPoint: 1,
            windowSize: [400, 300], createdAt: Date(timeIntervalSince1970: 2),
            lineageOverrideForTesting: lineage
        ) { generation in
            fingerprintTree(
                generation: generation,
                buttonFingerprint: fingerprint(identifier: "save-a"),
                renderedSuffix: " value=enabled")
        }
        #expect(upgraded.snapshot.elements[1].id != historicalID)
        #expect(upgraded.snapshot.elements[1].fingerprint?.identifier == "save-a")

        let replaced = await SnapshotStore.shared.capture(
            pid: pid, bundleIdentifier: "com.example.fingerprint", windowTitle: "Document",
            windowID: 83, windowOrigin: .zero, pixelsPerPoint: 1,
            windowSize: [400, 300], createdAt: Date(timeIntervalSince1970: 3),
            lineageOverrideForTesting: lineage
        ) { generation in
            fingerprintTree(
                generation: generation,
                buttonFingerprint: fingerprint(identifier: "save-b"),
                renderedSuffix: " value=disabled")
        }
        #expect(replaced.snapshot.elements[1].id != historicalID)

        await SnapshotStore.shared.clearMemoryForTesting(pid: pid)
        let resolved = await SnapshotStore.shared.resolveElementSnapshot(
            forPid: pid, elementID: historicalID)
        #expect(resolved == nil)
    }

    @Test func diskReloadRejectsLegacyIDBeforeLaterFingerprint() async {
        let pid: pid_t = -32_074
        await SnapshotStore.shared.resetForTesting(pid: pid)
        defer { Task { await SnapshotStore.shared.resetForTesting(pid: pid) } }
        let lineage = SnapshotLineage(
            process: SnapshotProcessIdentity(
                pid: pid, bundleIdentifier: "com.example.fingerprint",
                startTimeMicroseconds: 5_000_003),
            windowID: 84)
        let path = [LocatorStep(role: "AXButton", indexOfRole: 0)]

        func snapshot(
            generation: String, id: String, fingerprint: ElementFingerprint?
        ) -> AppSnapshot {
            let element = SnapshotElement(
                id: id, role: "AXButton", label: "Save",
                fingerprint: fingerprint, path: path, frame: [0, 0, 80, 24])
            let text = "\(id) AXButton \"Save\""
            return AppSnapshot(
                pid: pid, bundleIdentifier: "com.example.fingerprint",
                windowTitle: "Document", windowOrigin: [0, 0], pixelsPerPoint: 1,
                windowSize: [400, 300], createdAt: Date(), generation: generation,
                treeFingerprint: treeFingerprint(text), treeText: text,
                scoped: false, partial: false, coverage: .complete,
                lineage: lineage, elements: [element])
        }

        await SnapshotStore.shared.seedForTesting(
            snapshot(generation: "s1", id: "e-old@s1", fingerprint: nil))
        await SnapshotStore.shared.seedForTesting(
            snapshot(generation: "s2", id: "e-mid@s2", fingerprint: nil))
        await SnapshotStore.shared.seedForTesting(
            snapshot(
                generation: "s3", id: "e-new@s3",
                fingerprint: fingerprint(identifier: "save-a")))

        await SnapshotStore.shared.clearMemoryForTesting(pid: pid)
        let resolved = await SnapshotStore.shared.resolveElementSnapshot(
            forPid: pid, elementID: "e-old@s1")

        #expect(resolved == nil)
    }
}
