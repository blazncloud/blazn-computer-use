// Scroll container ranking: route a wheel event to the AX element that will
// actually consume it. A coordinate (or an element id) often lands on a leaf —
// a table row, a static label — that does not itself scroll, and whose tiny
// frame also mis-sizes a semantic direction+pages scroll. So we walk the
// ancestor chain from the hit/target element, score each candidate for
// scrollability, and drive the highest-ranked container (special-casing web
// areas). Mirrors BCU's ScrollRouteService, tuned to what our trees expose.

import ApplicationServices
import CoreGraphics
import Foundation

/// Extracted, side-effect-free features of a scroll-container candidate, so the
/// scoring policy is a pure function separate from the live AX reads.
struct ScrollCandidateFeatures: Equatable {
    let role: String
    let hasVerticalScrollBar: Bool
    let hasHorizontalScrollBar: Bool
    let supportsScrollToVisible: Bool
}

/// Fitness of a candidate as a scroll container. Tuned from what our trees
/// expose: a real AXScrollArea (or anything carrying scroll bars) is a strong
/// container; web-area/collection roles qualify on their own; a bare
/// scroll-to-visible action is only a weak hint (an element that can be
/// *scrolled into view* by its parent is not itself a scroller), below the
/// routing threshold. The scroll bar itself and its stepper/thumb are
/// disqualified so a wheel never targets the control instead of the content.
func scrollContainerScore(_ f: ScrollCandidateFeatures) -> Int {
    switch f.role {
    case "AXScrollBar", "AXValueIndicator", "AXIncrementor": return -100
    default: break
    }
    var score = 0
    if f.role == "AXScrollArea" { score += 100 }
    if f.hasVerticalScrollBar || f.hasHorizontalScrollBar { score += 40 }
    switch f.role {
    case "AXWebArea": score += 60
    case "AXTable", "AXOutline", "AXList", "AXGrid", "AXCollection", "AXBrowser": score += 30
    default: break
    }
    if f.supportsScrollToVisible { score += 5 }
    return score
}

/// Minimum score to treat a candidate as a routable scroll container. Above a
/// bare scroll-to-visible hint (5), at the collection-role floor (30) — so a
/// leaf whose only signal is scroll-to-visible does not masquerade as a scroller.
let scrollContainerRoutingThreshold = 30

/// True when a candidate scores high enough to route a wheel to.
func qualifiesAsScrollContainer(_ f: ScrollCandidateFeatures) -> Bool {
    scrollContainerScore(f) >= scrollContainerRoutingThreshold
}

/// Rank scroll-container candidates innermost-first. macOS routes a wheel to the
/// innermost scrollable region under the pointer, so proximity to the hit
/// element — not raw score — decides which container drives; the score only
/// gates whether a candidate is a container at all. Pure, so the ranking policy
/// is tested independent of the live AX walk.
func rankScrollCandidates<Item>(_ scored: [(item: Item, score: Int, depth: Int)]) -> [Item] {
    scored.filter { $0.score >= scrollContainerRoutingThreshold }
        .sorted { $0.depth < $1.depth }
        .map(\.item)
}

/// Live features of an element for the scoring function.
func scrollFeatures(_ element: AXUIElement) -> ScrollCandidateFeatures {
    ScrollCandidateFeatures(
        role: axRole(element),
        hasVerticalScrollBar: axElement(element, "AXVerticalScrollBar") != nil,
        hasHorizontalScrollBar: axElement(element, "AXHorizontalScrollBar") != nil,
        supportsScrollToVisible: axActionNames(element).contains("AXScrollToVisible")
    )
}

/// Walk from the hit/target element up the AX parent chain and return the
/// scroll containers among it and its ancestors, best-first.
func rankedScrollContainers(from element: AXUIElement, maxHops: Int = 8) -> [AXUIElement] {
    var scored: [(item: AXUIElement, score: Int, depth: Int)] = []
    var current: AXUIElement? = element
    var depth = 0
    while let node = current, depth <= maxHops {
        scored.append((node, scrollContainerScore(scrollFeatures(node)), depth))
        current = axElement(node, kAXParentAttribute)
        depth += 1
    }
    return rankScrollCandidates(scored)
}

/// Choose which ranked container to drive: the highest-ranked one that is not
/// already pinned at the boundary in the scroll direction, so a pinned outer
/// container does not swallow a scroll an inner one could still take. Falls back
/// to the top-ranked container; nil when nothing ranks as scrollable.
func chooseScrollContainer(_ ranked: [AXUIElement], deltaX: Int, deltaY: Int) -> AXUIElement? {
    guard let top = ranked.first else { return nil }
    for candidate in ranked where scrollAtExtent(container: candidate, deltaX: deltaX, deltaY: deltaY) != true {
        return candidate
    }
    return top
}

/// The scroll-bar fill (0…1) for an axis, read off the container's own bar.
func scrollBarValue(_ container: AXUIElement, vertical: Bool) -> Double? {
    let attribute = vertical ? "AXVerticalScrollBar" : "AXHorizontalScrollBar"
    guard let bar = axElement(container, attribute),
        let value = (axAttribute(bar, kAXValueAttribute) as? NSNumber)?.doubleValue
    else { return nil }
    return value
}

/// Is the container already pinned at the boundary in the requested direction?
/// Then "no movement" is expected, not a dropped event. nil when the bar is
/// unreadable — the reducer then leans on the whole-window change bit.
func scrollAtExtent(container: AXUIElement, deltaX: Int, deltaY: Int) -> Bool? {
    if deltaY != 0, let value = scrollBarValue(container, vertical: true) {
        return deltaY > 0 ? value >= 0.999 : value <= 0.001
    }
    if deltaX != 0, let value = scrollBarValue(container, vertical: false) {
        return deltaX > 0 ? value >= 0.999 : value <= 0.001
    }
    return nil
}

/// The AX page-scroll action name for a semantic direction, or nil for an
/// unrecognized one. These actions (AXScrollDownByPage, …) drive the container
/// directly through accessibility — reliable in the background, where a
/// synthetic wheel is often swallowed by SwiftUI/WebKit views.
func scrollPageAction(for direction: String) -> String? {
    switch direction {
    case "down": return "AXScrollDownByPage"
    case "up": return "AXScrollUpByPage"
    case "left": return "AXScrollLeftByPage"
    case "right": return "AXScrollRightByPage"
    default: return nil
    }
}

/// A movement fingerprint combining three signals, because no single one covers
/// every scroll surface:
///   - the container's scroll-bar fills (native scroll areas);
///   - the target element's on-screen origin (a web paragraph slides up);
///   - the target element's value (a virtualized list reuses the same AX element
///     at a fixed frame, so only its value changes — "Row 001" → "Row 025").
/// Compared before/after an action to decide if anything moved. All-"-" means
/// nothing was readable and movement cannot be confirmed.
func scrollMovementFingerprint(container: AXUIElement?, target: AXUIElement?) -> String {
    let offset = container.flatMap(scrollOffsetSignature) ?? "-"
    let origin = target.flatMap(axFrame).map { "\(Int($0.origin.x.rounded())),\(Int($0.origin.y.rounded()))" } ?? "-"
    let value = target.flatMap { axString($0, kAXValueAttribute) } ?? "-"
    return "\(offset)|\(origin)|\(value)"
}

/// Index of the candidate whose offset past the viewport edge is closest to the
/// target scroll distance (both positive, measured in the scroll axis). Pure, so
/// the "which descendant to reveal" policy is unit-tested without a live tree.
func nearestOffsetIndex(_ offsets: [Double], target: Double) -> Int? {
    offsets.enumerated()
        .filter { $0.element > 0 }
        .min { abs($0.element - target) < abs($1.element - target) }?
        .offset
}

/// Equivalent AX scroll for containers that expose no page-scroll action (web
/// areas): the off-screen descendant to reveal so that scrolling it into view
/// advances the content ~`pages` viewports in the requested direction. Collects
/// descendants that support AXScrollToVisible and sit past the viewport edge in
/// that direction, then picks the one whose distance past the edge is closest to
/// the requested amount. nil when nothing is revealable (e.g. a virtualized list
/// whose off-screen rows are not realized).
func descendantToRevealForScroll(
    container: AXUIElement, direction: String, pages: Double, windowFrame: CGRect?
) -> AXUIElement? {
    guard let viewport = visibleViewport(of: container, windowFrame: windowFrame) else { return nil }
    let vertical = direction == "down" || direction == "up"
    let towardPositive = direction == "down" || direction == "right"

    var elements: [AXUIElement] = []
    var offsets: [Double] = []
    func edgeOffset(_ frame: CGRect) -> Double {
        if vertical {
            return towardPositive ? Double(frame.minY - viewport.maxY) : Double(viewport.minY - frame.maxY)
        }
        return towardPositive ? Double(frame.minX - viewport.maxX) : Double(viewport.minX - frame.maxX)
    }
    func walk(_ element: AXUIElement, depth: Int) {
        guard depth < 12, elements.count < 500 else { return }
        if axActionNames(element).contains("AXScrollToVisible"), let frame = axFrame(element) {
            let offset = edgeOffset(frame)
            if offset > 0 {
                elements.append(element)
                offsets.append(offset)
            }
        }
        for child in axElements(element, kAXChildrenAttribute) { walk(child, depth: depth + 1) }
    }
    walk(container, depth: 0)

    let target = (vertical ? Double(viewport.height) : Double(viewport.width)) * pages
    return nearestOffsetIndex(offsets, target: target).map { elements[$0] }
}

/// The container's visible viewport: its frame clipped to the window. A web
/// area (and some scroll areas) reports its *content* frame, which can be many
/// screens tall — sizing a "page" from that would scroll the whole document, so
/// page-sized scrolls measure the clipped, on-screen height instead. Falls back
/// to the raw frame when there is no window frame or the clip is degenerate.
func visibleViewport(of element: AXUIElement, windowFrame: CGRect?) -> CGRect? {
    guard let frame = axFrame(element) else { return nil }
    guard let windowFrame else { return frame }
    let clipped = frame.intersection(windowFrame)
    return (clipped.isNull || clipped.isEmpty) ? frame : clipped
}

/// A signature of the container's scroll position (both bar fills), compared
/// before/after to detect whether the content actually moved. nil when neither
/// bar is readable.
func scrollOffsetSignature(_ container: AXUIElement) -> String? {
    let v = scrollBarValue(container, vertical: true)
    let h = scrollBarValue(container, vertical: false)
    guard v != nil || h != nil else { return nil }
    func fmt(_ value: Double?) -> String { value.map { String(format: "%.5f", $0) } ?? "-" }
    return "\(fmt(v)),\(fmt(h))"
}
