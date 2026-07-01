// Target-window selection for an app: front window by default, or by title.

import AppKit
import ApplicationServices
import Foundation

/// Backing scale of the display containing a global top-left point — the
/// fallback pixels-per-point when a window cannot be captured and no prior
/// snapshot exists (defaulting to 1 on a Retina display would skew element
/// boxes ~2x against a later real capture).
func displayScale(atGlobalTopLeft point: CGPoint) -> Double {
    let primaryHeight =
        (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first)?.frame.height ?? 0
    let appKitPoint = CGPoint(x: point.x, y: primaryHeight - point.y)
    let screen = NSScreen.screens.first { $0.frame.contains(appKitPoint) } ?? NSScreen.screens.first
    return screen.map { Double($0.backingScaleFactor) } ?? 1
}

/// @unchecked: AXUIElement is an immutable thread-safe CF handle.
struct TargetWindow: @unchecked Sendable {
    let element: AXUIElement
    let title: String?
    /// Global screen frame in points (top-left origin).
    let frame: CGRect
}

func targetWindow(for app: ResolvedApp, title requestedTitle: String?) throws -> TargetWindow {
    try requireAppAlive(app)
    let axApp = app.axApplication
    // Some apps (observed with windows on inactive Spaces) return degenerate
    // entries — even the application element itself — in AXWindows; keep only
    // real windows so the failure reads "no windows", not a frame error.
    var windows = axElements(axApp, kAXWindowsAttribute).filter { axRole($0) == "AXWindow" }
    if windows.isEmpty, let focused = axElement(axApp, kAXFocusedWindowAttribute),
        axRole(focused) == "AXWindow"
    {
        windows = [focused]
    }
    guard !windows.isEmpty else {
        throw ToolError.failed(
            "\(app.name) has no windows in the current Space. If it is launching or its "
                + "windows are closed, open one first (e.g. press_key cmd+n); if its window "
                + "is on another Space, switch to it or move the window. See list_apps for "
                + "alternatives."
        )
    }

    func describe(_ window: AXUIElement) -> String? {
        axString(window, kAXTitleAttribute)
    }

    let chosen: AXUIElement
    if let requestedTitle {
        let query = requestedTitle.lowercased()
        guard
            let match = windows.first(where: { describe($0)?.lowercased() == query })
                ?? windows.first(where: { describe($0)?.lowercased().contains(query) ?? false })
        else {
            let titles = windows.compactMap(describe).joined(separator: "\", \"")
            throw ToolError.failed(
                "No \(app.name) window titled \"\(requestedTitle)\". Open windows: \"\(titles)\"."
            )
        }
        chosen = match
    } else {
        chosen = axElement(axApp, kAXFocusedWindowAttribute)
            ?? axElement(axApp, kAXMainWindowAttribute)
            ?? windows[0]
    }

    guard let frame = axFrame(chosen) else {
        throw ToolError.failed("Could not read the window frame for \(app.name).")
    }
    return TargetWindow(element: chosen, title: describe(chosen), frame: frame)
}
