// Client side of the daemon protocol: connect to the shared engine daemon,
// spawning one if none is alive, with a version handshake so a stale daemon
// (older binary still running) is asked to step down and replaced. A newer
// daemon is never killed by an older CLI — the client defers or asks the user
// to upgrade.

import Foundation
import MCP

actor DaemonClient {
    static let shared = DaemonClient()

    private var fd: Int32 = -1
    private var nextID = 1
    private var pending = DaemonPendingRegistry<CheckedContinuation<DaemonResponse, any Error>>()
    private var pendingTimeouts: [Int: Task<Void, Never>] = [:]
    private var resumeToken: String?
    private var daemonIncarnationID: String?
    private var operationDeduplicationSupported = false
    private var connectionGeneration = 0
    /// Keeps a spawned daemon Process alive so Foundation reaps it on exit.
    private var spawnedDaemon: Process?

    func call(tool: String, arguments: [String: Value]) async throws -> CallTool.Result {
        let operationID = UUID().uuidString
        try await ensureConnected()
        let originalIncarnationID = daemonIncarnationID
        let originalConnectionGeneration = connectionGeneration
        let deduplicationWasNegotiated = operationDeduplicationSupported
        let mutation = isMutatingTool(tool)
        do {
            return try await sendOperation(
                tool: tool, arguments: arguments, operationID: operationID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard daemonRetryPermitted(
                isMutating: mutation,
                deduplicationSupported: deduplicationWasNegotiated,
                daemonIncarnationID: originalIncarnationID)
            else { throw error }
        }

        // One bounded retry. Read-only calls remain safe against legacy
        // daemons; mutations require a negotiated dedupe capability.
        try await ensureConnected()
        if mutation, connectionGeneration != originalConnectionGeneration,
            !daemonRetryAllowed(
                originalIncarnationID: originalIncarnationID,
                currentIncarnationID: daemonIncarnationID,
                connectionChanged: true)
        {
            throw ToolError.failed(
                "Daemon restarted after an ambiguous mutation result; refusing to replay the operation.")
        }
        return try await sendOperation(
            tool: tool, arguments: arguments, operationID: operationID)
    }

    private func sendOperation(
        tool: String, arguments: [String: Value], operationID: String
    ) async throws -> CallTool.Result {
        let response = try await send(
            DaemonRequest(
                id: allocateID(), method: tool, arguments: arguments,
                operationID: operationID),
            operationIDForCallerCancellation: operationID)
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
                // Local build is newer: the old daemon was asked to shut down;
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

    /// Returns true when the daemon speaks our version. When the local build is
    /// strictly newer, asks the daemon to shut down and returns false. When the
    /// daemon is newer or equal but incompatible, throws an upgrade error
    /// without sending shutdown.
    private func handshake() async throws -> Bool {
        let token = try daemonAuthToken()
        let reply = try await send(
            DaemonRequest(
                id: allocateID(), method: "hello", version: version, authToken: token,
                buildStamp: executableBuildStamp, resumeToken: resumeToken
            ))
        if reply.isError == true {
            let message = reply.content?.compactMap(\.text).joined(separator: "\n")
                ?? "daemon authentication failed"
            throw ToolError.failed(message)
        }
        if daemonHandshakeAccepts(
            replyVersion: reply.version, replyAuthenticated: reply.authenticated,
            replyBuildStamp: reply.buildStamp,
            localVersion: version, localBuildStamp: executableBuildStamp
        ) {
            resumeToken = reply.resumeToken ?? resumeToken
            daemonIncarnationID = reply.daemonIncarnationID
            operationDeduplicationSupported =
                reply.operationDeduplicationSupported == true
                && reply.daemonIncarnationID != nil
            return true
        }
        guard let replyVersion = reply.version else {
            throw ToolError.failed("daemon handshake did not return a version")
        }
        if daemonClientShouldRequestShutdown(
            replyVersion: reply.version, replyBuildStamp: reply.buildStamp,
            localVersion: version, localBuildStamp: executableBuildStamp
        ) {
            _ = try? await send(
                DaemonRequest(
                    id: allocateID(), method: "shutdown", authToken: token,
                    buildStamp: executableBuildStamp
                ))
            try? await Task.sleep(for: .milliseconds(200))
            return false
        }
        throw ToolError.failed(
            daemonUpgradeRequiredMessage(daemonVersion: replyVersion, localVersion: version)
        )
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
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, size)
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
        connectionGeneration += 1
        // Reader thread: blocking reads must not occupy the cooperative pool.
        Thread.detachNewThread { [weak self] in
            var frames = DaemonLineBuffer<DaemonResponse>(
                maxFrameBytes: DaemonProtocolLimits.maxResponseFrameBytes
            )
            var chunk = [UInt8](repeating: 0, count: DaemonProtocolLimits.readChunkBytes)
            var malformedBudget = DaemonMalformedFrameBudget()
            readLoop: while true {
                let n = read(connected, &chunk, chunk.count)
                if n <= 0 { break }

                do {
                    for frame in try frames.append(contentsOf: chunk[0..<n]) {
                        switch frame {
                        case .message(let response):
                            // Bind a strong actor reference before the Task:
                            // Swift 6.1 rejects the optional-chained closure
                            // (`await self?.…` infers a non-Sendable `() -> ()?`).
                            if let client = self {
                                Task { await client.fulfill(response) }
                            }
                        case .malformed:
                            // Skip bad lines; only disconnect after the budget
                            // is exhausted. Unrelated pending RPCs stay alive.
                            if malformedBudget.record() {
                                break readLoop
                            }
                        }
                    }
                } catch {
                    break
                }
            }
            if let client = self {
                Task { await client.connectionDropped(fd: connected) }
            }
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

    private func send(
        _ request: DaemonRequest, operationIDForCallerCancellation: String? = nil
    ) async throws -> DaemonResponse {
        guard fd >= 0 else { throw ToolError.failed("Not connected to the engine daemon.") }
        let timeoutSeconds = daemonRPCTimeoutSeconds()
        let requestID = request.id
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.store(id: requestID, handler: continuation)
                let timeoutTask = Task { [timeoutSeconds] in
                    do {
                        try await Task.sleep(for: .seconds(timeoutSeconds))
                    } catch {
                        return
                    }
                    self.failPending(
                        id: requestID,
                        error: ToolError.failed(
                            "Daemon RPC timed out after \(Int(timeoutSeconds))s waiting for \"\(request.method)\"."
                        )
                    )
                }
                pendingTimeouts[requestID] = timeoutTask
                if !writeJSONLine(request, to: fd) {
                    pendingTimeouts.removeValue(forKey: requestID)?.cancel()
                    if let continuation = pending.take(id: requestID) {
                        disconnect(error: ToolError.failed("Lost the engine daemon connection."))
                        continuation.resume(throwing: ToolError.failed("Lost the engine daemon connection."))
                    }
                }
            }
        } onCancel: {
            Task {
                await self.failPending(id: requestID, error: CancellationError())
                if let operationID = operationIDForCallerCancellation {
                    await self.sendCancel(operationID: operationID)
                }
            }
        }
    }

    private func sendCancel(operationID: String) {
        guard fd >= 0 else { return }
        let request = DaemonRequest(
            id: allocateID(), method: "cancel", cancelOperationID: operationID)
        _ = writeJSONLine(request, to: fd)
    }

    private func fulfill(_ response: DaemonResponse) {
        pendingTimeouts.removeValue(forKey: response.id)?.cancel()
        pending.take(id: response.id)?.resume(returning: response)
    }

    private func failPending(id: Int, error: any Error) {
        pendingTimeouts.removeValue(forKey: id)?.cancel()
        pending.take(id: id)?.resume(throwing: error)
    }

    private func connectionDropped(fd dropped: Int32) {
        guard dropped == fd else { return }  // a stale reader from a replaced connection
        disconnect(error: ToolError.failed("The engine daemon connection closed."))
    }

    private func disconnect(error: any Error) {
        if fd >= 0 { close(fd) }
        fd = -1
        for timeout in pendingTimeouts.values { timeout.cancel() }
        pendingTimeouts.removeAll()
        for continuation in pending.takeAll() {
            continuation.resume(throwing: error)
        }
    }
}

func daemonRetryAllowed(
    originalIncarnationID: String?, currentIncarnationID: String?, connectionChanged: Bool
) -> Bool {
    guard connectionChanged else { return true }
    guard let originalIncarnationID, let currentIncarnationID else { return false }
    return originalIncarnationID == currentIncarnationID
}

func daemonRetryPermitted(
    isMutating: Bool, deduplicationSupported: Bool, daemonIncarnationID: String?
) -> Bool {
    !isMutating || (deduplicationSupported && daemonIncarnationID != nil)
}
