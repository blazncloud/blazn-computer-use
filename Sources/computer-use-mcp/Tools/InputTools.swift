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

    let storedSnapshot = await SnapshotStore.shared.load(forPid: app.pid)
    let window: TargetWindow?
    if pressKeyRequiresSnapshotIdentity(storedSnapshotExists: storedSnapshot != nil),
        let storedSnapshot
    {
        let resolved = try targetWindow(for: app, title: storedSnapshot.windowTitle)
        try requireCompatibleSnapshotIdentity(
            snapshot: storedSnapshot, app: app, window: resolved, requirement: .mutation)
        window = resolved
    } else {
        // A focused key chord has no snapshot-derived target or coordinates.
        // Use current window context for delivery telemetry, but do not let an
        // unrelated legacy/lineage-less snapshot block the mutation.
        window = try? targetWindow(for: app, title: nil)
    }
    let context = DeliveryContext(
        pid: app.pid,
        windowNumber: window.flatMap { windowID(for: $0.element) },
        windowFrame: window?.frame,
        allowGlobalCursor: allowGlobalKeyboard
    )
    let verifyEffect = args.bool("include_state") != false
    let deliveryObserver = verifyEffect ? window.flatMap {
        AXDeliveryObserver(
            pid: app.pid, application: app.axApplication, window: $0.element,
            target: axElement(app.axApplication, kAXFocusedUIElementAttribute),
            family: .secondaryAction)
    } : nil
    let deliveryRevision = deliveryObserver?.revision
    let targetAppIsActive = NSRunningApplication(processIdentifier: app.pid)?.isActive == true
    let deliveryMode = try deliverKey(chord, context: context, targetAppIsActive: targetAppIsActive)
    if verifyEffect {
        await waitForDeliveryVerification(
            observer: deliveryObserver, baselineRevision: deliveryRevision,
            predicate: nil)
    }

    return try await recaptureAfterPressKey { windowTitle, windowID in
        try await stateResult(
        app: app, windowTitle: windowTitle, windowID: windowID,
        note: "Pressed \(combo).",
        screenshot: screenshotDetail(args),
        focusTelemetry: focus.finish(deliveryTier: deliveryMode.rawValue)
        )
    }
}

func recaptureAfterPressKey<T>(
    _ recapture: (String?, CGWindowID?) async throws -> T
) async throws -> T {
    try await recapture(nil, nil)
}

func pressKeyRequiresSnapshotIdentity(storedSnapshotExists _: Bool) -> Bool {
    false
}

private enum ScrollDeliveryPlan {
    case alreadyAtExtent
    case scrollBar(bar: AXUIElement, newValue: Double)
    case pageAction(container: AXUIElement, action: String, count: Int)
    case reveal(AXUIElement)
    case wheel
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

    let direction = args.string("direction")
    var deltaX = args.integer("delta_x") ?? 0
    var deltaY = args.integer("delta_y") ?? 0
    if let direction {
        let pages = try ArgumentBounds.checkScrollPages(args.number("pages") ?? 1)
        // Size a page from the top-ranked container's *visible* viewport (not a
        // ~20px leaf row, nor a web area's full content height); fall back to the
        // hit element, then a default page height.
        let viewport = (ranked.first ?? target.element)
            .flatMap { visibleViewport(of: $0, windowFrame: target.deliveryContext.windowFrame) }
        func pageDelta(_ size: CGFloat) throws -> Int {
            let raw = Double(size) * pages
            guard raw.isFinite, abs(raw) <= Double(ArgumentBounds.maxScrollDelta), let delta = safeInt(raw) else {
                throw ToolError.invalidArguments(
                    "The requested scroll distance is outside the supported delta range."
                )
            }
            return delta
        }
        switch direction {
        case "down": deltaY = try pageDelta(viewport?.height ?? 400)
        case "up": deltaY = -(try pageDelta(viewport?.height ?? 400))
        case "right": deltaX = try pageDelta(viewport?.width ?? 400)
        case "left": deltaX = -(try pageDelta(viewport?.width ?? 400))
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

    let pageCount = max(1, Int((args.number("pages") ?? 1).rounded()))
    let plan: ScrollDeliveryPlan
    if let direction {
        let vertical = direction == "down" || direction == "up"
        let barAttribute = vertical ? "AXVerticalScrollBar" : "AXHorizontalScrollBar"
        let ownerIndices = scrollOwnerCandidateIndices(atExtents: ranked.map {
            scrollAtExtent(container: $0, deltaX: deltaX, deltaY: deltaY)
        })
        // A collection often sits inside the AXScrollArea that owns its bar or
        // page action. Resolve that owner before delivery, skipping an inner
        // container already pinned in this direction. No route is attempted yet.
        let owners = ownerIndices.map { ranked[$0] }
        var semanticPlan: ScrollDeliveryPlan?
        for owner in owners {
            if let bar = axElement(owner, barAttribute),
                let current = (axAttribute(bar, kAXValueAttribute) as? NSNumber)?.doubleValue,
                try axAttributeIsSettable(bar, kAXValueAttribute as String)
            {
                let forward = direction == "down" || direction == "right"
                let proportion = scrollBarPageProportion(bar, vertical: vertical) ?? 0.9
                let newValue = scrolledBarValue(
                    current: current, pageProportion: proportion,
                    pages: args.number("pages") ?? 1, forward: forward)
                semanticPlan = abs(newValue - current) <= 1e-6
                    ? .alreadyAtExtent
                    : .scrollBar(bar: bar, newValue: newValue)
                break
            }
            if let actionName = scrollPageAction(for: direction),
                axActionNames(owner).contains(actionName)
            {
                semanticPlan = .pageAction(
                    container: owner, action: actionName, count: pageCount)
                break
            }
        }
        if let semanticPlan {
            plan = semanticPlan
        } else if let container,
            let reveal = descendantToRevealForScroll(
                container: container, direction: direction,
                pages: args.number("pages") ?? 1,
                windowFrame: target.deliveryContext.windowFrame)
        {
            plan = .reveal(reveal)
        } else {
            plan = .wheel
        }
    } else {
        plan = .wheel
    }

    let observedScrollElement: AXUIElement?
    switch plan {
    case .scrollBar(let bar, _): observedScrollElement = bar
    case .pageAction(let actionContainer, _, _): observedScrollElement = actionContainer
    case .reveal: observedScrollElement = container
    case .alreadyAtExtent, .wheel: observedScrollElement = container ?? target.element
    }
    let verifyEffect = args.bool("include_state") != false
    let deliveryObserver = verifyEffect ? AXDeliveryObserver(
        pid: app.pid, application: app.axApplication, window: target.windowElement,
        target: observedScrollElement, family: .scroll) : nil
    let deliveryRevision = deliveryObserver?.revision

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
    let beforeMovement = scrollMovementFingerprint(container: container, target: target.element)

    await AgentCursor.shared.glide(to: point, targetWindow: target.deliveryContext.windowNumber)

    // Execute exactly the route selected from pre-dispatch capabilities. An AX
    // acknowledgement is followed by observation, never another scroll route.
    let tier: InputTier
    let dispatched: Bool
    switch plan {
    case .alreadyAtExtent:
        tier = .accessibilityAttribute
        dispatched = false
        before.scrollAtExtent = true
        before.notes.append("The selected scroll bar is already at the requested extent.")
    case .scrollBar(let bar, let newValue):
        try checkCancellationBeforeDelivery()
        let error = AXUIElementSetAttributeValue(
            bar, kAXValueAttribute as CFString, NSNumber(value: newValue))
        guard error == .success else {
            throw ToolError.failed(
                "Setting the scroll-bar position failed (\(axErrorDescription(error))).")
        }
        tier = .accessibilityAttribute
        dispatched = true
        before.notes.append("Selected the container's settable scroll bar before delivery.")
    case .pageAction(let actionContainer, let action, let count):
        try checkCancellationBeforeDelivery()
        for _ in 0..<count {
            let error = AXUIElementPerformAction(actionContainer, action as CFString)
            guard error == .success else {
                throw ToolError.failed("\(action) failed (\(axErrorDescription(error))).")
            }
        }
        tier = .accessibilityAction
        dispatched = true
        before.notes.append("Selected the container's advertised \(action) action before delivery.")
    case .reveal(let reveal):
        try checkCancellationBeforeDelivery()
        let error = AXUIElementPerformAction(reveal, "AXScrollToVisible" as CFString)
        guard error == .success else {
            throw ToolError.failed(
                "AXScrollToVisible failed (\(axErrorDescription(error))).")
        }
        tier = .accessibilityAction
        dispatched = true
        before.notes.append("Selected one off-screen descendant to reveal before delivery.")
    case .wheel:
        tier = try deliverScroll(
            at: point, deltaX: deltaX, deltaY: deltaY,
            context: target.deliveryContext)
        dispatched = true
        if direction != nil { fallbackReasons.insert(.axActionUnsupported, at: 0) }
    }

    if dispatched && verifyEffect {
        await waitForDeliveryVerification(
            observer: deliveryObserver, baselineRevision: deliveryRevision,
            predicate: {
                scrollMovementChanged(
                    before: beforeMovement,
                    after: scrollMovementFingerprint(
                        container: container, target: target.element)) == true
            })
    }

    if let container, let beforeOffset, let afterOffset = scrollOffsetSignature(container) {
        before.scrollPositionChanged = beforeOffset != afterOffset
    }
    if let moved = scrollMovementChanged(
        before: beforeMovement,
        after: scrollMovementFingerprint(container: container, target: target.element))
    {
        before.scrollContentChanged = moved
    }

    let verifier = ActionVerifier(
        family: .scroll, intent: .scrollContent, deliveryTier: tier.rawValue,
        dispatchSucceeded: dispatched, hasTargetElement: false, snapshotElement: nil,
        before: before, beforeWindowTitle: target.snapshot.windowTitle)
    return try await stateResult(
        app: app, windowTitle: target.snapshot.windowTitle,
        windowID: target.deliveryContext.windowNumber,
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
    let window = try resolveMutationWindow(snapshot: snapshot, app: app)
    try requireFreshCoordinateGeometry(snapshot: snapshot, window: window)
    let from = try screenPoint(x: try args.requireNumber("from_x"), y: try args.requireNumber("from_y"), snapshot: snapshot)
    let to = try screenPoint(x: try args.requireNumber("to_x"), y: try args.requireNumber("to_y"), snapshot: snapshot)

    // Gate a drop onto a destructive target (e.g. the Trash) like a click.
    let confirmed = SafetyPolicy.confirmed(args)
    if let destination = accessibilityElement(at: to, pid: app.pid) {
        try SafetyPolicy.checkClick(label: clickableLabel(destination), app: app, confirmed: confirmed)
    }

    let context = DeliveryContext(
        pid: app.pid,
        windowNumber: window.lineageWindowID,
        windowFrame: window.frame,
        allowGlobalCursor: false
    )
    let verifyEffect = args.bool("include_state") != false
    let deliveryObserver = verifyEffect ? AXDeliveryObserver(
        pid: app.pid, application: app.axApplication, window: window.element,
        target: nil, family: .drag) : nil
    let deliveryRevision = deliveryObserver?.revision
    await AgentCursor.shared.glide(to: from, targetWindow: context.windowNumber)
    let tier = try await deliverDrag(from: from, to: to, context: context)
    await AgentCursor.shared.pulse(at: to, targetWindow: context.windowNumber)
    if verifyEffect {
        await waitForDeliveryVerification(
            observer: deliveryObserver, baselineRevision: deliveryRevision,
            predicate: nil)
    }

    // Drag is a coordinate gesture with no re-readable target: success on a
    // whole-window change, verifier_ambiguous otherwise (a drag with no visible
    // effect could be a legitimate no-op).
    let verifier = ActionVerifier(
        family: .drag, intent: .activate, deliveryTier: tier.rawValue,
        dispatchSucceeded: true, hasTargetElement: false, snapshotElement: nil,
        beforeWindowTitle: snapshot.windowTitle)
    return try await stateResult(
        app: app, windowTitle: snapshot.windowTitle,
        windowID: context.windowNumber,
        note: "Dragged from (\(roundedIntegerDescription(from.x)),\(roundedIntegerDescription(from.y))) "
            + "to (\(roundedIntegerDescription(to.x)),\(roundedIntegerDescription(to.y))).",
        screenshot: screenshotDetail(args),
        focusTelemetry: focus.finish(deliveryTier: tier.rawValue),
        verifier: verifier
    )
}
