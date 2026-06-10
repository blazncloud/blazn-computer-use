// press_key, scroll, drag — the synthetic-input tools.

import ApplicationServices
import CoreGraphics
import Foundation
import MCP

func pressKeyImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    let combo = try args.requireString("key")
    let chord = try Keymap.parse(combo)

    let window = try? targetWindow(for: app, title: SnapshotStore.load(forPid: app.pid)?.windowTitle)
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
    let target = try resolvePointTarget(args, app: app)
    let deltaX = args.integer("delta_x") ?? 0
    let deltaY = args.integer("delta_y") ?? 0
    guard deltaX != 0 || deltaY != 0 else {
        throw ToolError.invalidArguments("Provide a non-zero delta_x or delta_y.")
    }

    deliverScroll(at: target.point, deltaX: deltaX, deltaY: deltaY, context: target.deliveryContext)
    try? await Task.sleep(for: .milliseconds(80))

    return try await stateResult(
        app: app, windowTitle: target.snapshot.windowTitle,
        note: "Scrolled (\(deltaX),\(deltaY)) at \(target.description)."
    )
}

func dragImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    guard let snapshot = SnapshotStore.load(forPid: app.pid) else {
        throw ToolError.failed("Call get_app_state for \(app.name) before dragging.")
    }
    let from = try screenPoint(x: try args.requireNumber("from_x"), y: try args.requireNumber("from_y"), snapshot: snapshot)
    let to = try screenPoint(x: try args.requireNumber("to_x"), y: try args.requireNumber("to_y"), snapshot: snapshot)

    let window = try? targetWindow(for: app, title: snapshot.windowTitle)
    let context = DeliveryContext(
        pid: app.pid,
        windowNumber: window.flatMap { windowID(for: $0.element) },
        windowFrame: window?.frame,
        allowGlobalCursor: args.bool("allow_global_cursor") ?? false
    )
    await deliverDrag(from: from, to: to, context: context)
    try? await Task.sleep(for: .milliseconds(80))

    return try await stateResult(
        app: app, windowTitle: snapshot.windowTitle,
        note: "Dragged from (\(args.integer("from_x") ?? 0),\(args.integer("from_y") ?? 0)) "
            + "to (\(args.integer("to_x") ?? 0),\(args.integer("to_y") ?? 0))."
    )
}
