// `daemon` — the shared engine process.
//
// Exactly one daemon serves all agent sessions of a user (flock singleton,
// like the overlay helper). It owns accessibility, screen capture, input
// delivery, and the agent cursor; serve shims connect over a unix socket and
// forward tool calls. One engine process means sessions cannot collide on
// shared system services, and per-app leases (AppLeases) keep two sessions
// from interleaving actions inside the same app.

import Foundation
import MCP

func runDaemon() async -> Never {
    // Singleton: hold the lock for the daemon's lifetime; the kernel releases
    // it on exit or crash. A concurrently spawned daemon defers to the
    // incumbent.
    let lockFD = open(daemonLockPath(), O_CREAT | O_WRONLY, 0o644)
    if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
        exit(0)
    }

    let listenFD = bindDaemonSocket()
    daemonLog("daemon \(version) listening (pid \(ProcessInfo.processInfo.processIdentifier))")

    // Accept loop on its own thread (accept(2) blocks); each connection gets
    // a reader thread; each request runs as a Task through the shared
    // dispatch funnel.
    let thread = Thread {
        while true {
            let connectionFD = accept(listenFD, nil, nil)
            if connectionFD < 0 { continue }
            DaemonState.shared.connectionOpened()
            Thread.detachNewThread {
                serveConnection(fd: connectionFD)
                Task { await AppLeases.shared.dropLeases(session: connectionFD) }
                DaemonState.shared.connectionClosed()
            }
        }
    }
    thread.start()

    scheduleIdleExit()
    // Park the main task; all work happens on connection threads and Tasks.
    while true {
        try? await Task.sleep(for: .seconds(3600))
    }
}

private func bindDaemonSocket() -> Int32 {
    let path = daemonSocketPath()
    unlink(path)  // stale socket from a dead daemon; the lock arbitrates liveness
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { fatalError("daemon: socket() failed: \(errno)") }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bound = path.withCString { cPath -> Bool in
        withUnsafeMutableBytes(of: &address.sun_path) { sunPath in
            guard strlen(cPath) < sunPath.count else { return false }
            strcpy(sunPath.baseAddress!.assumingMemoryBound(to: CChar.self), cPath)
            return true
        }
    }
    guard bound else { fatalError("daemon: socket path too long: \(path)") }

    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            bind(fd, sockaddrPointer, size)
        }
    }
    guard result == 0, listen(fd, 16) == 0 else {
        fatalError("daemon: bind/listen failed on \(path): \(errno)")
    }
    return fd
}

private func serveConnection(fd: Int32) {
    // Serializes response writes from concurrently completing tool Tasks.
    let writeLock = NSLock()
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)

    while true {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { break }
        buffer.append(contentsOf: chunk[0..<n])
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard let request = try? JSONDecoder().decode(DaemonRequest.self, from: line) else { continue }
            handle(request: request, fd: fd, writeLock: writeLock)
        }
    }
    close(fd)
}

private func handle(request: DaemonRequest, fd: Int32, writeLock: NSLock) {
    func respond(_ response: DaemonResponse) {
        writeLock.lock()
        _ = writeJSONLine(response, to: fd)
        writeLock.unlock()
    }

    switch request.method {
    case "hello":
        respond(DaemonResponse(id: request.id, version: version))
    case "shutdown":
        daemonLog("shutdown requested (version handover)")
        respond(DaemonResponse(id: request.id))
        exit(0)
    default:
        DaemonState.shared.noteActivity()
        Task {
            if let denial = await AppLeases.shared.check(
                tool: request.method, arguments: request.arguments ?? [:], session: fd
            ) {
                respond(DaemonResponse.from(.text(denial, isError: true), id: request.id))
                return
            }
            let result = await dispatchTool(name: request.method, arguments: request.arguments ?? [:])
            respond(DaemonResponse.from(result, id: request.id))
            DaemonState.shared.noteActivity()
        }
    }
}

/// Connection count + last activity, for the idle self-exit. Class with a
/// lock (not an actor): it is touched from raw connection threads.
private final class DaemonState: @unchecked Sendable {
    static let shared = DaemonState()
    private let lock = NSLock()
    private var connections = 0
    private var lastActivity = Date()

    func connectionOpened() {
        lock.lock()
        connections += 1
        lastActivity = Date()
        lock.unlock()
    }

    func connectionClosed() {
        lock.lock()
        connections -= 1
        lastActivity = Date()
        lock.unlock()
    }

    func noteActivity() {
        lock.lock()
        lastActivity = Date()
        lock.unlock()
    }

    var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connections <= 0 && Date().timeIntervalSince(lastActivity) > 1800
    }
}

/// With no connected sessions for 30 minutes the daemon reaps itself; the
/// next session spawns a fresh one (which also picks up binary updates).
private func scheduleIdleExit() {
    Thread.detachNewThread {
        while true {
            Thread.sleep(forTimeInterval: 60)
            if DaemonState.shared.isIdle {
                daemonLog("idle exit")
                exit(0)
            }
        }
    }
}

func daemonLog(_ message: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    if let handle = FileHandle(forWritingAtPath: daemonLogPath()) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: URL(fileURLWithPath: daemonLogPath()))
    }
}
