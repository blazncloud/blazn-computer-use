// Shared transport between server processes and the overlay helper.
//
// Each MCP client spawns its own server process, but there should be exactly
// one agent cursor on screen. The helper is a singleton (it holds an
// exclusive flock for its lifetime; later instances exit immediately) and
// reads commands from a named FIFO that every server writes to. Commands are
// single short lines, well under PIPE_BUF, so concurrent writers interleave
// whole commands, never fragments.

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
