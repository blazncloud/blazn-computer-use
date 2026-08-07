// Target-window selection for an app: front window by default, or by title.

import ApplicationServices
import CoreGraphics
import Foundation

/// A launch-specific process token from libproc. It distinguishes a live app
/// from a later process that reuses the same pid. Nil is a first-class result:
/// process inspection can race with exit or be unavailable in restricted
/// environments.
func processStartTimeMicroseconds(pid: pid_t) -> UInt64? {
    var info = proc_bsdinfo()
    let bytes = proc_pidinfo(
        pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
    guard bytes == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
    return UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
}

func snapshotProcessIdentity(pid: pid_t, bundleIdentifier: String) -> SnapshotProcessIdentity {
    SnapshotProcessIdentity(
        pid: pid, bundleIdentifier: bundleIdentifier,
        startTimeMicroseconds: processStartTimeMicroseconds(pid: pid))
}

/// Best-effort AX window match for snapshot lineage. Ambiguous title/frame
/// matches deliberately produce nil rather than blessing an arbitrary window.
func snapshotWindowID(pid: pid_t, title: String?, frame: CGRect?) -> CGWindowID? {
    let app = AXUIElementCreateApplication(pid)
    let windows = axElements(app, kAXWindowsAttribute).filter { axRole($0) == "AXWindow" }
    let titleMatches = title.map { expected in
        windows.filter { axString($0, kAXTitleAttribute) == expected }
    } ?? windows
    let candidates = titleMatches.isEmpty ? windows : titleMatches
    guard !candidates.isEmpty else { return nil }

    let matched: AXUIElement
    if let frame {
        let ranked = candidates.compactMap { window -> (AXUIElement, CGFloat)? in
            guard let candidateFrame = axFrame(window) else { return nil }
            let distance =
                abs(candidateFrame.midX - frame.midX) + abs(candidateFrame.midY - frame.midY)
                + abs(candidateFrame.width - frame.width) + abs(candidateFrame.height - frame.height)
            return (window, distance)
        }.sorted { $0.1 < $1.1 }
        guard let first = ranked.first else { return nil }
        guard first.1 <= 2 else { return nil }
        if ranked.count > 1, abs(ranked[1].1 - first.1) < 0.5 { return nil }
        matched = first.0
    } else {
        guard candidates.count == 1 else { return nil }
        matched = candidates[0]
    }
    return windowID(for: matched)
}

func snapshotLineage(
    pid: pid_t, bundleIdentifier: String, windowID: CGWindowID?
) -> SnapshotLineage {
    SnapshotLineage(
        process: snapshotProcessIdentity(pid: pid, bundleIdentifier: bundleIdentifier),
        windowID: windowID)
}

/// Backing scale of the display containing a global top-left point — the
/// fallback pixels-per-point when a window cannot be captured and no prior
/// snapshot exists (defaulting to 1 on a Retina display would skew element
/// boxes ~2x against a later real capture). CoreGraphics, not NSScreen:
/// NSScreen.screens needs a serviced run loop to refresh and goes stale in
/// the daemon after display changes; CG queries the window server directly,
/// in the same global top-left coordinates as window frames.
func displayScale(atGlobalTopLeft point: CGPoint) -> Double {
    var displayCount: UInt32 = 0
    var displays = [CGDirectDisplayID](repeating: 0, count: 16)
    guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &displayCount) == .success,
        displayCount > 0
    else { return 1 }
    let active = displays.prefix(Int(displayCount))
    let display = active.first { CGDisplayBounds($0).contains(point) } ?? active[0]
    let bounds = CGDisplayBounds(display)
    guard bounds.width > 0, let mode = CGDisplayCopyDisplayMode(display) else { return 1 }
    return Double(mode.pixelWidth) / bounds.width
}

/// @unchecked: AXUIElement is an immutable thread-safe CF handle.
struct TargetWindow: @unchecked Sendable {
    let element: AXUIElement
    let title: String?
    /// Global screen frame in points (top-left origin).
    let frame: CGRect
    /// Captured once when this window is resolved, before any mutation can
    /// close or replace it.
    let identityWindowID: CGWindowID?

    init(
        element: AXUIElement, title: String?, frame: CGRect,
        identityWindowID: CGWindowID? = nil
    ) {
        self.element = element
        self.title = title
        self.frame = frame
        self.identityWindowID = identityWindowID ?? windowID(for: element)
    }

    var lineageWindowID: CGWindowID? {
        identityWindowID
    }
}

struct WindowIdentityCandidate: Equatable {
    let windowID: CGWindowID?
    let title: String?
}

/// Pure exact-ID selection used by strict mutation targeting. Titles are
/// intentionally ignored: duplicate-title windows must never redirect an
/// action when the captured window id is known.
func exactWindowIdentityIndex(
    snapshotWindowID: CGWindowID, candidates: [WindowIdentityCandidate]
) -> Int? {
    candidates.firstIndex { $0.windowID == snapshotWindowID }
}

func requireExactWindowIdentityIndex(
    snapshotWindowID: CGWindowID, candidates: [WindowIdentityCandidate],
    appName: String
) throws -> Int {
    guard let index = exactWindowIdentityIndex(
        snapshotWindowID: snapshotWindowID, candidates: candidates)
    else {
        throw ToolError.failed(
            "The captured window (id \(snapshotWindowID)) no longer exists for \(appName). "
                + "Call get_app_state and use an id from the current window.")
    }
    return index
}

/// Resolve the exact AX window captured in the snapshot. A missing id is stale,
/// not an invitation to fall back to another same-title window.
func targetWindow(for app: ResolvedApp, snapshotWindowID: CGWindowID) throws -> TargetWindow {
    try requireAppAlive(app)
    let windows = axElements(app.axApplication, kAXWindowsAttribute)
        .filter { axRole($0) == "AXWindow" }
    let candidates = windows.map {
        WindowIdentityCandidate(
            windowID: windowID(for: $0),
            title: axString($0, kAXTitleAttribute))
    }
    let index = try requireExactWindowIdentityIndex(
        snapshotWindowID: snapshotWindowID, candidates: candidates,
        appName: app.name)
    let chosen = windows[index]
    guard let frame = axFrame(chosen) else {
        throw ToolError.failed("Could not read the window frame for \(app.name).")
    }
    return TargetWindow(
        element: chosen, title: axString(chosen, kAXTitleAttribute), frame: frame,
        identityWindowID: snapshotWindowID)
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
