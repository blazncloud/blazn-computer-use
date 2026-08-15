// click — by element id (preferred) or screenshot coordinates (fallback).
// Tier 1 uses the accessibility press/menu action when available (precise,
// background, no event posted); otherwise it descends the synthetic input
// ladder (per-window NSEvent → per-pid CGEvent → guarded global cursor).

import ApplicationServices
import Foundation
import MCP

func clickImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    let clickCount = try clickCountArgument(args)
    try requireAccessibilityTrusted()
    let buttonName = args.string("mouse_button") ?? "left"
    let confirmed = SafetyPolicy.confirmed(args)
    try SafetyPolicy.check(app: app, confirmed: confirmed)
    let allowGlobalCursor = try allowGlobalCursorArgument(args)
    let focus = FocusChangeTracker.start(
        focusChangeAllowed: allowGlobalCursor,
        cursorMovementAllowed: allowGlobalCursor
    )
    let target = try await resolvePointTarget(args, app: app, allowGlobalCursor: allowGlobalCursor)
    try SafetyPolicy.checkClick(label: clickTargetLabel(target), app: app, confirmed: confirmed)

    // Capture target-local state before deriving intent so a single checkbox
    // click can declare and verify the exact state transition it should cause.
    let before = ActionVerifier.captureBefore(
        target.element, family: .click, snapshotElement: target.snapshotElement)
    let intent = clickIntent(
        role: target.snapshotElement?.role,
        button: buttonName,
        clickCount: clickCount,
        beforeSelected: before.beforeSelected)

    // Read-act-read, pre-dispatch: a disabled control cannot perform the action.
    // Classify it `unsupported` and do not press a dead control — distinct from
    // a verified failure (retrying won't help), and not a raw throw.
    if let element = target.element, target.snapshotElement != nil,
        axBool(element, kAXEnabledAttribute) == false
    {
        let verifier = ActionVerifier(
            family: .click, intent: intent, deliveryTier: InputTier.accessibilityAction.rawValue,
            dispatchSucceeded: false, hasTargetElement: true, snapshotElement: target.snapshotElement,
            before: before,
            resolved: .unsupported(.unsupported, "\(target.description) is disabled and cannot be clicked."))
        return try await stateResult(
            app: app, windowTitle: target.snapshot.windowTitle,
            windowID: target.deliveryContext.windowNumber,
            note: "\(target.description) is disabled; no click was performed.",
            screenshot: screenshotDetail(args),
            focusTelemetry: focus.finish(deliveryTier: InputTier.accessibilityAction.rawValue),
            verifier: verifier)
    }

    let verifyEffect = args.bool("include_state") != false
    let deliveryObserver = verifyEffect ? AXDeliveryObserver(
        pid: app.pid, application: app.axApplication, window: target.windowElement,
        target: target.element, family: .click) : nil
    let deliveryRevision = deliveryObserver?.revision

    let outcome: InputActionOutcome
    switch buttonName {
    case "left":
        outcome = try await leftClick(target, clickCount: clickCount)
    case "right":
        outcome = try rightClick(target)
    case "middle":
        let delivery = try deliverClick(at: target.requirePoint(), button: .middle, clickCount: clickCount, context: target.deliveryContext)
        outcome = InputActionOutcome(
            note: "Middle-clicked \(target.description) [\(delivery.tier.rawValue)].",
            deliveryTier: delivery.tier, fallbackReasons: delivery.fallbackReasons
        )
    default:
        throw ToolError.invalidArguments("mouse_button \"\(buttonName)\" is not supported.")
    }

    let verificationPredicate: (() async -> Bool)?
    if let snapshotElement = target.snapshotElement, intent != .activate {
        verificationPredicate = {
            await retainedTargetSatisfies(
                snapshotElement: snapshotElement, window: target.windowElement,
                family: .click, intent: intent, before: before)
        }
    } else {
        verificationPredicate = nil
    }
    if verifyEffect {
        await waitForDeliveryVerification(
            observer: deliveryObserver, baselineRevision: deliveryRevision,
            predicate: verificationPredicate)
    }

    // The click landed: ripple the overlay at the point so the user sees it.
    if let point = target.point {
        await AgentCursor.shared.pulse(at: point, targetWindow: target.deliveryContext.windowNumber)
    }

    let verifier = ActionVerifier(
        family: .click, intent: intent, deliveryTier: outcome.deliveryTier.rawValue,
        dispatchSucceeded: true, hasTargetElement: target.snapshotElement != nil,
        snapshotElement: target.snapshotElement, before: before,
        beforeWindowTitle: target.snapshot.windowTitle)

    return try await stateResult(
        app: app, windowTitle: target.snapshot.windowTitle,
        windowID: target.deliveryContext.windowNumber, note: outcome.note,
        screenshot: screenshotDetail(args),
        focusTelemetry: focus.finish(
            deliveryTier: outcome.deliveryTier.rawValue, fallbackReasons: outcome.fallbackReasons,
            landedRung: outcome.landedRung),
        verifier: verifier
    )
}

/// The intended effect of a click, for the outcome verifier. A single left click
/// focuses text fields and toggles checkboxes with known state. Other clicks are
/// generic activations whose effect is an observed change.
func clickIntent(
    role: String?, button: String, clickCount: Int, beforeSelected: Bool?
) -> ActionIntent {
    guard button == "left", clickCount == 1 else { return .activate }
    if let role, isTextEntryRole(role) { return .focusTarget }
    if role == "AXCheckBox", let beforeSelected {
        return .toggle(!beforeSelected)
    }
    if role == "AXRadioButton", beforeSelected != nil {
        return .toggle(true)
    }
    return .activate
}

func clickCountArgument(_ args: [String: Value]) throws -> Int {
    if args["click_count"] != nil {
        guard let rawClickCount = args.integer("click_count") else {
            throw ToolError.invalidArguments("\"click_count\" must be an integer.")
        }
        return try ArgumentBounds.checkClickCount(rawClickCount)
    }
    return 1
}

/// Best-effort label for the click target, for the safety check.
private func clickTargetLabel(_ target: PointTarget) -> String? {
    target.element.flatMap(clickableLabel)
}

private struct InputActionOutcome {
    let note: String
    let deliveryTier: InputTier
    let fallbackReasons: [FallbackReason]
    /// The AX chain rung whose verified effect landed the click (tier 1 only).
    let landedRung: String?

    init(
        note: String, deliveryTier: InputTier, fallbackReasons: [FallbackReason] = [], landedRung: String? = nil
    ) {
        self.note = note
        self.deliveryTier = deliveryTier
        self.fallbackReasons = fallbackReasons
        self.landedRung = landedRung
    }
}

private func leftClick(_ target: PointTarget, clickCount: Int) async throws -> InputActionOutcome {
    // Animate the (cosmetic) agent cursor to the target before acting.
    if let point = target.point {
        await AgentCursor.shared.glide(to: point, targetWindow: target.deliveryContext.windowNumber)
    }

    // Select one route before dispatch. A supported AXPress owns the operation;
    // once it is attempted we never continue into synthetic delivery. Walking
    // to one pressable ancestor is target resolution, not another action.
    let pressable = target.element.flatMap {
        selfOrAncestor(of: $0, supporting: kAXPressAction as String)
    }
    switch clickDeliveryRoute(hasPressableElement: pressable != nil) {
    case .axPress:
        guard let pressable else { preconditionFailure("AXPress route requires an action owner") }
        try await performRepeatedAXPress(
            count: clickCount,
            primitive: { AXUIElementPerformAction(pressable, kAXPressAction as CFString) },
            betweenPresses: { try? await Task.sleep(for: .milliseconds(80)) },
            failureMessage: "AXPress failed on \(target.description)")
        let verb = clickCount > 1 ? "Double-pressed" : "Pressed"
        return InputActionOutcome(
            note: "\(verb) \(target.description) via accessibility [tier1-ax-action].",
            deliveryTier: .accessibilityAction,
            landedRung: "ax-press"
        )
    case .synthetic:
        // AXPress was unsupported before dispatch, so one synthetic route is safe.
        let delivery = try deliverClick(
            at: target.requirePoint(), button: .left,
            clickCount: clickCount, context: target.deliveryContext)
        let verb = clickCount > 1 ? "Double-clicked" : "Clicked"
        return InputActionOutcome(
            note: "\(verb) \(target.description) [\(delivery.tier.rawValue)].",
            deliveryTier: delivery.tier,
            fallbackReasons: [.axActionUnsupported] + delivery.fallbackReasons
        )
    }
}

func performRepeatedAXPress(
    count: Int,
    primitive: () -> AXError,
    betweenPresses: () async -> Void,
    failureMessage: String
) async throws {
    try checkCancellationBeforeDelivery()
    for index in 0..<count {
        let error = primitive()
        guard error == .success else {
            throw ToolError.failed("\(failureMessage) (\(axErrorDescription(error))).")
        }
        guard index + 1 < count else { continue }
        await betweenPresses()
        // Delivery already began. Cancellation now is intentionally generic,
        // so Dispatch records unknown rather than a false safe-retry abort.
        if Task.isCancelled { throw CancellationError() }
    }
}

private func rightClick(_ target: PointTarget) throws -> InputActionOutcome {
    // Tier 1: accessibility context-menu action.
    if let element = target.element,
        let menu = selfOrAncestor(of: element, supporting: "AXShowMenu")
    {
        try checkCancellationBeforeDelivery()
        let error = AXUIElementPerformAction(menu, "AXShowMenu" as CFString)
        guard error == .success else {
            throw ToolError.failed("AXShowMenu failed on \(target.description) (\(axErrorDescription(error))).")
        }
        return InputActionOutcome(
            note: "Opened context menu on \(target.description) via accessibility [tier1-ax-action].",
            deliveryTier: .accessibilityAction
        )
    }
    let delivery = try deliverClick(at: target.requirePoint(), button: .right, clickCount: 1, context: target.deliveryContext)
    return InputActionOutcome(
        note: "Right-clicked \(target.description) [\(delivery.tier.rawValue)].",
        deliveryTier: delivery.tier,
        fallbackReasons: [.axActionUnsupported] + delivery.fallbackReasons
    )
}
