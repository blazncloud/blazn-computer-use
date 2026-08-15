// In-memory app-state snapshots backed by live accessibility handles.
//
// Element ids name retained AXUIElement objects in the daemon process. A
// mutation validates the exact captured handle and its window attachment; it
// never replays a structural path or guesses at a replacement. A stale handle
// fails clearly and requires a fresh get_app_state.

import ApplicationServices
import CryptoKit
import Foundation

/// Hashable identity for a live AX object. Core Foundation owns the equality
/// contract for AXUIElement; Swift object identity is not equivalent.
struct AXHandleKey: Hashable, @unchecked Sendable {
    let element: AXUIElement

    static func == (lhs: AXHandleKey, rhs: AXHandleKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

/// One materialized node in the model-facing tree. The node retains both the
/// semantic facts captured for rendering/validation and the exact live AX
/// handle used for delivery.
final class CapturedNode: @unchecked Sendable {
    var id: String
    let role: String
    let label: String?
    let fingerprint: ElementFingerprint
    /// Bounding box in screenshot pixel coordinates.
    let frame: [Double]
    let handle: AXUIElement?
    weak var parent: CapturedNode?
    private(set) var children: [CapturedNode]

    init(
        id: String, role: String, label: String?,
        fingerprint: ElementFingerprint? = nil,
        frame: [Double], handle: AXUIElement? = nil,
        children: [CapturedNode] = []
    ) {
        self.id = id
        self.role = role
        self.label = label
        self.fingerprint = fingerprint ?? ElementFingerprint(
            role: role, subrole: nil, identifier: nil, stableLabel: nil)
        self.frame = frame
        self.handle = handle
        self.children = children
        for child in children { child.parent = self }
    }

    func appendChild(_ child: CapturedNode) {
        child.parent = self
        children.append(child)
    }
}

/// Strong process identity when macOS exposes a launch timestamp. PID and
/// bundle id are always retained; `startTimeMicroseconds` is nil when libproc
/// cannot inspect the process.
struct SnapshotProcessIdentity: Equatable, Hashable {
    let pid: Int32
    let bundleIdentifier: String
    let startTimeMicroseconds: UInt64?
}

/// Identity shared by the AX window used to build the tree and later mutation
/// resolution. A nil `windowID` explicitly means strong window identity was
/// unavailable.
struct SnapshotLineage: Equatable, Hashable {
    let process: SnapshotProcessIdentity
    let windowID: UInt32?
}

enum SnapshotLineageDecision: Equatable {
    case compatible
    case unavailable
    case conflict(String)
}

/// Single policy for deciding whether captured state still belongs to a
/// current process/window. Missing strong identity preserves read-only behavior;
/// any positively observed conflict fails closed.
func compareSnapshotLineage(
    persisted: SnapshotLineage?, current: SnapshotLineage
) -> SnapshotLineageDecision {
    guard let persisted else { return .unavailable }
    guard persisted.process.pid == current.process.pid else {
        return .conflict("the process id changed")
    }
    guard persisted.process.bundleIdentifier == current.process.bundleIdentifier else {
        return .conflict("pid \(current.process.pid) now belongs to a different app")
    }
    if let oldStart = persisted.process.startTimeMicroseconds,
        let newStart = current.process.startTimeMicroseconds,
        oldStart != newStart
    {
        return .conflict("the app process was replaced")
    }
    if let oldWindow = persisted.windowID, let newWindow = current.windowID,
        oldWindow != newWindow
    {
        return .conflict("the target window was replaced")
    }
    guard persisted.process.startTimeMicroseconds != nil,
        current.process.startTimeMicroseconds != nil,
        persisted.windowID != nil, current.windowID != nil
    else { return .unavailable }
    return .compatible
}

struct AppSnapshot: @unchecked Sendable {
    let pid: Int32
    let bundleIdentifier: String
    let windowTitle: String?
    /// Window origin in global screen coordinates (top-left origin).
    let windowOrigin: [Double]
    /// Multiplier from window points to screenshot pixels.
    let pixelsPerPoint: Double
    /// Physical backing scale of the display at capture time. Kept separate
    /// from screenshot pixelsPerPoint, which may be downscaled for payload size.
    let displayScale: Double?
    /// Geometry provenance of the screenshot coordinates. Tree-only captures
    /// update live tree geometry but carry these fields forward unchanged.
    let screenshotWindowOrigin: [Double]?
    let screenshotWindowSize: [Double]?
    /// Window size in screenshot pixels, for coordinate bounds checks (the
    /// element list may be scoped to a subtree).
    let windowSize: [Double]?
    let createdAt: Date
    /// Generation tag baked into element ids (e.g. "e11@s3"), so an id from
    /// an older state is rejected loudly instead of silently resolving to
    /// whatever occupies that index now. Elements that survive a UI change
    /// carry their id (and so an older tag) forward — see stabilizeTree.
    let generation: String
    /// Hash of the id-normalized tree text, for unchanged-tree detection.
    let treeFingerprint: String?
    /// The rendered outline this snapshot was built from, kept for diffing.
    let treeText: String?
    /// True when the element list covers a scoped subtree rather than the
    /// whole window; scoped snapshots are never diffed against.
    let scoped: Bool?
    /// True when a whole-window capture omitted known-live elements because
    /// of truncation, skeleton depth, or collection windowing. Partial
    /// snapshots must not invalidate ids they did not observe.
    let partial: Bool?
    /// Rich coverage state. `partial` is retained as a compact compatibility bit.
    let coverage: SnapshotCoverage?
    let lineage: SnapshotLineage?
    let windowElement: AXUIElement?
    let root: CapturedNode?
    let elements: [CapturedNode]
    let nodesByID: [String: CapturedNode]
    let idsByHandle: [AXHandleKey: String]

    init(
        pid: Int32, bundleIdentifier: String, windowTitle: String?,
        windowOrigin: [Double], pixelsPerPoint: Double, displayScale: Double? = nil,
        screenshotWindowOrigin: [Double]? = nil,
        screenshotWindowSize: [Double]? = nil,
        windowSize: [Double]?,
        createdAt: Date, generation: String,
        treeFingerprint: String? = nil, treeText: String? = nil,
        scoped: Bool? = nil, partial: Bool? = nil,
        coverage: SnapshotCoverage? = nil, lineage: SnapshotLineage? = nil,
        windowElement: AXUIElement? = nil, root: CapturedNode? = nil,
        elements: [CapturedNode], retainedElements: [CapturedNode] = []
    ) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.windowOrigin = windowOrigin
        self.pixelsPerPoint = pixelsPerPoint
        self.displayScale = displayScale
        self.screenshotWindowOrigin = screenshotWindowOrigin
        self.screenshotWindowSize = screenshotWindowSize
        self.windowSize = windowSize
        self.createdAt = createdAt
        self.generation = generation
        self.treeFingerprint = treeFingerprint
        self.treeText = treeText
        self.scoped = scoped
        self.partial = partial
        self.coverage = coverage
        self.lineage = lineage
        self.windowElement = windowElement
        self.root = root ?? elements.first
        self.elements = elements
        var nodeIndex: [String: CapturedNode] = [:]
        var handleIndex: [AXHandleKey: String] = [:]
        for node in elements {
            nodeIndex[node.id] = node
            if let handle = node.handle {
                let key = AXHandleKey(element: handle)
                if handleIndex[key] == nil { handleIndex[key] = node.id }
            }
        }
        for node in retainedElements where nodeIndex[node.id] == nil {
            nodeIndex[node.id] = node
            if let handle = node.handle {
                let key = AXHandleKey(element: handle)
                if handleIndex[key] == nil { handleIndex[key] = node.id }
            }
        }
        self.nodesByID = nodeIndex
        self.idsByHandle = handleIndex
    }

    var effectiveCoverage: SnapshotCoverage {
        coverage ?? (partial == true ? .partial : .complete)
    }

    func element(withID id: String) -> CapturedNode? {
        nodesByID[id]
    }

    /// Convert a screenshot pixel coordinate to global screen points.
    func screenPoint(fromScreenshotX x: Double, y: Double) -> CGPoint {
        let origin = screenshotWindowOrigin ?? windowOrigin
        return CGPoint(
            x: origin[0] + x / pixelsPerPoint,
            y: origin[1] + y / pixelsPerPoint
        )
    }
}

struct ScreenshotGeometryProvenance: Equatable {
    let origin: [Double]?
    let size: [Double]?
    let displayScale: Double?
}

/// A tree-only capture must not rewrite the geometry of the screenshot the
/// model still sees. Preserve all coordinate provenance together or expose no
/// usable screenshot coordinates.
func screenshotGeometryProvenance(
    hasNewScreenshot: Bool, currentOrigin: [Double], currentSize: [Double],
    currentDisplayScale: Double, previous: AppSnapshot?
) -> ScreenshotGeometryProvenance {
    if hasNewScreenshot {
        return ScreenshotGeometryProvenance(
            origin: currentOrigin, size: currentSize,
            displayScale: currentDisplayScale)
    }
    return ScreenshotGeometryProvenance(
        origin: previous?.screenshotWindowOrigin,
        size: previous?.screenshotWindowSize,
        displayScale: previous?.displayScale)
}

private enum SnapshotWindowIdentity: Hashable {
    case cgWindow(CGWindowID)
    case axWindow(AXHandleKey)
    case unavailable
}

private struct WindowSnapshotKey: Hashable {
    let process: SnapshotProcessIdentity
    let window: SnapshotWindowIdentity
}

private func snapshotKey(
    process: SnapshotProcessIdentity, windowID: CGWindowID?, windowElement: AXUIElement?
) -> WindowSnapshotKey {
    let window: SnapshotWindowIdentity
    if let windowID {
        window = .cgWindow(windowID)
    } else if let windowElement {
        window = .axWindow(AXHandleKey(element: windowElement))
    } else {
        window = .unavailable
    }
    return WindowSnapshotKey(process: process, window: window)
}

/// Serializes capture, id allocation, and handle lookup. Snapshots deliberately
/// live only in the daemon: a restart starts with no valid AX references.
actor SnapshotStore {
    static let shared = SnapshotStore()

    private var snapshots: [WindowSnapshotKey: AppSnapshot] = [:]
    private var latestKeyByPid: [pid_t: WindowSnapshotKey] = [:]
    private var counters: [pid_t: Int] = [:]

    /// Allocate a generation and atomically replace the current snapshot for
    /// this live process/window. Identity reuse is based only on AX handles.
    func capture(
        pid: pid_t, bundleIdentifier: String, windowTitle: String?,
        windowID: CGWindowID?, windowElement: AXUIElement? = nil,
        windowOrigin: CGPoint, pixelsPerPoint: Double, displayScale: Double? = nil,
        screenshotWindowOrigin: [Double]? = nil,
        screenshotWindowSize: [Double]? = nil,
        windowSize: [Double]?, createdAt: Date,
        lineageOverrideForTesting: SnapshotLineage? = nil,
        scoped: Bool = false,
        revision: (() -> UInt64)? = nil,
        buildTree: (String) -> BuiltTree
    ) -> (snapshot: AppSnapshot, tree: BuiltTree, unchanged: Bool, diff: TreeDiff?) {
        let lineage =
            lineageOverrideForTesting
            ?? snapshotLineage(
                pid: pid, bundleIdentifier: bundleIdentifier,
                windowID: windowID)
        let key = snapshotKey(
            process: lineage.process, windowID: lineage.windowID,
            windowElement: windowElement)
        snapshots = snapshots.filter { existing, _ in
            existing.process.pid != pid || existing.process == lineage.process
        }

        let next = (counters[pid] ?? 0) + 1
        counters[pid] = next
        let generation = "s\(next)"
        var tree = buildTreeWithRevisionRetry(
            generation: generation, revision: revision, build: buildTree)
        let previous = snapshots[key]

        var diff: TreeDiff?
        if let previous, let stabilized = stabilizeTree(tree, against: previous)
        {
            tree = stabilized.tree
            if !scoped, tree.coverage.isComplete,
                previous.scoped != true, previous.effectiveCoverage.isComplete,
                previous.windowTitle == windowTitle,
                previous.windowOrigin == [windowOrigin.x, windowOrigin.y],
                previous.windowSize == windowSize,
                previous.pixelsPerPoint == pixelsPerPoint
            {
                diff = stabilized.diff
            }
        }

        let fingerprint = treeFingerprint(tree.text)
        let unchanged = previous.map { prior in
            tree.coverage.isComplete
                && prior.effectiveCoverage.isComplete
                && diff?.entryCount == 0
                && prior.treeFingerprint == fingerprint
                && prior.windowTitle == windowTitle
                && prior.windowOrigin == [windowOrigin.x, windowOrigin.y]
                && prior.windowSize == windowSize
                && prior.pixelsPerPoint == pixelsPerPoint
                && (prior.scoped == true) == scoped
        } ?? false
        let preserveUnobserved = scoped || !tree.coverage.isComplete
        let observedIDs = Set(tree.elements.map(\.id))
        let observedHandles = Set(tree.elements.compactMap(\.handle).map(AXHandleKey.init))
        let retainedElements: [CapturedNode]
        if preserveUnobserved, let previous {
            retainedElements = previous.nodesByID.values.filter { node in
                guard let handle = node.handle else { return false }
                return !observedIDs.contains(node.id)
                    && !observedHandles.contains(AXHandleKey(element: handle))
            }
        } else {
            retainedElements = []
        }
        let snapshot = AppSnapshot(
            pid: pid, bundleIdentifier: bundleIdentifier, windowTitle: windowTitle,
            windowOrigin: [windowOrigin.x, windowOrigin.y], pixelsPerPoint: pixelsPerPoint,
            displayScale: displayScale,
            screenshotWindowOrigin: screenshotWindowOrigin,
            screenshotWindowSize: screenshotWindowSize,
            windowSize: windowSize,
            createdAt: createdAt, generation: generation,
            treeFingerprint: fingerprint, treeText: tree.text, scoped: scoped,
            partial: tree.isPartial, coverage: tree.coverage,
            lineage: lineage, windowElement: windowElement, root: tree.root,
            elements: tree.elements, retainedElements: retainedElements
        )
        snapshots[key] = snapshot
        latestKeyByPid[pid] = key
        return (snapshot, tree, unchanged, unchanged ? nil : diff)
    }

    func load(forPid pid: pid_t) -> AppSnapshot? {
        latestKeyByPid[pid].flatMap { snapshots[$0] }
    }

    /// Load only the prior snapshot for this exact window. Perception must not
    /// inherit screenshot coordinate provenance from a sibling window owned by
    /// the same process.
    func load(
        forPid pid: pid_t, windowID: CGWindowID?, windowElement: AXUIElement
    ) -> AppSnapshot? {
        snapshots.values.first { snapshot in
            guard snapshot.pid == pid else { return false }
            if let windowID {
                return snapshot.lineage?.windowID == windowID
            }
            guard snapshot.lineage?.windowID == nil,
                let retained = snapshot.windowElement
            else { return false }
            return CFEqual(retained, windowElement)
        }
    }

    func resolveElementSnapshot(
        forPid pid: pid_t, elementID: String
    ) -> (snapshot: AppSnapshot, element: CapturedNode)? {
        if let latest = load(forPid: pid), let element = latest.element(withID: elementID) {
            return (latest, element)
        }
        for (key, snapshot) in snapshots where key.process.pid == pid {
            if let element = snapshot.element(withID: elementID) {
                return (snapshot, element)
            }
        }
        return nil
    }

    func resetForTesting(pid: pid_t) {
        clearMemoryForTesting(pid: pid)
    }

    func seedForTesting(_ snapshot: AppSnapshot) {
        let lineage = snapshot.lineage ?? SnapshotLineage(
            process: SnapshotProcessIdentity(
                pid: snapshot.pid, bundleIdentifier: snapshot.bundleIdentifier,
                startTimeMicroseconds: nil),
            windowID: nil)
        let key = snapshotKey(
            process: lineage.process, windowID: lineage.windowID,
            windowElement: snapshot.windowElement)
        snapshots[key] = snapshot
        latestKeyByPid[snapshot.pid] = key
        counters[snapshot.pid] = max(counters[snapshot.pid] ?? 0, Self.parseGeneration(snapshot))
    }

    func clearMemoryForTesting(pid: pid_t) {
        snapshots = snapshots.filter { $0.key.process.pid != pid }
        latestKeyByPid.removeValue(forKey: pid)
        counters.removeValue(forKey: pid)
    }

    private static func parseGeneration(_ snapshot: AppSnapshot) -> Int {
        Int(snapshot.generation.dropFirst()) ?? 0
    }
}

/// Hash of the tree text with element ids normalized away, so two builds of
/// an identical UI fingerprint the same even though ids carry fresh
/// generation tags.
func treeFingerprint(_ treeText: String) -> String {
    let normalized = treeText.replacing(/e\d+@s\d+/, with: "e@")
    let digest = SHA256.hash(data: Data(normalized.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// What changed between the previous snapshot and a fresh capture, after id
/// stabilization. Entries are outline lines with a `~` (content changed),
/// `+` (new element), or `-` (element gone) prefix.
struct TreeDiff {
    let changed: [String]
    let added: [String]
    let removed: [String]
    let totalElements: Int

    var entryCount: Int { changed.count + added.count + removed.count }
    var text: String { (changed + added + removed).joined(separator: "\n") }
    /// Worth sending instead of the full tree: non-empty, and smaller than
    /// half the outline (a rewrite-everything diff is not a diff).
    var isCompact: Bool { entryCount > 0 && entryCount * 2 <= totalElements }

    /// True when the post-state diff contains any changed/added/removed line
    /// other than the acted target's own line. Without a target line,
    /// independence cannot be proven.
    func hasChangeIndependent(of target: CapturedNode?) -> Bool {
        hasChangeIndependent(in: changed + added + removed, of: target) { _ in true }
    }

    /// Text-entry web corroboration is stricter than "some sibling changed":
    /// the independent line must carry the requested text in post-action
    /// changed/added content, or unrelated timers/deletions could be mistaken
    /// for proof that the write landed.
    func hasChangeIndependent(of target: CapturedNode?, matching text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return hasChangeIndependent(in: changed + added, of: target) { line in
            String(line).localizedCaseInsensitiveContains(text)
        }
    }

    private func hasChangeIndependent(
        in entries: [String], of target: CapturedNode?, where lineMatches: (String.SubSequence) -> Bool
    ) -> Bool {
        guard let target else { return false }
        let targetPrefix = target.id + " "
        return entries.contains { entry in
            let body = entry.dropFirst(2)
            return !body.hasPrefix(targetPrefix) && lineMatches(body)
        }
    }
}

/// Scroll-specific evidence from a post-action tree diff. A scroll verifier must
/// not treat arbitrary whole-window churn as success: movement is corroborated
/// only when the diff shows rows/children/text entering/leaving the viewport or
/// a surviving element's frame moving within the tree.
func scrollRelevantChange(in diff: TreeDiff?) -> Bool? {
    guard let diff else { return nil }
    let entries = diff.changed + diff.added + diff.removed
    guard !entries.isEmpty else { return false }
    return entries.contains(where: isScrollRelevantDiffEntry)
}

private func isScrollRelevantDiffEntry(_ entry: String) -> Bool {
    let line = String(entry.dropFirst(2))
    if line.contains("AXRow") || line.contains("AXCell") || line.contains("AXList")
        || line.contains("AXTable") || line.contains("AXOutline") || line.contains("AXWebArea")
    {
        return true
    }
    if line.contains("AXStaticText") || line.contains("AXTextField") || line.contains("AXTextArea") {
        return entry.hasPrefix("+ ") || entry.hasPrefix("- ")
    }
    return false
}

/// Carry ids forward only when Core Foundation says the fresh traversal saw
/// the same live AX object. Recreated objects are intentionally remove/add.
func stabilizeTree(_ tree: BuiltTree, against previous: AppSnapshot) -> (tree: BuiltTree, diff: TreeDiff)? {
    guard let previousText = previous.treeText else { return nil }
    let previousLines = previousText.components(separatedBy: "\n")
    guard previous.elements.count <= previousLines.count else { return nil }
    var newLines = tree.text.components(separatedBy: "\n")
    guard tree.elements.count <= newLines.count else { return nil }

    func stripIndent(_ line: String) -> String {
        String(line.drop(while: { $0 == "\t" }))
    }

    let previousIndexByID = Dictionary(uniqueKeysWithValues:
        previous.elements.enumerated().map { ($0.element.id, $0.offset) })
    var claimedPreviousIDs: Set<String> = []
    var changed: [String] = []
    var added: [String] = []

    for index in tree.elements.indices {
        let element = tree.elements[index]
        if let handle = element.handle,
            let priorID = previous.idsByHandle[AXHandleKey(element: handle)],
            let prior = previous.nodesByID[priorID],
            prior.role == element.role,
            !claimedPreviousIDs.contains(priorID)
        {
            claimedPreviousIDs.insert(priorID)
            newLines[index] = newLines[index].replacingOccurrences(
                of: element.id, with: priorID)
            element.id = priorID
            if let priorIndex = previousIndexByID[priorID],
                previousLines[priorIndex] != newLines[index]
            {
                changed.append("~ " + stripIndent(newLines[index]))
            }
        } else {
            added.append("+ " + stripIndent(newLines[index]))
        }
    }

    let removed = previous.elements.filter { !claimedPreviousIDs.contains($0.id) }.map { element in
        let label = element.label.map { " \"\($0)\"" } ?? ""
        return "- \(element.id) \(element.role)\(label) is gone"
    }

    let stabilized = BuiltTree(
        text: newLines.joined(separator: "\n"), root: tree.root, elements: tree.elements,
        coverage: tree.coverage, elementsVisited: tree.elementsVisited)
    return (stabilized, TreeDiff(
        changed: changed, added: added, removed: removed,
        totalElements: tree.elements.count))
}

/// Validate the exact retained handle. There is no structural replay or
/// replacement search: invalid, changed, or detached targets fail stale.
func resolveElement(
    _ element: CapturedNode, in window: AXUIElement,
    comparePresentationEvidence: Bool = true
) async throws -> AXUIElement {
    guard let handle = element.handle else {
        throw ToolError.failed(
            "Element \(element.id) has no live AX handle. Call get_app_state in the current daemon "
                + "and use a fresh element id.")
    }
    switch axReadAttribute(handle, kAXRoleAttribute) {
    case .failure(let failure):
        throw staleHandleError(element, reason: describeAXReadFailure(failure))
    case .value(let raw):
        guard let role = raw as? String else {
            throw staleHandleError(element, reason: "AXRole returned an unexpected value")
        }
        guard role == element.role else {
            throw staleHandleError(
                element, reason: "role changed from \(element.role) to \(role)")
        }
    }

    let validation = validateElementFingerprint(
        expected: element.fingerprint, live: liveElementFingerprint(handle),
        requireIdentityEvidence: false,
        comparePresentationEvidence: comparePresentationEvidence)
    guard validation == .match else {
        throw staleHandleError(element, reason: validation.description)
    }
    try requireAttached(handle, to: window, element: element)
    return handle
}

private func staleHandleError(_ element: CapturedNode, reason: String) -> ToolError {
    ToolError.failed(
        "Element \(element.id) (\(element.role)\(element.label.map { " \"\($0)\"" } ?? "")) "
            + "is stale: \(reason). Call get_app_state and use a fresh element id.")
}

func describeAXReadFailure(_ failure: AXReadFailure) -> String {
    switch failure {
    case .api(let error): return axErrorDescription(error)
    case .typeMismatch: return "the accessibility attribute had an unexpected type"
    }
}

private func requireAttached(
    _ element: AXUIElement, to expectedWindow: AXUIElement,
    element captured: CapturedNode, maxDepth: Int = 32
) throws {
    if CFEqual(element, expectedWindow) { return }
    switch axReadAttribute(element, kAXWindowAttribute) {
    case .value(let raw):
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            throw staleHandleError(captured, reason: "AXWindow returned an unexpected value")
        }
        guard CFEqual(raw as! AXUIElement, expectedWindow) else {
            throw staleHandleError(captured, reason: "the element belongs to a different window")
        }
        return
    case .failure(.api(.noValue)), .failure(.api(.attributeUnsupported)):
        break
    case .failure(let failure):
        throw staleHandleError(captured, reason: describeAXReadFailure(failure))
    }

    var current = element
    var visited: Set<AXHandleKey> = []
    for _ in 0..<maxDepth {
        let key = AXHandleKey(element: current)
        guard visited.insert(key).inserted else {
            throw staleHandleError(captured, reason: "the AXParent chain contains a cycle")
        }
        switch axReadAttribute(current, kAXParentAttribute) {
        case .value(let raw):
            guard CFGetTypeID(raw) == AXUIElementGetTypeID() else {
                throw staleHandleError(captured, reason: "AXParent returned an unexpected value")
            }
            current = raw as! AXUIElement
            if CFEqual(current, expectedWindow) { return }
        case .failure(let failure):
            throw staleHandleError(captured, reason: describeAXReadFailure(failure))
        }
    }
    throw staleHandleError(
        captured, reason: "the expected window was not reached within \(maxDepth) AXParent hops")
}

/// Fail fast with a clear message when the target app has quit or crashed,
/// instead of surfacing a confusing stale-element or no-window error.
func requireAppAlive(_ app: ResolvedApp) throws {
    if appIsGone(pid: app.pid) {
        throw ToolError.failed(
            "\(app.name) (pid \(app.pid)) has quit or crashed since it was resolved. "
                + "Call list_apps to see what is running, then get_app_state on the new instance."
        )
    }
}

extension ElementFingerprintValidation {
    fileprivate var description: String {
        switch self {
        case .match: return "matched"
        case .insufficientEvidence:
            return "the captured fingerprint had no AXIdentifier or meaningful stable label"
        case .mismatch(let reason): return reason
        }
    }
}

/// Pure identity rule behind the stale-element re-check. Label identity is
/// only enforced when the snapshot had one (unlabeled containers are
/// identified by structure alone) and the role is not text entry — a text
/// field's label tracks its contents, so a mismatch there is churn, not a
/// different control.
func elementIdentityMatches(
    liveRole: String, liveLabel: String?, expectedRole: String, expectedLabel: String?
) -> Bool {
    guard liveRole == expectedRole else { return false }
    guard let expected = expectedLabel, !expected.isEmpty else { return true }
    if isTextEntryRole(expectedRole) { return true }
    return liveLabel == expected
}
