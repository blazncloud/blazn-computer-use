// press_key, scroll, drag — the synthetic-input tools.

import ApplicationServices
import CoreGraphics
import Foundation
import MCP

func pressKeyImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    let confirmed = SafetyPolicy.confirmed(args)
    try SafetyPolicy.check(app: app, confirmed: confirmed)
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
        allowGlobalCursor: args.bool("allow_global_cursor") ?? false
    )
    try deliverKey(chord, context: context)
    try? await Task.sleep(for: .milliseconds(80))

    return try await stateResult(
        app: app, windowTitle: window?.title, note: "Pressed \(combo)."
    )
}

func scrollImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    try SafetyPolicy.check(app: app, confirmed: SafetyPolicy.confirmed(args))
    let target = try await resolvePointTarget(args, app: app)
    let deltaX = args.integer("delta_x") ?? 0
    let deltaY = args.integer("delta_y") ?? 0
    guard deltaX != 0 || deltaY != 0 else {
        throw ToolError.invalidArguments("Provide a non-zero delta_x or delta_y.")
    }

    let point = try target.requirePoint()
    await AgentCursor.shared.glide(to: point)
    deliverScroll(at: point, deltaX: deltaX, deltaY: deltaY, context: target.deliveryContext)
    try? await Task.sleep(for: .milliseconds(80))

    return try await stateResult(
        app: app, windowTitle: target.snapshot.windowTitle,
        note: "Scrolled (\(deltaX),\(deltaY)) at \(target.description)."
    )
}

func dragImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    try SafetyPolicy.check(app: app, confirmed: SafetyPolicy.confirmed(args))
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
        allowGlobalCursor: args.bool("allow_global_cursor") ?? false
    )
    await AgentCursor.shared.glide(to: from)
    await deliverDrag(from: from, to: to, context: context)
    try? await Task.sleep(for: .milliseconds(80))

    return try await stateResult(
        app: app, windowTitle: snapshot.windowTitle,
        note: "Dragged from (\(Int(from.x.rounded())),\(Int(from.y.rounded()))) "
            + "to (\(Int(to.x.rounded())),\(Int(to.y.rounded())))."
    )
}
