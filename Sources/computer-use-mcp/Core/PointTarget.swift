// Shared resolution for pointer tools (click, scroll): turn the tool args into
// a concrete (AXUIElement, global point, delivery context).

import ApplicationServices
import CoreGraphics
import Foundation
import MCP

struct PointTarget {
    /// The element under the point (hit-tested or resolved from an id), if any.
    let element: AXUIElement?
    /// The captured node when the target came from an element id, so the
    /// outcome verifier can revalidate and re-read its handle after the action.
    /// nil for coordinate clicks.
    let snapshotElement: CapturedNode?
    /// Global screen point (top-left origin). Nil when the element exposes no
    /// frame — such targets can only be driven by accessibility actions, and
    /// point-based delivery must fail loudly rather than act at (0,0).
    let point: CGPoint?
    /// Snapshot the ids/coordinates came from.
    let snapshot: AppSnapshot
    /// Exact retained and revalidated window that owns this mutation.
    let windowElement: AXUIElement
    /// Human description for result notes.
    let description: String
    let deliveryContext: DeliveryContext

    /// The point, or a clear error for tools that cannot act without one.
    func requirePoint() throws -> CGPoint {
        guard let point else {
            throw ToolError.failed(
                "\(description) has no screen position (the element exposes no frame), "
                    + "so this action cannot be delivered. Call get_app_state and target "
                    + "a different element or use screenshot coordinates."
            )
        }
        return point
    }
}

enum CoordinateFreshnessDecision: Equatable {
    case fresh
    case stale(String)
}

/// Screenshot coordinates are valid only for the exact geometry they were
/// captured from. AX handles use current live geometry and do not need this
/// check; coordinate and drag tools do.
func coordinateFreshnessDecision(
    snapshotOrigin: [Double], snapshotSize: [Double]?, pixelsPerPoint: Double,
    capturedDisplayScale: Double?, currentFrame: CGRect, currentDisplayScale: Double,
    tolerance: Double = 0.5
) -> CoordinateFreshnessDecision {
    guard snapshotOrigin.count >= 2, let snapshotSize, snapshotSize.count >= 2,
        pixelsPerPoint.isFinite, pixelsPerPoint > 0
    else { return .stale("captured window geometry is incomplete") }
    let capturedFrame = CGRect(
        x: snapshotOrigin[0], y: snapshotOrigin[1],
        width: snapshotSize[0] / pixelsPerPoint,
        height: snapshotSize[1] / pixelsPerPoint)
    let differences = [
        abs(capturedFrame.minX - currentFrame.minX),
        abs(capturedFrame.minY - currentFrame.minY),
        abs(capturedFrame.width - currentFrame.width),
        abs(capturedFrame.height - currentFrame.height),
    ]
    if differences.contains(where: { !$0.isFinite || $0 > tolerance }) {
        return .stale("the window moved or resized after the screenshot")
    }
    if let capturedDisplayScale,
        abs(capturedDisplayScale - currentDisplayScale) > 0.01
    {
        return .stale("the window's display scale changed after the screenshot")
    }
    return .fresh
}

func requireFreshCoordinateGeometry(snapshot: AppSnapshot, window: TargetWindow) throws {
    let currentScale = displayScale(
        atGlobalTopLeft: CGPoint(x: window.frame.midX, y: window.frame.midY))
    switch coordinateFreshnessDecision(
        snapshotOrigin: snapshot.screenshotWindowOrigin ?? [],
        snapshotSize: snapshot.screenshotWindowSize,
        pixelsPerPoint: snapshot.pixelsPerPoint,
        capturedDisplayScale: snapshot.displayScale,
        currentFrame: window.frame, currentDisplayScale: currentScale)
    {
    case .fresh:
        return
    case .stale(let reason):
        throw ToolError.failed(
            "Screenshot coordinates are stale because \(reason). Call get_app_state with a screenshot and retry.")
    }
}

func resolvePointTarget(_ args: [String: Value], app: ResolvedApp, allowGlobalCursor: Bool = false) async throws -> PointTarget {
    let syntheticPreference = try diagnosticSyntheticDeliveryPreference(args)
    if allowGlobalCursor, syntheticPreference == .perPidOnly {
        throw ToolError.invalidArguments(
            "_diagnostic_delivery_tier cannot be combined with allow_global_cursor."
        )
    }
    if let elementID = args.string("element_id") {
        let target = try await resolveMutationTarget(app: app, elementID: elementID)
        let context = pointDeliveryContext(
            pid: app.pid, windowNumber: target.snapshot.lineage?.windowID,
            windowFrame: target.window.frame, allowGlobalCursor: allowGlobalCursor,
            syntheticPreference: syntheticPreference)
        let point = axFrame(target.element).map { CGPoint(x: $0.midX, y: $0.midY) }
        return PointTarget(
            element: target.element, snapshotElement: target.snapshotElement, point: point,
            snapshot: target.snapshot, windowElement: target.window.element,
            description: describeTarget(target), deliveryContext: context
        )
    }

    if let x = args.number("x"), let y = args.number("y") {
        guard let snapshot = await SnapshotStore.shared.load(forPid: app.pid) else {
            throw ToolError.failed("Call get_app_state for \(app.name) before using coordinates.")
        }
        let window = try resolveMutationWindow(snapshot: snapshot, app: app)
        try requireFreshCoordinateGeometry(snapshot: snapshot, window: window)
        let context = pointDeliveryContext(
            pid: app.pid, windowNumber: snapshot.lineage?.windowID,
            windowFrame: window.frame, allowGlobalCursor: allowGlobalCursor,
            syntheticPreference: syntheticPreference)
        let point = try screenPoint(x: x, y: y, snapshot: snapshot)
        let element = accessibilityElement(at: point, pid: app.pid)
        return PointTarget(
            element: element, snapshotElement: nil, point: point, snapshot: snapshot,
            windowElement: window.element,
            description: "(\(Int(x)),\(Int(y)))", deliveryContext: context
        )
    }

    throw ToolError.invalidArguments("Provide element_id, or x and y screenshot coordinates.")
}

/// Hidden from the MCP catalog: this exists only for local CLI diagnosis of a
/// single delivery rung and therefore cannot be selected by an MCP model.
func diagnosticSyntheticDeliveryPreference(
    _ args: [String: Value]
) throws -> SyntheticDeliveryPreference {
    guard args["_diagnostic_delivery_tier"] != nil else { return .automatic }
    guard let raw = args.string("_diagnostic_delivery_tier"), raw == "tier3" else {
        throw ToolError.invalidArguments(
            "_diagnostic_delivery_tier only supports \"tier3\"."
        )
    }
    return .perPidOnly
}

/// Pure delivery-context constructor used to prove exact window affinity
/// independently of live AX resolution.
func pointDeliveryContext(
    pid: pid_t, windowNumber: CGWindowID?, windowFrame: CGRect?,
    allowGlobalCursor: Bool,
    syntheticPreference: SyntheticDeliveryPreference = .automatic
) -> DeliveryContext {
    DeliveryContext(
        pid: pid, windowNumber: windowNumber,
        windowFrame: windowFrame, allowGlobalCursor: allowGlobalCursor,
        syntheticPreference: syntheticPreference)
}
