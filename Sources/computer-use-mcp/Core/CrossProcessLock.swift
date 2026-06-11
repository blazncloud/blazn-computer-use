// Best-effort cross-process mutex via flock(2).
//
// Each MCP client spawns its own server process, so contention on shared
// system services (notably replayd, which serves every ScreenCaptureKit
// capture and has been observed to wedge under concurrent requests) must be
// serialized across processes, not just within one. flock is released by the
// kernel when the holding process exits, so a crashed server never strands
// the lock.

import Foundation

/// Run `operation` while holding an exclusive named lock shared by all
/// computer-use-mcp processes of this user. If the lock cannot be acquired
/// within `acquireTimeout`, the operation proceeds unlocked — the lock is a
/// contention reducer, not a correctness requirement, and a stuck peer must
/// not turn into a stuck caller.
func withCrossProcessLock<T>(
    named name: String, acquireTimeout: Double = 10,
    operation: () async throws -> T
) async rethrows -> T {
    let fd = await acquireLockFile(name: name, timeout: acquireTimeout)
    defer {
        if fd >= 0 {
            flock(fd, LOCK_UN)
            close(fd)
        }
    }
    return try await operation()
}

private func acquireLockFile(name: String, timeout: Double) async -> Int32 {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
    let directory = base.appendingPathComponent("computer-use-mcp", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("\(name).lock").path

    let fd = open(path, O_CREAT | O_WRONLY, 0o644)
    guard fd >= 0 else { return -1 }

    let deadline = Date().addingTimeInterval(timeout)
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
        if Date() >= deadline {
            close(fd)
            return -1
        }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return fd
}
