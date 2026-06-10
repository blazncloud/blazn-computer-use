// click — by element id (preferred) or screenshot coordinates (fallback).
// Tier 1 uses the accessibility press/menu action when available (precise,
// background, no event posted); otherwise it descends the synthetic input
// ladder (per-window NSEvent → per-pid CGEvent → guarded global cursor).

import ApplicationServices
import Foundation
import MCP

func clickImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    let buttonName = args.string("mouse_button") ?? "left"
    let clickCount = max(1, args.integer("click_count") ?? 1)
    let confirmed = SafetyPolicy.confirmed(args)
    try SafetyPolicy.check(app: app, confirmed: confirmed)
    let target = try resolvePointTarget(args, app: app)
    try SafetyPolicy.checkClick(label: clickTargetLabel(target), app: app, confirmed: confirmed)

    let note: String
    switch buttonName {
    case "left":
        note = try await leftClick(target, clickCount: clickCount)
    case "right":
        note = try rightClick(target)
    case "middle":
        guard target.point != .zero else {
            throw ToolError.invalidArguments("middle click requires a resolvable point.")
        }
        let tier = try deliverClick(at: target.point, button: .middle, clickCount: clickCount, context: target.deliveryContext)
        note = "Middle-clicked \(target.description) [\(tier.rawValue)]."
    default:
        throw ToolError.invalidArguments("mouse_button \"\(buttonName)\" is not supported.")
    }

    return try await stateResult(app: app, windowTitle: target.snapshot.windowTitle, note: note)
}

/// Best-effort label for the click target, for the safety check.
private func clickTargetLabel(_ target: PointTarget) -> String? {
    target.element.flatMap(clickableLabel)
}

private func leftClick(_ target: PointTarget, clickCount: Int) async throws -> String {
    // Animate the (cosmetic) agent cursor to the target before acting.
    if target.point != .zero { await AgentCursor.shared.glide(to: target.point) }

    // Tier 1: accessibility press, when the element advertises it.
    if let element = target.element,
        let pressable = selfOrAncestor(of: element, supporting: kAXPressAction as String)
    {
        for _ in 0..<clickCount {
            let error = AXUIElementPerformAction(pressable, kAXPressAction as CFString)
            guard error == .success else {
                throw ToolError.failed("AXPress failed on \(target.description) (AXError \(error.rawValue)).")
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        let verb = clickCount > 1 ? "Double-pressed" : "Pressed"
        return "\(verb) \(target.description) via accessibility [tier1-ax-action]."
    }

    // Tiers 2–4: synthetic click at the point.
    let tier = try deliverClick(at: target.point, button: .left, clickCount: clickCount, context: target.deliveryContext)
    let verb = clickCount > 1 ? "Double-clicked" : "Clicked"
    return "\(verb) \(target.description) [\(tier.rawValue)]."
}

private func rightClick(_ target: PointTarget) throws -> String {
    // Tier 1: accessibility context-menu action.
    if let element = target.element,
        let menu = selfOrAncestor(of: element, supporting: "AXShowMenu")
    {
        let error = AXUIElementPerformAction(menu, "AXShowMenu" as CFString)
        guard error == .success else {
            throw ToolError.failed("AXShowMenu failed on \(target.description) (AXError \(error.rawValue)).")
        }
        return "Opened context menu on \(target.description) via accessibility [tier1-ax-action]."
    }
    let tier = try deliverClick(at: target.point, button: .right, clickCount: 1, context: target.deliveryContext)
    return "Right-clicked \(target.description) [\(tier.rawValue)]."
}
