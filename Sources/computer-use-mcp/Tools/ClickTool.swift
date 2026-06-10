// click — by element id (preferred) or screenshot coordinates (fallback).
// M2 implements the accessibility path: AXPress on the element, or on the
// hit-tested element under the coordinate. The synthetic-event ladder for
// elements without AXPress lands in M3.

import ApplicationServices
import Foundation
import MCP

func clickImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    let button = args.string("mouse_button") ?? "left"
    let clickCount = max(1, args.integer("click_count") ?? 1)

    if let elementID = args.string("element_id") {
        let target = try resolveTarget(app: app, elementID: elementID)
        return try await clickResolved(target, app: app, button: button, clickCount: clickCount)
    }

    if let x = args.number("x"), let y = args.number("y") {
        guard let snapshot = SnapshotStore.load(forPid: app.pid) else {
            throw ToolError.failed("Call get_app_state for \(app.name) before clicking by coordinates.")
        }
        let point = try screenPoint(x: x, y: y, snapshot: snapshot)
        guard let hit = accessibilityElement(at: point, pid: app.pid) else {
            throw ToolError.failed(
                "Nothing found at (\(Int(x)), \(Int(y))) in \(app.name). The point may be "
                    + "empty space — check coordinates against the latest screenshot."
            )
        }
        let pressable = selfOrAncestor(of: hit, supporting: kAXPressAction as String)
        let element = pressable ?? hit
        let synthetic = SnapshotElement(
            id: "(\(Int(x)),\(Int(y)))",
            role: axRole(element),
            label: axString(element, kAXTitleAttribute) ?? axString(element, kAXDescriptionAttribute),
            path: [],
            frame: [x, y, 0, 0]
        )
        let target = ResolvedTarget(app: app, snapshot: snapshot, snapshotElement: synthetic, element: element)
        guard pressable != nil else {
            throw ToolError.failed(
                "The element at (\(Int(x)), \(Int(y))) (\(synthetic.role)) does not support "
                    + "a press action yet. Synthetic clicks arrive in the next milestone; "
                    + "try an element id with actions=Press from get_app_state."
            )
        }
        return try await clickResolved(target, app: app, button: button, clickCount: clickCount)
    }

    throw ToolError.invalidArguments("Provide element_id, or x and y screenshot coordinates.")
}

private func clickResolved(
    _ target: ResolvedTarget, app: ResolvedApp, button: String, clickCount: Int
) async throws -> CallTool.Result {
    switch button {
    case "left":
        guard let pressable = selfOrAncestor(of: target.element, supporting: kAXPressAction as String) else {
            throw ToolError.failed(
                "\(describeTarget(target)) has no press action. Synthetic clicks arrive in "
                    + "the next milestone; look for an element with actions=Press, or use "
                    + "perform_secondary_action for other accessibility actions."
            )
        }
        let pressTarget = ResolvedTarget(
            app: target.app, snapshot: target.snapshot,
            snapshotElement: target.snapshotElement, element: pressable
        )
        for _ in 0..<clickCount {
            try performAXAction(kAXPressAction as String, on: pressTarget)
            try? await Task.sleep(for: .milliseconds(80))
        }
    case "right":
        guard let menuTarget = selfOrAncestor(of: target.element, supporting: "AXShowMenu") else {
            throw ToolError.failed(
                "\(describeTarget(target)) has no context-menu action. Use perform_secondary_action "
                    + "on an element with actions=ShowMenu."
            )
        }
        let showMenu = ResolvedTarget(
            app: target.app, snapshot: target.snapshot,
            snapshotElement: target.snapshotElement, element: menuTarget
        )
        try performAXAction("AXShowMenu", on: showMenu)
    default:
        throw ToolError.invalidArguments("mouse_button \"\(button)\" is not supported yet.")
    }

    let what = clickCount > 1 ? "Double-clicked" : (button == "right" ? "Opened context menu on" : "Clicked")
    return try await stateResult(
        app: app, windowTitle: target.snapshot.windowTitle,
        note: "\(what) \(describeTarget(target))."
    )
}
