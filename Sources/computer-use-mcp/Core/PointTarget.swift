// Shared resolution for pointer tools (click, scroll): turn the tool args into
// a concrete (AXUIElement, global point, delivery context).

import ApplicationServices
import CoreGraphics
import Foundation
import MCP

struct PointTarget {
    /// The element under the point (hit-tested or resolved from an id), if any.
    let element: AXUIElement?
    /// Global screen point (top-left origin).
    let point: CGPoint
    /// Snapshot the ids/coordinates came from.
    let snapshot: AppSnapshot
    /// Human description for result notes.
    let description: String
    let deliveryContext: DeliveryContext
}

func resolvePointTarget(_ args: [String: Value], app: ResolvedApp) async throws -> PointTarget {
    let allowGlobal = args.bool("allow_global_cursor") ?? false

    // Window + windowNumber for delivery (best-effort; nil disables Tier 2).
    let snapshot = await SnapshotStore.shared.load(forPid: app.pid)
    let window = try? targetWindow(for: app, title: snapshot?.windowTitle)
    let windowNumber = window.flatMap { windowID(for: $0.element) }
    let context = DeliveryContext(
        pid: app.pid, windowNumber: windowNumber,
        windowFrame: window?.frame, allowGlobalCursor: allowGlobal
    )

    if let elementID = args.string("element_id") {
        let target = try await resolveTarget(app: app, elementID: elementID)
        let point = axFrame(target.element).map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? CGPoint(x: 0, y: 0)
        return PointTarget(
            element: target.element, point: point, snapshot: target.snapshot,
            description: describeTarget(target), deliveryContext: context
        )
    }

    if let x = args.number("x"), let y = args.number("y") {
        guard let snapshot else {
            throw ToolError.failed("Call get_app_state for \(app.name) before using coordinates.")
        }
        let point = try screenPoint(x: x, y: y, snapshot: snapshot)
        let element = accessibilityElement(at: point, pid: app.pid)
        return PointTarget(
            element: element, point: point, snapshot: snapshot,
            description: "(\(Int(x)),\(Int(y)))", deliveryContext: context
        )
    }

    throw ToolError.invalidArguments("Provide element_id, or x and y screenshot coordinates.")
}
