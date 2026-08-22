import Darwin
import Foundation
import MCP
import Testing

@testable import computer_use_mcp

/// Exercises the coordination primitives through the daemon's JSON wire types
/// and independent Unix socket connections without resolving or controlling a
/// real application. The small server is deliberately test-local: production
/// dispatch remains hard-wired to macOS app discovery.
@Suite struct DaemonWireContractTests {
    @Test func twoClientsProveFIFOBusyAndDifferentAppConcurrency() async throws {
        let fixture = DaemonWireFixture()
        let firstClient = try fixture.connect()
        let firstHello = try await firstClient.exchange(
            DaemonRequest(id: 1, method: "hello"))
        let resumeToken = try #require(firstHello.resumeToken)
        let sessionID = try #require(firstHello.sessionID)

        let resumedClient = try fixture.connect()
        let resumedHello = try await resumedClient.exchange(
            DaemonRequest(id: 2, method: "hello", resumeToken: resumeToken))
        #expect(resumedHello.sessionID == sessionID)

        let otherClient = try fixture.connect()
        let otherHello = try await otherClient.exchange(
            DaemonRequest(id: 3, method: "hello"))
        #expect(otherHello.sessionID != sessionID)

        let firstOperation = UUID()
        let first = Task {
            try await firstClient.exchange(
                fixture.mutation(
                    id: 10, operationID: firstOperation, pid: 41_001,
                    label: "first", held: true))
        }
        await fixture.waitForTrace("started:first")

        let secondOperation = UUID()
        let second = Task {
            try await resumedClient.exchange(
                fixture.mutation(
                    id: 11, operationID: secondOperation, pid: 41_001,
                    label: "second"))
        }
        await fixture.waitForQueued(operationID: secondOperation, pid: 41_001)
        #expect(!fixture.traceContains("started:second"))

        let busy = try await otherClient.exchange(
            fixture.mutation(
                id: 12, operationID: UUID(), pid: 41_001, label: "busy"))
        #expect(busy.isError == true)
        #expect(responseText(busy).contains("APP_BUSY"))

        let otherApp = try await otherClient.exchange(
            fixture.mutation(
                id: 13, operationID: UUID(), pid: 41_002, label: "other-app"))
        #expect(otherApp.isError != true)
        #expect(responseText(otherApp) == "other-app")
        #expect(!fixture.traceContains("finished:first"))

        await fixture.openGate("first")
        let firstResponse: DaemonResponse
        do {
            firstResponse = try await first.value
        } catch {
            Issue.record("first held response failed; trace=\(fixture.traceValues())")
            throw error
        }
        #expect(responseText(firstResponse) == "first")
        #expect(responseText(try await second.value) == "second")
        #expect(
            fixture.traceIndex("started:first")
                < fixture.traceIndex("started:second"))

        firstClient.close()
        resumedClient.close()
        otherClient.close()
        await fixture.waitForConnectionsToClose()
    }

    @Test func operationIDIsCachedAcrossDuplicateAndReconnect() async throws {
        let fixture = DaemonWireFixture()
        let client = try fixture.connect()
        let hello = try await client.exchange(DaemonRequest(id: 1, method: "hello"))
        let sessionID = try #require(hello.sessionID)
        let resumeToken = try #require(hello.resumeToken)
        let operationID = UUID()
        let request = fixture.mutation(
            id: 2, operationID: operationID, pid: 42_001, label: "once")

        let original = try await client.exchange(request)
        let duplicate = try await client.exchange(
            fixture.mutation(
                id: 3, operationID: operationID, pid: 42_001, label: "once"))
        #expect(responseText(original) == "once")
        #expect(responseText(duplicate) == "once")
        #expect(fixture.traceCount("started:once") == 1)

        client.close()
        await fixture.waitForSessionDisconnect(sessionID)

        let reconnected = try fixture.connect()
        let resumed = try await reconnected.exchange(
            DaemonRequest(id: 4, method: "hello", resumeToken: resumeToken))
        #expect(resumed.sessionID == sessionID)
        let replay = try await reconnected.exchange(
            fixture.mutation(
                id: 5, operationID: operationID, pid: 42_001, label: "once"))
        #expect(responseText(replay) == "once")
        #expect(fixture.traceCount("started:once") == 1)

        reconnected.close()
        await fixture.waitForConnectionsToClose()
    }

    @Test func cancelQueuedAndRunningOperations() async throws {
        let fixture = DaemonWireFixture()
        let ownerClient = try fixture.connect()
        let hello = try await ownerClient.exchange(
            DaemonRequest(id: 1, method: "hello"))
        let resumeToken = try #require(hello.resumeToken)

        let queuedClient = try fixture.connect()
        _ = try await queuedClient.exchange(
            DaemonRequest(id: 2, method: "hello", resumeToken: resumeToken))
        let controlClient = try fixture.connect()
        _ = try await controlClient.exchange(
            DaemonRequest(id: 3, method: "hello", resumeToken: resumeToken))

        let runningID = UUID()
        let running = Task {
            try await ownerClient.exchange(
                fixture.mutation(
                    id: 10, operationID: runningID, pid: 43_001,
                    label: "running", held: true))
        }
        await fixture.waitForTrace("started:running")

        let queuedID = UUID()
        let queued = Task {
            try await queuedClient.exchange(
                fixture.mutation(
                    id: 11, operationID: queuedID, pid: 43_001,
                    label: "queued"))
        }
        await fixture.waitForQueued(operationID: queuedID, pid: 43_001)

        let cancelQueued = try await controlClient.exchange(
            DaemonRequest(
                id: 12, method: "cancel",
                cancelOperationID: queuedID.uuidString))
        #expect(responseText(cancelQueued) == "cancelled")
        #expect(cancelQueued.cancellationDisposition == "cancelled")
        let queuedResponse: DaemonResponse
        do {
            queuedResponse = try await queued.value
        } catch {
            Issue.record("queued cancellation response failed; trace=\(fixture.traceValues())")
            throw error
        }
        #expect(responseText(queuedResponse) == "cancelled")
        #expect(!fixture.traceContains("started:queued"))

        let cancelRunning = try await controlClient.exchange(
            DaemonRequest(
                id: 13, method: "cancel",
                cancelOperationID: runningID.uuidString))
        #expect(responseText(cancelRunning) == "cancellation_requested")
        #expect(cancelRunning.cancellationDisposition == "cancellation_requested")
        #expect(responseText(try await running.value) == "cancelled")
        #expect(fixture.traceContains("cancelled:running"))

        ownerClient.close()
        queuedClient.close()
        controlClient.close()
        await fixture.waitForConnectionsToClose()
    }

    @Test func disconnectCancelsRunningWorkAndReleasesApp() async throws {
        let fixture = DaemonWireFixture()
        let abandonedClient = try fixture.connect()
        let hello = try await abandonedClient.exchange(
            DaemonRequest(id: 1, method: "hello"))
        let abandonedSessionID = try #require(hello.sessionID)
        let operationID = UUID()

        let abandonedCall = Task {
            try await abandonedClient.exchange(
                fixture.mutation(
                    id: 2, operationID: operationID, pid: 44_001,
                    label: "abandoned", held: true))
        }
        await fixture.waitForTrace("started:abandoned")
        abandonedClient.close()
        await fixture.waitForSessionDisconnect(abandonedSessionID)
        await fixture.waitForTrace("cancelled:abandoned")
        await fixture.waitForTrace("released:abandoned")
        _ = try? await abandonedCall.value

        let replacement = try fixture.connect()
        _ = try await replacement.exchange(
            DaemonRequest(id: 3, method: "hello"))
        let result = try await replacement.exchange(
            fixture.mutation(
                id: 4, operationID: UUID(), pid: 44_001,
                label: "replacement"))
        #expect(responseText(result) == "replacement")

        replacement.close()
        await fixture.waitForConnectionsToClose()
    }

    @Test func legacyMessagesOmitEveryNewOptionalField() async throws {
        let legacyRequest = Data(#"{"id":1,"method":"hello"}"#.utf8)
        let decoded = try JSONDecoder().decode(
            DaemonRequest.self, from: legacyRequest)
        #expect(decoded.resumeToken == nil)
        #expect(decoded.operationID == nil)
        #expect(decoded.cancelOperationID == nil)

        let fixture = DaemonWireFixture()
        let client = try fixture.connect()
        let hello = try await client.exchange(decoded)
        #expect(hello.sessionID != nil)
        #expect(hello.resumeToken != nil)

        let response = try await client.exchange(
            DaemonRequest(
                id: 2, method: "mutate",
                arguments: [
                    "pid": .string("45001"),
                    "label": .string("legacy"),
                ]))
        #expect(responseText(response) == "legacy")
        #expect(UUID(uuidString: response.operationID ?? "") != nil)

        let legacyResponse = try JSONDecoder().decode(
            DaemonResponse.self,
            from: Data(#"{"id":99,"content":[]}"#.utf8))
        #expect(legacyResponse.sessionID == nil)
        #expect(legacyResponse.resumeToken == nil)
        #expect(legacyResponse.operationID == nil)
        #expect(legacyResponse.daemonIncarnationID == nil)

        client.close()
        await fixture.waitForConnectionsToClose()
    }
}

private final class DaemonWireFixture: @unchecked Sendable {
    private let sessions = DaemonSessionRegistry()
    private let operations: DaemonOperationRegistry
    private let coordinator: AppMutationCoordinator
    private let state = LockedWireFixtureState()
    private let connectionGroup = DispatchGroup()

    init() {
        let coordinator = AppMutationCoordinator()
        self.coordinator = coordinator
        self.operations = DaemonOperationRegistry(coordinator: coordinator)
    }

    func connect() throws -> WireClient {
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw WireFixtureError.systemCall("socketpair", errno)
        }
        // Keep a bounded deadline for a deliberately held operation while
        // leaving enough room for the hosted runner to schedule the sibling
        // connection that releases or cancels it.
        var timeout = timeval(tv_sec: 60, tv_usec: 0)
        guard setsockopt(
            sockets[0], SOL_SOCKET, SO_RCVTIMEO, &timeout,
            socklen_t(MemoryLayout<timeval>.size)) == 0
        else {
            let error = errno
            Darwin.close(sockets[0])
            Darwin.close(sockets[1])
            throw WireFixtureError.systemCall("setsockopt", error)
        }
        connectionGroup.enter()
        let connection = WireServerConnection(fd: sockets[1])
        Thread.detachNewThread { [self] in
            let handlerGroup = DispatchGroup()
            while let line = readJSONLine(from: connection.fd) {
                guard let request = try? JSONDecoder().decode(
                    DaemonRequest.self, from: line)
                else { continue }
                handlerGroup.enter()
                // The wire fixture is entered from a blocking POSIX reader
                // thread. Use an explicit detached task so held requests on
                // one connection cannot inherit and monopolize the test
                // runner's serial executor while another connection must
                // deliver a cancel, busy response, or gate release.
                Task.detached { [self] in
                    defer { handlerGroup.leave() }
                    let response = await handle(
                        request, connection: connection)
                    connection.write(response)
                }
            }
            if let sessionID = connection.sessionID {
                let cleanup = DispatchSemaphore(value: 0)
                Task { [self] in
                    if sessions.detach(sessionID: sessionID) {
                        await operations.disconnect(sessionID: sessionID)
                        sessions.finishCleanup(sessionID: sessionID)
                        state.recordDisconnected(sessionID.uuidString)
                    }
                    cleanup.signal()
                }
                cleanup.wait()
            }
            handlerGroup.wait()
            Darwin.close(connection.fd)
            connectionGroup.leave()
        }
        return WireClient(fd: sockets[0])
    }

    func mutation(
        id: Int, operationID: UUID, pid: pid_t, label: String,
        held: Bool = false
    ) -> DaemonRequest {
        DaemonRequest(
            id: id, method: "mutate",
            arguments: [
                "pid": .string(String(pid)),
                "label": .string(label),
                "held": .bool(held),
            ],
            operationID: operationID.uuidString)
    }

    func openGate(_ label: String) async {
        await state.gate(label).open()
    }

    func traceContains(_ value: String) -> Bool {
        state.traceContains(value)
    }

    func traceCount(_ value: String) -> Int {
        state.traceCount(value)
    }

    func traceIndex(_ value: String) -> Int {
        state.traceIndex(value)
    }

    func traceValues() -> [String] {
        state.traceValues()
    }

    func waitForTrace(_ value: String) async {
        await waitUntilWire { self.traceContains(value) }
    }

    func waitForQueued(operationID: UUID, pid: pid_t) async {
        await waitUntilWire {
            await self.coordinator.queuedOperationIDs(pid: pid)
                .contains(operationID)
        }
    }

    func waitForSessionDisconnect(_ sessionID: String) async {
        await waitUntilWire { self.state.wasDisconnected(sessionID) }
    }

    func waitForConnectionsToClose() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [connectionGroup] in
                connectionGroup.wait()
                continuation.resume()
            }
        }
    }

    private func handle(
        _ request: DaemonRequest, connection: WireServerConnection
    ) async -> DaemonResponse {
        if request.method == "hello" {
            let session = sessions.establish(resumeToken: request.resumeToken)
            connection.sessionID = session.id
            return DaemonResponse(
                id: request.id, authenticated: true,
                sessionID: session.id.uuidString,
                resumeToken: session.resumeToken,
                daemonIncarnationID: "wire-fixture")
        }
        guard let sessionID = connection.sessionID else {
            return DaemonResponse.from(
                codedErrorResult("unauthorized", code: .daemonUnauthorized),
                id: request.id)
        }
        if request.method == "cancel" {
            guard let rawID = request.cancelOperationID,
                let operationID = UUID(uuidString: rawID)
            else {
                return DaemonResponse.from(
                    codedErrorResult("invalid cancellation", code: nil),
                    id: request.id)
            }
            let disposition = await operations.cancel(
                operationID: operationID, sessionID: sessionID)
            var response = disposition == .capacityExceeded
                ? DaemonResponse.from(daemonOperationCapacityResult(), id: request.id)
                : DaemonResponse(
                    id: request.id,
                    content: [DaemonContent(type: "text", text: disposition.rawValue)])
            response.operationID = operationID.uuidString
            response.cancellationDisposition = disposition.rawValue
            return response
        }
        guard request.method == "mutate",
            let pidText = request.arguments?["pid"]?.stringValue,
            let pid = pid_t(pidText),
            let label = request.arguments?["label"]?.stringValue
        else {
            return DaemonResponse.from(
                codedErrorResult("invalid fixture mutation", code: nil),
                id: request.id)
        }
        let operationID = request.operationID
            .flatMap(UUID.init(uuidString:)) ?? UUID()
        let fingerprint = daemonOperationFingerprint(
            method: request.method, arguments: request.arguments ?? [:])
        let result = await operations.run(
            operationID: operationID, sessionID: sessionID,
            requestFingerprint: fingerprint
        ) { [state, coordinator] in
            let admission = await withTaskCancellationHandler {
                await coordinator.acquire(
                    pid: pid, sessionID: sessionID,
                    operationID: operationID)
            } onCancel: {
                Task {
                    await coordinator.cancelQueued(
                        operationID: operationID, sessionID: sessionID)
                }
            }
            guard admission == .acquired else {
                if case .busy(let ownerSessionID) = admission {
                    return appBusyResult(ownerSessionID: ownerSessionID)
                }
                return .text("cancelled")
            }
            state.record("started:\(label)")
            let operationResult: CallTool.Result
            if request.arguments?["held"]?.boolValue == true {
                let completed = await state.gate(label).wait()
                if !completed {
                    state.record("cancelled:\(label)")
                    operationResult = .text("cancelled")
                } else if Task.isCancelled {
                    state.record("cancelled:\(label)")
                    operationResult = .text("cancelled")
                } else {
                    state.record("finished:\(label)")
                    operationResult = .text(label)
                }
            } else if Task.isCancelled {
                state.record("cancelled:\(label)")
                operationResult = .text("cancelled")
            } else {
                state.record("finished:\(label)")
                operationResult = .text(label)
            }
            await coordinator.release(
                pid: pid, sessionID: sessionID,
                operationID: operationID)
            state.record("released:\(label)")
            return operationResult
        }
        var response = DaemonResponse.from(result, id: request.id)
        response.operationID = operationID.uuidString
        return response
    }
}

private final class WireServerConnection: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private var storedSessionID: UUID?

    init(fd: Int32) {
        self.fd = fd
    }

    var sessionID: UUID? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedSessionID
        }
        set {
            lock.lock()
            storedSessionID = newValue
            lock.unlock()
        }
    }

    func write(_ response: DaemonResponse) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        lock.lock()
        _ = data.withUnsafeBytes { buffer in
            send(fd, buffer.baseAddress, buffer.count, MSG_NOSIGNAL)
        }
        lock.unlock()
    }
}

private final class WireClient: @unchecked Sendable {
    private let descriptorLock = NSLock()
    private let exchangeLock = NSLock()
    private var fd: Int32

    init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        close()
    }

    func exchange(_ request: DaemonRequest) async throws -> DaemonResponse {
        try await Task.detached { [self] in
            try exchangeSynchronously(request)
        }.value
    }

    func close() {
        descriptorLock.lock()
        let descriptor = fd
        fd = -1
        descriptorLock.unlock()
        if descriptor >= 0 {
            shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
    }

    private func exchangeSynchronously(
        _ request: DaemonRequest
    ) throws -> DaemonResponse {
        exchangeLock.lock()
        defer { exchangeLock.unlock() }
        descriptorLock.lock()
        let descriptor = fd
        descriptorLock.unlock()
        guard descriptor >= 0 else {
            throw WireFixtureError.closed(requestID: request.id)
        }
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        let written = data.withUnsafeBytes { buffer in
            send(descriptor, buffer.baseAddress, buffer.count, MSG_NOSIGNAL)
        }
        guard written == data.count else {
            throw WireFixtureError.systemCall("send", errno)
        }
        guard let line = readJSONLine(from: descriptor) else {
            throw WireFixtureError.closed(requestID: request.id)
        }
        let response = try JSONDecoder().decode(
            DaemonResponse.self, from: line)
        guard response.id == request.id else {
            throw WireFixtureError.unexpectedResponseID(
                expected: request.id, actual: response.id)
        }
        return response
    }
}

private final class LockedWireFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var trace: [String] = []
    private var gates: [String: WireGate] = [:]
    private var disconnectedSessions: Set<String> = []

    func gate(_ label: String) -> WireGate {
        lock.lock()
        defer { lock.unlock() }
        if let gate = gates[label] { return gate }
        let gate = WireGate()
        gates[label] = gate
        return gate
    }

    func record(_ value: String) {
        lock.lock()
        trace.append(value)
        lock.unlock()
    }

    func traceContains(_ value: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return trace.contains(value)
    }

    func traceCount(_ value: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return trace.filter { $0 == value }.count
    }

    func traceIndex(_ value: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return trace.firstIndex(of: value) ?? .max
    }

    func traceValues() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return trace
    }

    func recordDisconnected(_ sessionID: String) {
        lock.lock()
        disconnectedSessions.insert(sessionID)
        lock.unlock()
    }

    func wasDisconnected(_ sessionID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return disconnectedSessions.contains(sessionID)
    }
}

private actor WireGate {
    private var opened = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func wait() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await suspend(id: id)
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    private func suspend(id: UUID) async -> Bool {
        if opened { return true }
        if Task.isCancelled { return false }
        return await withCheckedContinuation { waiters[id] = $0 }
    }

    private func cancel(id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: false)
    }

    func open() {
        opened = true
        let pending = waiters.values
        waiters.removeAll()
        pending.forEach { $0.resume(returning: true) }
    }
}

private enum WireFixtureError: Error {
    case closed(requestID: Int)
    case systemCall(String, Int32)
    case unexpectedResponseID(expected: Int, actual: Int)
}

private func readJSONLine(from fd: Int32) -> Data? {
    var data = Data()
    var byte: UInt8 = 0
    while true {
        let count = Darwin.read(fd, &byte, 1)
        if count == 0 { return nil }
        if count < 0 {
            if errno == EINTR { continue }
            return nil
        }
        if byte == 0x0A { return data }
        data.append(byte)
    }
}

private func waitUntilWire(
    _ predicate: @escaping @Sendable () async -> Bool
) async {
    // Polling with millisecond sleeps can consume the socket's entire bounded
    // receive deadline on a throttled hosted runner before the handler task is
    // scheduled. Yield directly to the coordination actors instead.
    for _ in 0..<10_000 {
        if await predicate() { return }
        await Task.yield()
    }
    Issue.record("wire fixture condition was not reached")
}

private func responseText(_ response: DaemonResponse) -> String {
    response.content?.compactMap(\.text).joined(separator: "\n") ?? ""
}
