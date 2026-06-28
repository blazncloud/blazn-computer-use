// Client side of the daemon protocol: connect to the shared engine daemon,
// spawning one if none is alive, with a version handshake so a stale daemon
// (older binary still running) is asked to step down and replaced.

import Foundation
import MCP

actor DaemonClient {
    static let shared = DaemonClient()

    private var fd: Int32 = -1
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<DaemonResponse, any Error>] = [:]
    /// Keeps a spawned daemon Process alive so Foundation reaps it on exit.
    private var spawnedDaemon: Process?

    func call(tool: String, arguments: [String: Value]) async throws -> CallTool.Result {
        try await ensureConnected()
        let response = try await send(DaemonRequest(id: allocateID(), method: tool, arguments: arguments))
        return response.asCallToolResult
    }

    // MARK: connection

    private func ensureConnected() async throws {
        if fd >= 0 { return }

        // Connect; if nothing is listening, spawn a daemon and retry. The
        // spawn race is safe: losers exit on the daemon's flock.
        var didSpawn = false
        let deadline = Date().addingTimeInterval(5)
        while true {
            if let connected = Self.connect() {
                adopt(fd: connected)
                do {
                    if try await handshake() { return }
                } catch {
                    disconnect(error: error)
                    throw error
                }
                // Version mismatch: the old daemon was asked to shut down;
                // loop to spawn/connect a current one.
                disconnect(error: ToolError.failed("daemon version handover"))
            }
            guard Date() < deadline else {
                throw ToolError.failed("Engine daemon did not come up within 5s.")
            }
            if !didSpawn {
                didSpawn = true
                spawnDaemon()
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Returns true when the daemon speaks our version; otherwise tells it to
    /// shut down (so a fresh one can take over) and returns false.
    private func handshake() async throws -> Bool {
        let token = try daemonAuthToken()
        let reply = try await send(DaemonRequest(id: allocateID(), method: "hello", version: version, authToken: token))
        if reply.isError == true {
            let message = reply.content?.compactMap(\.text).joined(separator: "\n")
                ?? "daemon authentication failed"
            throw ToolError.failed(message)
        }
        if reply.version == version, reply.authenticated == true { return true }
        guard reply.version != nil else {
            throw ToolError.failed("daemon handshake did not return a version")
        }
        _ = try? await send(DaemonRequest(id: allocateID(), method: "shutdown", authToken: token))
        try? await Task.sleep(for: .milliseconds(200))
        return false
    }

    private static func connect() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = daemonSocketPath()
        let fits = path.withCString { cPath -> Bool in
            withUnsafeMutableBytes(of: &address.sun_path) { sunPath in
                guard strlen(cPath) < sunPath.count else { return false }
                strcpy(sunPath.baseAddress!.assumingMemoryBound(to: CChar.self), cPath)
                return true
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = fits
            ? withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.connect(fd, sockaddrPointer, size)
                }
            } : -1
        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    private func adopt(fd connected: Int32) {
        fd = connected
        // Reader thread: blocking reads must not occupy the cooperative pool.
        Thread.detachNewThread { [weak self] in
            var frames = DaemonLineBuffer<DaemonResponse>(
                maxFrameBytes: DaemonProtocolLimits.maxResponseFrameBytes
            )
            var chunk = [UInt8](repeating: 0, count: DaemonProtocolLimits.readChunkBytes)
            readLoop: while true {
                let n = read(connected, &chunk, chunk.count)
                if n <= 0 { break }

                do {
                    for frame in try frames.append(contentsOf: chunk[0..<n]) {
                        guard case .message(let response) = frame else {
                            break readLoop
                        }
                        Task { await self?.fulfill(response) }
                    }
                } catch {
                    break
                }
            }
            Task { await self?.connectionDropped(fd: connected) }
        }
    }

    private func spawnDaemon() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        task.arguments = ["daemon"]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        // The daemon outlives this session; it must not hold our stderr open
        // (hosts can wait on that fd). It logs to its own file instead.
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            spawnedDaemon = task
        } catch {
            // ensureConnected's deadline turns this into a thrown error.
        }
    }

    // MARK: request/response plumbing

    private func allocateID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    private func send(_ request: DaemonRequest) async throws -> DaemonResponse {
        guard fd >= 0 else { throw ToolError.failed("Not connected to the engine daemon.") }
        return try await withCheckedThrowingContinuation { continuation in
            pending[request.id] = continuation
            if !writeJSONLine(request, to: fd) {
                pending[request.id] = nil
                disconnect(error: ToolError.failed("Lost the engine daemon connection."))
                continuation.resume(throwing: ToolError.failed("Lost the engine daemon connection."))
            }
        }
    }

    private func fulfill(_ response: DaemonResponse) {
        pending.removeValue(forKey: response.id)?.resume(returning: response)
    }

    private func connectionDropped(fd dropped: Int32) {
        guard dropped == fd else { return }  // a stale reader from a replaced connection
        disconnect(error: ToolError.failed("The engine daemon connection closed."))
    }

    private func disconnect(error: any Error) {
        if fd >= 0 { close(fd) }
        fd = -1
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
        pending.removeAll()
    }
}
