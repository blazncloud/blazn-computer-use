// Shared transport between server processes and the overlay helper.
//
// Each MCP client spawns its own server process, but there should be exactly
// one overlay helper on screen. The helper is a singleton (it holds an
// exclusive flock for its lifetime; later instances exit immediately) and
// reads commands from a named FIFO that every server writes to. Commands are
// single short lines, well under PIPE_BUF, so concurrent writers interleave
// whole commands, never fragments. Each daemon connection gets its own cursor
// (color + optional label) so concurrent agents stay distinguishable.

import Foundation

/// Helper exits after this long without any command, so an orphaned helper
/// (all servers gone) cleans itself up. The cursor has long since faded by
/// then, so the exit is invisible.
let overlayIdleExitDelay: TimeInterval = 900

/// Directory holding the overlay FIFO and singleton lock. Defaults to the
/// shared runtime directory so every server and the one helper rendezvous
/// there. COMPUTER_USE_MCP_OVERLAY_DIR overrides it — a test-isolation hook so
/// a verification helper can run on a private FIFO without contending with a
/// live session's singleton (the overlay is otherwise hard to exercise offline;
/// see docs on overlay verification).
private func overlayDirectory() -> String {
    if let override = ProcessInfo.processInfo.environment["COMPUTER_USE_MCP_OVERLAY_DIR"], !override.isEmpty {
        return override
    }
    return runtimeDirectory().path
}

func overlayFifoPath() -> String {
    (overlayDirectory() as NSString).appendingPathComponent("overlay.cmd")
}

func overlayLockPath() -> String {
    (overlayDirectory() as NSString).appendingPathComponent("overlay.lock")
}

/// Session id used when no daemon connection context is available (no_daemon /
/// local dispatch). Keeps a single default cursor for that path.
let overlayDefaultSessionID = "local"

/// Fixed palette cycled by session id so concurrent agents stay visually distinct.
let overlaySessionPalette: [(red: Double, green: Double, blue: Double)] = [
    (0.20, 0.48, 1.00),  // blue
    (1.00, 0.55, 0.10),  // orange
    (0.20, 0.78, 0.35),  // green
    (0.70, 0.35, 0.95),  // purple
    (0.95, 0.35, 0.55),  // pink
    (0.10, 0.75, 0.75),  // teal
    (0.95, 0.80, 0.15),  // yellow
    (0.95, 0.25, 0.25),  // red
]

/// Stable palette index for a session id (same id → same color across runs).
func overlaySessionColorIndex(for sessionID: String) -> Int {
    let hash = sessionID.utf8.reduce(into: 0) { partial, byte in
        partial = partial &* 31 &+ Int(byte)
    }
    let count = overlaySessionPalette.count
    guard count > 0 else { return 0 }
    return ((hash % count) + count) % count
}

func overlaySessionColorComponents(for sessionID: String) -> (red: Double, green: Double, blue: Double) {
    overlaySessionPalette[overlaySessionColorIndex(for: sessionID)]
}

/// Short label drawn near the cursor (last up-to-3 characters of the session id).
func overlaySessionLabel(for sessionID: String) -> String {
    if sessionID.count <= 3 { return sessionID }
    return String(sessionID.suffix(3))
}

/// Wire commands the overlay helper understands.
enum OverlayCommand: Equatable {
    case ping
    case record(Bool)
    case move(x: Double, y: Double, window: UInt32?, session: String)
    case pulse(x: Double, y: Double, window: UInt32?, session: String)
    case drop(session: String)

    /// Parse one FIFO line. Backward compatible with `move/pulse x y [win]`;
    /// an optional 5th token is the session id.
    static func parse(_ line: String) -> OverlayCommand? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard let head = parts.first else { return nil }
        switch head {
        case "ping":
            return .ping
        case "record":
            guard parts.count == 2 else { return nil }
            return .record(parts[1] == "on")
        case "drop":
            guard parts.count == 2 else { return nil }
            return .drop(session: String(parts[1]))
        case "move", "pulse":
            guard parts.count == 3 || parts.count == 4 || parts.count == 5,
                let x = Double(parts[1]), let y = Double(parts[2])
            else { return nil }
            let window: UInt32?
            if parts.count >= 4, let raw = UInt32(parts[3]), raw != 0 {
                window = raw
            } else {
                window = nil
            }
            let session =
                parts.count == 5 ? String(parts[4]) : overlayDefaultSessionID
            if head == "move" {
                return .move(x: x, y: y, window: window, session: session)
            }
            return .pulse(x: x, y: y, window: window, session: session)
        default:
            return nil
        }
    }
}
