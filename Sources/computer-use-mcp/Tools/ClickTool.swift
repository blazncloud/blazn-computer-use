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

    // The click landed: ripple the overlay at the point so the user sees it.
    if let point = target.point { await AgentCursor.shared.pulse(at: point) }

    return try await stateResult(
        app: app, windowTitle: target.snapshot.windowTitle, note: outcome.note,
        screenshot: screenshotDetail(args),
        focusTelemetry: focus.finish(deliveryTier: outcome.deliveryTier.rawValue, fallbackReasons: outcome.fallbackReasons)
    )
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

    init(note: String, deliveryTier: InputTier, fallbackReasons: [FallbackReason] = []) {
        self.note = note
        self.deliveryTier = deliveryTier
        self.fallbackReasons = fallbackReasons
    }
}

private func leftClick(_ target: PointTarget, clickCount: Int) async throws -> InputActionOutcome {
    // Animate the (cosmetic) agent cursor to the target before acting.
    if let point = target.point { await AgentCursor.shared.glide(to: point) }

    // Tier 1: accessibility press, when the element advertises it.
    if let element = target.element,
        let pressable = selfOrAncestor(of: element, supporting: kAXPressAction as String)
    {
        for _ in 0..<clickCount {
            let error = AXUIElementPerformAction(pressable, kAXPressAction as CFString)
            guard error == .success else {
                throw ToolError.failed("AXPress failed on \(target.description) (\(axErrorDescription(error))).")
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        let verb = clickCount > 1 ? "Double-pressed" : "Pressed"
        return InputActionOutcome(
            note: "\(verb) \(target.description) via accessibility [tier1-ax-action].",
            deliveryTier: .accessibilityAction
        )
    }

    // Tiers 2–4: synthetic click at the point. Tier 1 was unavailable (no
    // pressable element), which is the first reason delivery fell through.
    let delivery = try deliverClick(at: target.requirePoint(), button: .left, clickCount: clickCount, context: target.deliveryContext)
    let verb = clickCount > 1 ? "Double-clicked" : "Clicked"
    return InputActionOutcome(
        note: "\(verb) \(target.description) [\(delivery.tier.rawValue)].",
        deliveryTier: delivery.tier,
        fallbackReasons: [.axActionUnsupported] + delivery.fallbackReasons
    )
}

private func rightClick(_ target: PointTarget) throws -> InputActionOutcome {
    // Tier 1: accessibility context-menu action.
    if let element = target.element,
        let menu = selfOrAncestor(of: element, supporting: "AXShowMenu")
    {
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
