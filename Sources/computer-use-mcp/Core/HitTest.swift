// Coordinate → element hit-testing, the fallback when a target is not (or is
// wrongly) represented in the accessibility tree.

import ApplicationServices
import Foundation

/// The accessibility element at a global screen point, restricted to the
/// target app. Returns nil when nothing (or another app's window) is there.
func accessibilityElement(at point: CGPoint, pid: pid_t) -> AXUIElement? {
    var raw: AXUIElement?
    let error = AXUIElementCopyElementAtPosition(
        AXUIElementCreateApplication(pid), Float(point.x), Float(point.y), &raw
    )
    guard error == .success, let element = raw else { return nil }
    return element
}

/// Walk up from an element to the nearest ancestor (or itself) supporting
/// the given action — a coordinate often lands on a label inside a button.
func selfOrAncestor(of element: AXUIElement, supporting action: String, maxHops: Int = 5) -> AXUIElement? {
    var current = element
    for _ in 0...maxHops {
        if axActionNames(current).contains(action) {
            return current
        }
        guard let parent = axElement(current, kAXParentAttribute) else { return nil }
        current = parent
    }
    return nil
}

/// Convert screenshot-pixel coordinates from the latest snapshot into a
/// global screen point, validating bounds.
func screenPoint(x: Double, y: Double, snapshot: AppSnapshot) throws -> CGPoint {
    guard let window = snapshot.elements.first else {
        throw ToolError.failed("The latest snapshot has no window element. Call get_app_state again.")
    }
    let frame = window.frame
    // Pixel coordinates are zero-indexed: width/height themselves are outside.
    guard x >= 0, y >= 0, x < frame[2], y < frame[3] else {
        throw ToolError.invalidArguments(
            "Coordinate (\(Int(x)), \(Int(y))) is outside the \(Int(frame[2]))x\(Int(frame[3])) "
                + "screenshot. Coordinates are pixels in the latest get_app_state screenshot."
        )
    }
    return snapshot.screenPoint(fromScreenshotX: x, y: y)
}
