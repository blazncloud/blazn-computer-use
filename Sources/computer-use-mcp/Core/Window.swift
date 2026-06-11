// Target-window selection for an app: front window by default, or by title.

import ApplicationServices
import Foundation

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
    var windows = axElements(axApp, kAXWindowsAttribute)
    if windows.isEmpty, let focused = axElement(axApp, kAXFocusedWindowAttribute) {
        windows = [focused]
    }
    guard !windows.isEmpty else {
        throw ToolError.failed(
            "\(app.name) has no windows. If it is launching or its windows are closed, "
                + "open one first (e.g. press_key cmd+n) or pick another app via list_apps."
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
