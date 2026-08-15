// Walk an app window's accessibility tree into (a) a numbered, indented text
// outline for the model and (b) a nested tree of retained live AX nodes.
//
// The traversal core (`buildTreeCore`) is generic over a node type via
// `TreeNodeAccessors`, so the shaping rules — structural-wrapper elision,
// dense-collection viewport windowing, and skeleton depth truncation — are
// unit-testable against an in-memory tree with no live accessibility API.

import ApplicationServices
import Foundation

struct BuiltTree {
    let text: String
    let root: CapturedNode?
    let elements: [CapturedNode]
    let coverage: SnapshotCoverage
    var isPartial: Bool { !coverage.isComplete }
    /// Nodes whose full facts were read during traversal, including structural
    /// wrappers that were inspected but omitted from the returned outline.
    let elementsVisited: Int

    init(
        text: String, root: CapturedNode? = nil, elements: [CapturedNode], isPartial: Bool = false,
        coverage: SnapshotCoverage? = nil,
        elementsVisited: Int? = nil
    ) {
        self.text = text
        self.root = root ?? elements.first
        self.elements = elements
        self.coverage = coverage ?? (isPartial ? .partial : .complete)
        self.elementsVisited = max(0, elementsVisited ?? elements.count)
    }

    func withCoverage(_ additionalCoverage: SnapshotCoverage, note: String? = nil) -> BuiltTree {
        let combined = SnapshotCoverage.combining(coverage, additionalCoverage)
        let combinedText = note.map { text.isEmpty ? $0 : text + "\n" + $0 } ?? text
        return BuiltTree(
            text: combinedText, root: root, elements: elements, coverage: combined,
            elementsVisited: elementsVisited)
    }
}

let defaultMaxTreeElements = 500
private let maxDepth = 24
private let maxRawDepth = 60
private let maxChildrenPerNode = 150
private let maxValueLength = 300

/// Outline depth a skeleton (overview) build recurses to. Containers deeper
/// than this are emitted but their children are cut and summarized with a
/// `children_count`, keeping the container a drill target for a follow-up
/// scoped get_app_state.
let skeletonMaxDepth = 3

/// A container is treated as a dense virtualized collection — eligible for
/// viewport windowing — only once it has at least this many children (or
/// reports at least this many rows). Small lists are shown whole.
let denseCollectionThreshold = 80

/// Per-element AX messaging timeout (seconds), set on every node before we
/// query it. One hung element then fails its own AX calls after this bound
/// instead of stalling the whole traversal against the coarser process-wide
/// timeout (Core/AX.swift). Tunable via COMPUTER_USE_MCP_AX_ELEMENT_TIMEOUT.
let perElementAXTimeout: Float = Config.double("ax_element_timeout").map(Float.init) ?? 0.25

/// Tighter timeout for the frame-only probes used to decide which children of
/// a dense collection fall in the viewport: a stall there must not cost more
/// than a blink per off-screen row. Tunable via
/// COMPUTER_USE_MCP_VIEWPORT_PROBE_TIMEOUT.
let viewportProbeAXTimeout: Float = Config.double("viewport_probe_timeout").map(Float.init) ?? 0.05

/// Roles whose children are dense, homogeneous, and virtualized around a
/// scroll viewport (lists, tables, outlines). Above `denseCollectionThreshold`
/// children these are windowed to the on-screen slice instead of shown by a
/// blind prefix that ignores the scroll position.
func isDenseCollectionRole(_ role: String) -> Bool {
    switch role {
    case "AXList", "AXTable", "AXOutline", "AXGrid", "AXBrowser": return true
    default: return false
    }
}

/// Element budget for a tree build, clamped to a sane range. Callers that
/// need to know whether a built tree hit its budget (was truncated) must
/// compare against this same clamp.
func clampedTreeBudget(_ maxElements: Int) -> Int {
    max(1, min(maxElements, 5000))
}

/// True for pure structural wrappers: unlabeled, value-less AXGroups whose
/// only actions are universal noise (ShowMenu, ScrollToVisible). Web pages
/// nest dozens of these around every piece of content — they are omitted from
/// the outline (and the element budget), while emitted descendants attach to
/// the nearest retained ancestor.
func isStructuralWrapper(
    role: String, label: String?, identifier: String? = nil,
    value: String?, focused: Bool, actions: [String]
) -> Bool {
    guard role == "AXGroup" else { return false }
    guard label == nil || label!.isEmpty else { return false }
    guard identifier == nil || identifier!.isEmpty else { return false }
    guard value == nil || value!.isEmpty else { return false }
    guard !focused else { return false }
    return actions.allSatisfy { $0 == "AXShowMenu" || $0 == "AXScrollToVisible" }
}

// MARK: - Generic node model

/// Everything the outline needs to know about a single node, read once so the
/// wrapper check and the rendered line don't re-query the same attributes.
/// `frame` is in the same global-screen coordinates as `windowOrigin`.
struct NodeFacts {
    let role: String
    let label: String?
    let identifier: String?
    let value: String?
    let selectedText: String?
    let enabled: Bool?
    let focused: Bool?
    let selected: Bool?
    let actions: [String]
    let frame: CGRect?
    var subrole: String? = nil
    var stableIdentityLabel: String? = nil
}

/// Accessors the generic traversal needs over an opaque node type. The live
/// implementation (`axTreeAccessors`) reads the accessibility API; tests supply
/// an in-memory tree.
struct TreeNodeAccessors<Node> {
    /// Full read for a node that will be materialized (emitted).
    let facts: (Node) -> NodeFacts
    /// Cheap role-only read used while scanning past children that are
    /// windowed out.
    let role: (Node) -> String
    /// Cheap frame-only read (tight timeout), used by the viewport-intersection
    /// windowing fallback.
    let frame: (Node) -> CGRect?
    let children: (Node) -> [Node]
    /// The app's own on-screen slice of a collection (AXVisibleRows /
    /// AXVisibleChildren), or nil when it exposes none.
    let visibleCollectionChildren: (Node) -> [Node]?
    /// Total item count of a collection (AXRows), independent of how many are
    /// realized in the tree; nil when the node reports none.
    let collectionTotal: (Node) -> Int?
    /// Identity, for mapping a visible child back to its index among all
    /// children.
    let equals: (Node, Node) -> Bool
    /// Live AX handle retained by production captures; deterministic tests use nil.
    let handle: (Node) -> AXUIElement?
    /// Coverage learned while reading nodes. Test accessors default to complete.
    let coverage: () -> SnapshotCoverage
    let coverageDiagnostic: () -> String?

    init(
        facts: @escaping (Node) -> NodeFacts,
        role: @escaping (Node) -> String,
        frame: @escaping (Node) -> CGRect?,
        children: @escaping (Node) -> [Node],
        visibleCollectionChildren: @escaping (Node) -> [Node]?,
        collectionTotal: @escaping (Node) -> Int?,
        equals: @escaping (Node, Node) -> Bool,
        handle: @escaping (Node) -> AXUIElement? = { _ in nil },
        coverage: @escaping () -> SnapshotCoverage = { .complete },
        coverageDiagnostic: @escaping () -> String? = { nil }
    ) {
        self.facts = facts
        self.role = role
        self.frame = frame
        self.children = children
        self.visibleCollectionChildren = visibleCollectionChildren
        self.collectionTotal = collectionTotal
        self.equals = equals
        self.handle = handle
        self.coverage = coverage
        self.coverageDiagnostic = coverageDiagnostic
    }
}

// MARK: - Dense-collection viewport windowing

/// The materialized on-screen window of a dense collection's children.
struct CollectionWindow {
    /// Indices (into the full children array) to materialize.
    let includedIndices: Set<Int>
    /// Scan children[0..<scanLimit]; beyond this the collection is entirely
    /// off-window.
    let scanLimit: Int
    /// Items past the window, for the summary line.
    let offscreen: Int
    /// "rows" or "items", for the summary line.
    let itemNoun: String
}

/// Indices whose frame vertically intersects `viewport` expanded by `margin`
/// (lists scroll vertically; horizontal extent is ignored). A child with an
/// unknown frame is always included — windowing must never *silently* drop an
/// actionable element. Pure and deterministic.
func viewportVisibleIndices(childFrames: [CGRect?], viewport: CGRect, margin: CGFloat) -> Set<Int> {
    let top = viewport.minY - margin
    let bottom = viewport.maxY + margin
    var included: Set<Int> = []
    for (index, frame) in childFrames.enumerated() {
        guard let frame else { included.insert(index); continue }
        if frame.maxY >= top && frame.minY <= bottom { included.insert(index) }
    }
    return included
}

/// Decide the on-screen window for a dense virtualized collection, or nil to
/// fall back to the default prefix (not a dense collection, too few children,
/// or nothing to window with). Prefers the app's own visible-rows list; else
/// filters children by viewport-frame intersection.
private func denseCollectionWindow<Node>(
    _ node: Node, role: String, children: [Node], accessors: TreeNodeAccessors<Node>
) -> CollectionWindow? {
    guard isDenseCollectionRole(role) else { return nil }
    let total = accessors.collectionTotal(node) ?? children.count
    guard children.count >= denseCollectionThreshold || total >= denseCollectionThreshold else {
        return nil
    }

    var includedIndices = Set<Int>()

    // Preferred: the app's own on-screen slice.
    if let visible = accessors.visibleCollectionChildren(node), !visible.isEmpty {
        for element in visible {
            if let index = children.firstIndex(where: { accessors.equals($0, element) }) {
                includedIndices.insert(index)
            }
        }
    }

    // Fallback: viewport-frame intersection. Bound the probe count so a huge
    // hung collection cannot cost more than a blink each; children past the
    // bound are treated as off-window.
    if includedIndices.isEmpty {
        guard let viewport = accessors.frame(node) else { return nil }
        let probeCount = min(children.count, 600)
        let frames = children.prefix(probeCount).map { accessors.frame($0) }
        includedIndices = viewportVisibleIndices(
            childFrames: frames, viewport: viewport, margin: viewport.height * 0.5)
    }

    guard !includedIndices.isEmpty else { return nil }

    // Safety cap: never materialize more than a full node's worth of children.
    if includedIndices.count > maxChildrenPerNode {
        includedIndices = Set(includedIndices.sorted().prefix(maxChildrenPerNode))
    }

    let scanLimit = min(children.count, (includedIndices.max() ?? -1) + 1)
    let offscreen = max(0, total - includedIndices.count)
    let noun = (role == "AXOutline" || role == "AXTable") ? "rows" : "items"
    return CollectionWindow(
        includedIndices: includedIndices, scanLimit: scanLimit, offscreen: offscreen, itemNoun: noun)
}

// MARK: - Generic traversal core

func buildTreeCore<Node>(
    root: Node, accessors: TreeNodeAccessors<Node>,
    windowOrigin: CGPoint, pixelsPerPoint: Double, generation: String,
    maxElements: Int, skeleton: Bool, windowCollections: Bool
) -> BuiltTree {
    let maxNodes = clampedTreeBudget(maxElements)
    var lines: [String] = []
    var elements: [CapturedNode] = []
    var capturedRoot: CapturedNode?

    func pixelFrame(_ frame: CGRect?) -> [Double]? {
        guard let frame = frame.flatMap(sanitizedRect), sanitizedPoint(windowOrigin) != nil,
            pixelsPerPoint.isFinite
        else { return nil }
        let pixels = [
            ((frame.origin.x - windowOrigin.x) * pixelsPerPoint).rounded(),
            ((frame.origin.y - windowOrigin.y) * pixelsPerPoint).rounded(),
            (frame.width * pixelsPerPoint).rounded(),
            (frame.height * pixelsPerPoint).rounded(),
        ]
        return pixels.allSatisfy(\.isFinite) ? pixels : nil
    }

    var depthTruncated = false
    var budgetTruncated = false
    var coveragePartial = false
    var elementsVisited = 0

    func visit(
        _ element: Node, depth: Int, rawDepth: Int,
        capturedParent: CapturedNode?
    ) {
        guard elements.count < maxNodes else {
            budgetTruncated = true
            return
        }
        guard depth <= maxDepth, rawDepth <= maxRawDepth else {
            depthTruncated = true
            return
        }

        let facts = accessors.facts(element)
        elementsVisited += 1
        let role = facts.role

        // Wrappers (never the tree root) pass their outline slot straight to
        // their children; childless wrappers vanish entirely.
        let wrapper =
            capturedParent != nil
            && isStructuralWrapper(
                role: role, label: facts.label, identifier: facts.identifier,
                value: facts.value,
                focused: facts.focused == true, actions: facts.actions)

        var lineIndex: Int?
        var parentForChildren = capturedParent
        if !wrapper {
            let id = "e\(elements.count)@\(generation)"
            let frame = pixelFrame(facts.frame)
            let node = CapturedNode(
                id: id, role: role, label: facts.label,
                fingerprint: ElementFingerprint(
                    role: role, subrole: facts.subrole,
                    identifier: facts.identifier,
                    stableLabel: facts.stableIdentityLabel),
                frame: frame ?? [0, 0, 0, 0],
                handle: accessors.handle(element))
            if let capturedParent {
                capturedParent.appendChild(node)
            } else {
                capturedRoot = node
            }
            elements.append(node)
            parentForChildren = node
            lines.append(describeLine(facts, id: id, frame: frame, depth: depth))
            lineIndex = lines.count - 1
        }

        let children = accessors.children(element)

        // Skeleton overview: a container past the shallow depth is kept as a
        // drill target (children_count) but not expanded.
        if skeleton, depth >= skeletonMaxDepth, !children.isEmpty {
            coveragePartial = true
            if let lineIndex {
                let total = accessors.collectionTotal(element) ?? children.count
                lines[lineIndex] += " children_count=\(total)"
            }
            return
        }

        let window =
            windowCollections
            ? denseCollectionWindow(element, role: role, children: children, accessors: accessors)
            : nil
        // Windowed perception caps per-node fanout to bound tokens. Non-windowed
        // callers (find, skill-replay) asked for the deep tree and are bounded
        // only by the element budget so find and unique skill anchors can see
        // every materialized row.
        let scanLimit =
            window?.scanLimit
            ?? (windowCollections ? min(children.count, maxChildrenPerNode) : children.count)
        if scanLimit < children.count {
            coveragePartial = true
        }

        for childIndex in 0..<children.count {
            guard childIndex < scanLimit else { break }
            let child = children[childIndex]
            if let window, !window.includedIndices.contains(childIndex) { continue }
            visit(
                child, depth: wrapper ? depth : depth + 1,
                rawDepth: rawDepth + 1, capturedParent: parentForChildren)
            if elements.count >= maxNodes {
                if childIndex + 1 < scanLimit { budgetTruncated = true }
                break
            }
        }

        // Annotate the container's own line rather than emitting a standalone
        // line, so the outline stays one-line-per-element — the invariant
        // stabilizeTree (Snapshot.swift) relies on to carry ids across a
        // re-snapshot.
        if let window, window.offscreen > 0, let lineIndex {
            coveragePartial = true
            lines[lineIndex] +=
                " …\(window.offscreen) more \(window.itemNoun) off-screen; scroll the list and "
                + "re-read to load them, or use find to jump to a specific one"
        }
    }

    visit(root, depth: 0, rawDepth: 0, capturedParent: nil)

    if budgetTruncated {
        coveragePartial = true
        lines.append(
            "… tree truncated at \(maxNodes) elements. Call get_app_state with scope_element_id "
                + "set to a container id to expand just that subtree, or raise max_elements."
        )
    }
    if depthTruncated {
        lines.append(
            "… some branches exceed the nesting limit and were cut. Call get_app_state with "
                + "scope_element_id set to the deepest visible container to expand further."
        )
    }
    var coverage: SnapshotCoverage = coveragePartial || depthTruncated ? .partial : .complete
    coverage = SnapshotCoverage.combining(coverage, accessors.coverage())
    if let diagnostic = accessors.coverageDiagnostic() {
        lines.append(diagnostic)
    }
    return BuiltTree(
        text: lines.joined(separator: "\n"), root: capturedRoot, elements: elements,
        coverage: coverage,
        elementsVisited: elementsVisited)
}

// MARK: - Live accessibility-backed accessors

/// @unchecked: AXUIElement is an immutable thread-safe CF handle; the struct
/// only carries the element by value through the generic traversal.
struct AXNode: @unchecked Sendable {
    let element: AXUIElement
}

final class AXTreeReadCoverageRecorder {
    private(set) var failedReads = 0

    var coverage: SnapshotCoverage { failedReads == 0 ? .complete : .degraded }

    var diagnostic: String? {
        guard failedReads > 0 else { return nil }
        return "… accessibility coverage degraded: \(failedReads) AX read(s) failed unexpectedly; "
            + "the tree may omit elements. Re-read app state before acting on absence."
    }

    func record(_ failure: AXReadFailure, required: Bool) {
        if required || failure.degradesOptionalRead { failedReads += 1 }
    }

    func read<T>(
        _ result: AXReadResult<CFTypeRef>, required: Bool = false,
        transform: (CFTypeRef) -> T?
    ) -> T? {
        switch result {
        case .failure(let failure):
            record(failure, required: required)
            return nil
        case .value(let raw):
            guard let value = transform(raw) else {
                record(.typeMismatch, required: required)
                return nil
            }
            return value
        }
    }

    func readElements(
        _ result: AXReadResult<[AXUIElement]>, required: Bool = false
    ) -> [AXUIElement]? {
        switch result {
        case .value(let elements): return elements
        case .failure(let failure):
            record(failure, required: required)
            return nil
        }
    }

    func readActions(_ result: AXReadResult<[String]>) -> [String] {
        switch result {
        case .value(let actions): return actions
        case .failure(let failure):
            record(failure, required: false)
            return []
        }
    }
}

func axTreeAccessors() -> TreeNodeAccessors<AXNode> {
    let recorder = AXTreeReadCoverageRecorder()

    func string(_ element: AXUIElement, _ attribute: String, required: Bool = false) -> String? {
        recorder.read(axReadAttribute(element, attribute), required: required) { value in
            if let string = value as? String { return string }
            if let number = value as? NSNumber { return number.stringValue }
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return (value as! CFBoolean) == kCFBooleanTrue ? "true" : "false"
            }
            if let attributed = value as? NSAttributedString { return attributed.string }
            if let url = value as? URL { return url.absoluteString }
            return nil
        }
    }

    func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        recorder.read(axReadAttribute(element, attribute)) { value in
            guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
            return (value as! CFBoolean) == kCFBooleanTrue
        }
    }

    func frame(_ element: AXUIElement) -> CGRect? {
        let position: CGPoint? = recorder.read(
            axReadAttribute(element, kAXPositionAttribute),
            transform: { value in
                guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
                var point = CGPoint.zero
                return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
            })
        let size: CGSize? = recorder.read(
            axReadAttribute(element, kAXSizeAttribute),
            transform: { value in
                guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
                var size = CGSize.zero
                return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
            })
        guard let position, let size else { return nil }
        return sanitizedRect(CGRect(origin: position, size: size))
    }

    func labels(_ element: AXUIElement, role: String) -> (display: String?, identity: String?) {
        let title = string(element, kAXTitleAttribute)
        let description = title == nil ? string(element, kAXDescriptionAttribute) : nil
        let display = title
            ?? description
            ?? string(element, "AXPlaceholderValue")
            ?? informativeRoleDescription(
                role: role, description: string(element, kAXRoleDescriptionAttribute))
        let associatedTitle: String?
        if isTextEntryRole(role) {
            let titleElement: AXUIElement? = recorder.read(
                axReadAttribute(element, kAXTitleUIElementAttribute),
                transform: { value in
                    guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
                    return (value as! AXUIElement)
                })
            associatedTitle = titleElement.flatMap { element in
                string(element, kAXTitleAttribute)
                    ?? string(element, kAXDescriptionAttribute)
                    ?? string(element, kAXValueAttribute)
            }
        } else {
            associatedTitle = nil
        }
        return (
            display,
            stableIdentityLabel(
                role: role, title: title, description: description,
                associatedTitle: associatedTitle))
    }

    return TreeNodeAccessors<AXNode>(
        facts: { node in
            let element = node.element
            AXUIElementSetMessagingTimeout(element, perElementAXTimeout)
            let role = string(element, kAXRoleAttribute, required: true) ?? "AXUnknown"
            let labels = labels(element, role: role)
            return NodeFacts(
                role: role,
                label: labels.display,
                identifier: string(element, "AXIdentifier"),
                value: string(element, kAXValueAttribute),
                selectedText: string(element, kAXSelectedTextAttribute),
                enabled: bool(element, kAXEnabledAttribute),
                focused: bool(element, kAXFocusedAttribute),
                selected: bool(element, kAXSelectedAttribute),
                actions: recorder.readActions(axReadActionNames(element)),
                frame: frame(element),
                subrole: string(element, kAXSubroleAttribute),
                stableIdentityLabel: labels.identity
            )
        },
        role: { node in
            AXUIElementSetMessagingTimeout(node.element, perElementAXTimeout)
            return string(node.element, kAXRoleAttribute, required: true) ?? "AXUnknown"
        },
        frame: { node in
            AXUIElementSetMessagingTimeout(node.element, viewportProbeAXTimeout)
            return frame(node.element)
        },
        children: { node in
            AXUIElementSetMessagingTimeout(node.element, perElementAXTimeout)
            return (recorder.readElements(axReadElements(node.element, kAXChildrenAttribute)) ?? [])
                .map(AXNode.init)
        },
        visibleCollectionChildren: { node in
            for attribute in ["AXVisibleRows", "AXVisibleChildren"] {
                let visible = recorder.readElements(axReadElements(node.element, attribute)) ?? []
                if !visible.isEmpty { return visible.map(AXNode.init) }
            }
            return nil
        },
        collectionTotal: { node in
            recorder.read(axReadAttribute(node.element, "AXRows")) { value in
                (value as? [AnyObject])?.count
            }
        },
        equals: { CFEqual($0.element, $1.element) },
        handle: { $0.element },
        coverage: { recorder.coverage },
        coverageDiagnostic: { recorder.diagnostic }
    )
}

func buildTree(
    window: AXUIElement, windowOrigin: CGPoint, pixelsPerPoint: Double, generation: String,
    maxElements: Int = defaultMaxTreeElements, skeleton: Bool = false,
    windowCollections: Bool = true
) -> BuiltTree {
    buildTreeCore(
        root: AXNode(element: window), accessors: axTreeAccessors(),
        windowOrigin: windowOrigin, pixelsPerPoint: pixelsPerPoint, generation: generation,
        maxElements: maxElements, skeleton: skeleton,
        windowCollections: windowCollections)
}

// MARK: - Labels and line rendering

/// Label as the snapshot stores it: title, description, placeholder, then an
/// informative role description. The stale-element identity re-check
/// (matchesIdentity in Snapshot.swift) must derive the live label through
/// this same chain, or elements labeled by a late fallback can never match.
func snapshotLabel(_ element: AXUIElement, role: String) -> String? {
    axString(element, kAXTitleAttribute)
        ?? axString(element, kAXDescriptionAttribute)
        ?? axString(element, "AXPlaceholderValue")
        ?? informativeRoleDescription(
            role: role, description: axString(element, kAXRoleDescriptionAttribute))
}

/// Default role descriptions that don't echo their role name and never add
/// signal: window subrole flavors, WebKit's web-area description, and
/// outline/table row flavors (System Settings would repeat "outline row" on
/// every row). Compared after normalization (lowercased, alphanumerics only).
private let genericRoleDescriptions: Set<String> = [
    "standardwindow", "floatingwindow", "dialog", "systemdialog",
    "htmlcontent", "outlinerow", "tablerow",
]

/// A role description worth using as a label-of-last-resort. Apps attach
/// real context to otherwise-anonymous controls ("close button" on window
/// chrome, "switch" on SwiftUI toggles, "banner" on landmark groups).
/// Standard controls merely localize their role ("button" for AXButton,
/// "text" for AXStaticText) — dropped, along with known generic defaults,
/// so label-poor native trees don't fill up with restated roles.
func informativeRoleDescription(role: String, description: String?) -> String? {
    guard let description else { return nil }
    func normalize(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
    let normalizedDescription = normalize(description)
    guard !normalizedDescription.isEmpty else { return nil }
    guard !normalize(role).contains(normalizedDescription) else { return nil }
    guard !genericRoleDescriptions.contains(normalizedDescription) else { return nil }
    return description
}

/// AXIdentifier trimmed for display on an unlabeled element's outline line.
/// Developer-assigned identifiers ("AddAccountButton", "sidebar.search")
/// are real signal for telling icon-only controls apart; auto-generated ids
/// are noise — skipped when more than half the characters are digits or
/// hyphens (UUIDs, numeric ids). Long identifiers truncate to 40 chars.
func displayableIdentifier(_ identifier: String?) -> String? {
    guard let identifier, !identifier.isEmpty else { return nil }
    let noise = identifier.filter { $0.isNumber || $0 == "-" }.count
    guard noise * 2 <= identifier.count else { return nil }
    guard identifier.count > 40 else { return identifier }
    return String(identifier.prefix(40)) + "…"
}

func describeLine(_ facts: NodeFacts, id: String, frame: [Double]?, depth: Int) -> String {
    var parts: [String] = ["\(id) \(facts.role)"]

    if let label = facts.label, !label.isEmpty {
        parts.append("\"\(clean(label))\"")
    } else if let identifier = displayableIdentifier(facts.identifier) {
        // Keep the developer identifier separate from the human label. It is
        // also retained as optional fingerprint evidence in CapturedNode.
        parts.append("id=\"\(clean(identifier))\"")
    }
    if let frame, frame.count >= 4 {
        let coordinates = frame.prefix(4).map(integerDescription).joined(separator: ",")
        parts.append("(\(coordinates))")
    }
    if let value = facts.value, !value.isEmpty {
        parts.append("value=\"\(clean(truncate(value)))\"")
    }
    if let selected = facts.selectedText, !selected.isEmpty {
        parts.append("selected=\"\(clean(truncate(selected)))\"")
    }
    if facts.enabled == false {
        parts.append("disabled")
    }
    if facts.focused == true {
        parts.append("focused")
    }
    if facts.selected == true {
        parts.append("selected")
    }
    // Keep standard AX* actions; custom app actions often embed junk
    // (selector dumps, newlines) that pollutes the tree.
    let actions = facts.actions.filter { name in
        name.hasPrefix("AX") && name.allSatisfy { $0.isLetter || $0.isNumber }
    }
    if !actions.isEmpty {
        parts.append("actions=\(actions.map { String($0.dropFirst(2)) }.joined(separator: ","))")
    }

    return String(repeating: "\t", count: depth) + parts.joined(separator: " ")
}

private func truncate(_ value: String) -> String {
    guard value.count > maxValueLength else { return value }
    return String(value.prefix(maxValueLength)) + "… [+\(value.count - maxValueLength) chars; use a scoped get_app_state capture]"
}

private func clean(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\t", with: " ")
}
