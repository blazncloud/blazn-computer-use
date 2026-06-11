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

func overlayFifoPath() -> String {
    runtimeDirectory().appendingPathComponent("overlay.cmd").path
}

func overlayLockPath() -> String {
    runtimeDirectory().appendingPathComponent("overlay.lock").path
}
