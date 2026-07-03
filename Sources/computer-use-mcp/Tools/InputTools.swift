// press_key, scroll, drag — the synthetic-input tools.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MCP

func pressKeyImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    let confirmed = SafetyPolicy.confirmed(args)
    try SafetyPolicy.check(app: app, confirmed: confirmed)
    let allowGlobalKeyboard = try allowGlobalKeyboardArgument(args)
    let focus = FocusChangeTracker.start(focusChangeAllowed: allowGlobalKeyboard)
    let combo = try args.requireString("key")
    let chord = try Keymap.parse(combo)
    try SafetyPolicy.checkKey(
        combo: combo, chord: chord,
        focused: axElement(app.axApplication, kAXFocusedUIElementAttribute),
        app: app, confirmed: confirmed
    )

    let window = try? targetWindow(for: app, title: await SnapshotStore.shared.load(forPid: app.pid)?.windowTitle)
    let context = DeliveryContext(
        pid: app.pid,
        windowNumber: window.flatMap { windowID(for: $0.element) },
        windowFrame: window?.frame,
        allowGlobalCursor: allowGlobalKeyboard
    )
    let targetAppIsActive = NSRunningApplication(processIdentifier: app.pid)?.isActive == true
    let deliveryMode = try deliverKey(chord, context: context, targetAppIsActive: targetAppIsActive)
    try? await Task.sleep(for: .milliseconds(80))

    return try await stateResult(
        app: app, windowTitle: window?.title, note: "Pressed \(combo).",
        screenshot: screenshotDetail(args),
        focusTelemetry: focus.finish(deliveryTier: deliveryMode.rawValue)
    )
}

func scrollImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    try SafetyPolicy.check(app: app, confirmed: SafetyPolicy.confirmed(args))
    let focus = FocusChangeTracker.start()
    let target = try await resolvePointTarget(args, app: app)

    // Route the wheel to the real scroll container, not whatever leaf the point
    // landed on: walk the AX ancestor chain and rank candidates for
    // scrollability. The container's own viewport (not a ~20px row) then also
    // sizes a semantic direction+pages scroll correctly.
    let ranked = target.element.map { rankedScrollContainers(from: $0) } ?? []

    var deltaX = args.integer("delta_x") ?? 0
    var deltaY = args.integer("delta_y") ?? 0
    if let direction = args.string("direction") {
        let pages = try ArgumentBounds.checkScrollPages(args.number("pages") ?? 1)
        // Size a page from the top-ranked container's *visible* viewport (not a
        // ~20px leaf row, nor a web area's full content height); fall back to the
        // hit element, then a default page height.
        let viewport = (ranked.first ?? target.element)
            .flatMap { visibleViewport(of: $0, windowFrame: target.deliveryContext.windowFrame) }
        switch direction {
        case "down": deltaY = Int(Double(viewport?.height ?? 400) * pages)
        case "up": deltaY = -Int(Double(viewport?.height ?? 400) * pages)
        case "right": deltaX = Int(Double(viewport?.width ?? 400) * pages)
        case "left": deltaX = -Int(Double(viewport?.width ?? 400) * pages)
        default:
            throw ToolError.invalidArguments("direction must be up, down, left, or right.")
        }
    }
    guard deltaX != 0 || deltaY != 0 else {
        throw ToolError.invalidArguments("Provide direction (+ optional pages), or a non-zero delta_x/delta_y.")
    }
    try ArgumentBounds.checkScrollDelta(deltaX: deltaX, deltaY: deltaY)

    // Pick the container to drive. Post the wheel at the hit point itself — it
    // already lies inside every ancestor we walked up through, so it is over the
    // chosen container; relocating to a container centre can land the event on a
    // sibling region (an outer scroll area's centre sits over other content).
    // Only synthesize a point from the container when the target exposes none.
    let container = chooseScrollContainer(ranked, deltaX: deltaX, deltaY: deltaY)
    var fallbackReasons: [FallbackReason] = []
    let point: CGPoint
    if let hit = target.point {
        point = hit
    } else if let container, let frame = axFrame(container) {
        point = CGPoint(x: frame.midX, y: frame.midY)
    } else {
        if container == nil { fallbackReasons.append(.noScrollContainerFound) }
        point = try target.requirePoint()
    }

    // Evidence read off the chosen container's own scroll bars: whether it is
    // already pinned in the scroll direction (so "no movement" is expected), and
    // a before/after position signature that confirms the content actually moved.
    var before = ActionVerification()
    before.scrollAtExtent = container.flatMap { scrollAtExtent(container: $0, deltaX: deltaX, deltaY: deltaY) }
    if let container {
        before.notes.append(
            "Routed the scroll to a \(axRole(container)) container "
                + "(\(ranked.count) scrollable candidate\(ranked.count == 1 ? "" : "s") on the ancestor chain).")
    }
    let beforeOffset = container.flatMap(scrollOffsetSignature)

    await AgentCursor.shared.glide(to: point, targetWindow: target.deliveryContext.windowNumber)
    let tier = deliverScroll(at: point, deltaX: deltaX, deltaY: deltaY, context: target.deliveryContext)
    try? await Task.sleep(for: .milliseconds(80))

    if let container, let beforeOffset, let afterOffset = scrollOffsetSignature(container) {
        before.scrollPositionChanged = beforeOffset != afterOffset
    }

    let verifier = ActionVerifier(
        family: .scroll, intent: .scrollContent, deliveryTier: tier.rawValue,
        dispatchSucceeded: true, hasTargetElement: false, snapshotElement: nil,
        before: before, beforeWindowTitle: target.snapshot.windowTitle)
    return try await stateResult(
        app: app, windowTitle: target.snapshot.windowTitle,
        note: "Scrolled (\(deltaX),\(deltaY)) at \(target.description).",
        screenshot: screenshotDetail(args),
        focusTelemetry: focus.finish(deliveryTier: tier.rawValue, fallbackReasons: fallbackReasons),
        verifier: verifier
    )
}

func dragImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    try SafetyPolicy.check(app: app, confirmed: SafetyPolicy.confirmed(args))
    let focus = FocusChangeTracker.start()
    guard let snapshot = await SnapshotStore.shared.load(forPid: app.pid) else {
        throw ToolError.failed("Call get_app_state for \(app.name) before dragging.")
    }
    let from = try screenPoint(x: try args.requireNumber("from_x"), y: try args.requireNumber("from_y"), snapshot: snapshot)
    let to = try screenPoint(x: try args.requireNumber("to_x"), y: try args.requireNumber("to_y"), snapshot: snapshot)

    // Gate a drop onto a destructive target (e.g. the Trash) like a click.
    let confirmed = SafetyPolicy.confirmed(args)
    if let destination = accessibilityElement(at: to, pid: app.pid) {
        try SafetyPolicy.checkClick(label: clickableLabel(destination), app: app, confirmed: confirmed)
    }

    let window = try? targetWindow(for: app, title: snapshot.windowTitle)
    let context = DeliveryContext(
        pid: app.pid,
        windowNumber: window.flatMap { windowID(for: $0.element) },
        windowFrame: window?.frame,
        allowGlobalCursor: false
    )
    await AgentCursor.shared.glide(to: from, targetWindow: context.windowNumber)
    let tier = await deliverDrag(from: from, to: to, context: context)
    await AgentCursor.shared.pulse(at: to, targetWindow: context.windowNumber)
    try? await Task.sleep(for: .milliseconds(80))

    // Drag is a coordinate gesture with no re-readable target: success on a
    // whole-window change, verifier_ambiguous otherwise (a drag with no visible
    // effect could be a legitimate no-op).
    let verifier = ActionVerifier(
        family: .drag, intent: .activate, deliveryTier: tier.rawValue,
        dispatchSucceeded: true, hasTargetElement: false, snapshotElement: nil,
        beforeWindowTitle: snapshot.windowTitle)
    return try await stateResult(
        app: app, windowTitle: snapshot.windowTitle,
        note: "Dragged from (\(Int(from.x.rounded())),\(Int(from.y.rounded()))) "
            + "to (\(Int(to.x.rounded())),\(Int(to.y.rounded()))).",
        screenshot: screenshotDetail(args),
        focusTelemetry: focus.finish(deliveryTier: tier.rawValue),
        verifier: verifier
    )
}
