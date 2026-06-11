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

private func overlayRuntimeDirectory() -> URL {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
    let directory = base.appendingPathComponent("computer-use-mcp", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

func overlayFifoPath() -> String {
    overlayRuntimeDirectory().appendingPathComponent("overlay.cmd").path
}

func overlayLockPath() -> String {
    overlayRuntimeDirectory().appendingPathComponent("overlay.lock").path
}
