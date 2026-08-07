// `daemon` — the shared engine process.
//
// Exactly one daemon serves all agent sessions of a user (flock singleton,
// like the overlay helper). It owns accessibility, screen capture, input
// delivery, and the agent cursor; serve shims connect over a unix socket and
// forward tool calls. One engine process means sessions cannot collide on
// shared system services, and AppMutationCoordinator keeps operations from
// interleaving inside the same app while allowing different apps to proceed.

import Darwin
import Foundation
import MCP

private let daemonConnectionLimiter = DaemonConnectionLimiter(maxConnections: DaemonProtocolLimits.maxConcurrentConnections)
private let daemonIncarnationID = UUID().uuidString

func runDaemon() async -> Never {
    // Singleton: hold the lock for the daemon's lifetime; the kernel releases
    // it on exit or crash. A concurrently spawned daemon defers to the
    // incumbent.
    let lockFD = open(daemonLockPath(), O_CREAT | O_WRONLY, 0o644)
    if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
        exit(0)
    }

    let authToken: String
    do {
        authToken = try daemonAuthToken()
    } catch {
        daemonLog("daemon auth setup failed: \(error)")
        exit(1)
    }

    let listenFD = bindDaemonSocket()
    DaemonState.shared.setListenFD(listenFD)
    daemonLog("daemon \(version) listening (pid \(ProcessInfo.processInfo.processIdentifier))")

    // Accept loop on its own thread (accept(2) blocks); each connection gets
    // a reader thread; each request runs as a Task through the shared
    // dispatch funnel.
    let thread = Thread {
        while true {
            let connectionFD = accept(listenFD, nil, nil)
            if connectionFD < 0 {
                if DaemonState.shared.isDraining { return }
                continue
            }
            guard isTrustedPeer(connectionFD) else {
                daemonLog("rejected daemon connection from untrusted peer")
                close(connectionFD)
                continue
            }
            guard daemonConnectionLimiter.tryOpen() else {
                daemonLog("rejected daemon connection: connection cap reached")
                close(connectionFD)
                continue
            }
            DaemonState.shared.connectionOpened()
            Thread.detachNewThread {
                let connectionTasks = DaemonConnectionTasks()
                let authorization = DaemonConnectionAuthorization()
                defer {
                    connectionTasks.cancelAll()
                    Task {
                        if let sessionID = authorization.sessionID {
                            if DaemonSessionRegistry.shared.detach(sessionID: sessionID) {
                                await DaemonOperationRegistry.shared.disconnect(sessionID: sessionID)
                                DaemonSessionRegistry.shared.finishCleanup(sessionID: sessionID)
                            }
                        }
                        await AgentCursor.shared.dropSession(connectionFD)
                    }
                    DaemonState.shared.connectionClosed()
                    daemonConnectionLimiter.close()
                }
                serveConnection(
                    fd: connectionFD, authToken: authToken, authorization: authorization,
                    connectionTasks: connectionTasks
                )
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

private func isTrustedPeer(_ fd: Int32) -> Bool {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0 else {
        return false
    }
    return uid == geteuid()
}

private func serveConnection(
    fd: Int32, authToken: String, authorization: DaemonConnectionAuthorization,
    connectionTasks: DaemonConnectionTasks
) {
    defer { close(fd) }
    let authenticationDeadline = Date().addingTimeInterval(
        TimeInterval(DaemonProtocolLimits.authenticationTimeoutSeconds)
    )
    // Serializes response writes from concurrently completing tool Tasks.
    let writeLock = NSLock()
    var frames = DaemonLineBuffer<DaemonRequest>()
    var chunk = [UInt8](repeating: 0, count: DaemonProtocolLimits.readChunkBytes)

    while true {
        if !authorization.isAuthenticated {
            let remaining = authenticationDeadline.timeIntervalSinceNow
            guard remaining > 0 else {
                daemonLog("closing daemon connection after authentication timeout")
                return
            }
            setReadTimeout(fd, seconds: max(1, Int(ceil(remaining))))
        }

        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { break }

        do {
            for frame in try frames.append(contentsOf: chunk[0..<n]) {
                switch frame {
                case .message(let request):
                    let wasAuthenticated = authorization.isAuthenticated
                    let action = handle(
                        request: request,
                        fd: fd,
                        writeLock: writeLock,
                        authToken: authToken,
                        authorization: authorization,
                        connectionTasks: connectionTasks
                    )
                    if !wasAuthenticated && authorization.isAuthenticated {
                        clearReadTimeout(fd)
                    }
                    if action == .close {
                        return
                    }
                case .malformed:
                    if authorization.recordMalformedFrame(maxFrames: DaemonProtocolLimits.maxMalformedFrames) {
                        daemonLog("closing daemon connection after malformed frame budget was exhausted")
                        return
                    }
                    if authorization.recordUnauthenticatedFailure(maxFailures: DaemonProtocolLimits.maxUnauthenticatedFailures) {
                        daemonLog("closing daemon connection after unauthenticated request budget was exhausted")
                        return
                    }
                }
            }
        } catch DaemonProtocolViolation.frameTooLarge(let maxBytes) {
            daemonLog("closing daemon connection after frame exceeded \(maxBytes) bytes")
            return
        } catch {
            daemonLog("closing daemon connection after protocol parse failure: \(error)")
            return
        }
    }
}

final class DaemonConnectionAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var authenticated = false
    private var malformedFrames = 0
    private var unauthenticatedFailures = 0
    private var logicalSession: DaemonLogicalSession?

    func markAuthenticated(session: DaemonLogicalSession) {
        lock.lock()
        authenticated = true
        logicalSession = session
        malformedFrames = 0
        unauthenticatedFailures = 0
        lock.unlock()
    }

    func markAuthenticated() {
        markAuthenticated(session: DaemonSessionRegistry.shared.establish(resumeToken: nil))
    }

    var sessionID: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return logicalSession?.id
    }

    var session: DaemonLogicalSession? {
        lock.lock()
        defer { lock.unlock() }
        return logicalSession
    }

    var isAuthenticated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return authenticated
    }

    func recordMalformedFrame(maxFrames: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        malformedFrames += 1
        return malformedFrames > maxFrames
    }

    func recordUnauthenticatedFailure(maxFailures: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !authenticated else {
            return false
        }
        unauthenticatedFailures += 1
        return unauthenticatedFailures > maxFailures
    }
}

/// Per-connection in-flight tool Tasks. Cancelled when the client disconnects
/// so mutating input work observes Task.isCancelled and stops.
final class DaemonConnectionTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Int: Task<Void, Never>] = [:]

    func add(_ task: Task<Void, Never>, id: Int) {
        lock.lock()
        tasks[id] = task
        lock.unlock()
    }

    func start(
        id: Int, reservation: DaemonMutationSequencer.Reservation? = nil,
        sequencer: DaemonMutationSequencer = .shared,
        operation: @escaping @Sendable () async -> Void
    ) {
        lock.lock()
        let task = Task {
            defer {
                if let reservation { sequencer.finish(reservation) }
            }
            if let predecessor = reservation?.predecessor { await predecessor.value }
            let queueLatency = reservation?.predecessor == nil
                ? 0
                : durationMilliseconds(reservation!.enqueuedAt.duration(to: .now))
            if !Task.isCancelled {
                await DaemonSessionContext.$queueLatencyMilliseconds.withValue(queueLatency) {
                    await operation()
                }
            }
        }
        tasks[id] = task
        lock.unlock()
    }

    func remove(id: Int) {
        lock.lock()
        tasks[id] = nil
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let active = Array(tasks.values)
        tasks.removeAll()
        lock.unlock()
        for task in active {
            task.cancel()
        }
    }


    func waitForAll() async {
        let active = activeTasks()
        for task in active { await task.value }
    }

    private func activeTasks() -> [Task<Void, Never>] {
        lock.lock()
        defer { lock.unlock() }
        return Array(tasks.values)
    }
}

private func durationMilliseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000
        + Double(components.attoseconds) / 1_000_000_000_000_000
}

private enum DaemonConnectionAction: Equatable {
    case keepOpen
    case close
}

private func handle(
    request: DaemonRequest,
    fd: Int32,
    writeLock: NSLock,
    authToken: String,
    authorization: DaemonConnectionAuthorization,
    connectionTasks: DaemonConnectionTasks
) -> DaemonConnectionAction {
    @Sendable func respond(_ response: DaemonResponse) {
        writeLock.lock()
        _ = writeJSONLine(response, to: fd)
        writeLock.unlock()
    }

    func unauthorized() -> DaemonConnectionAction {
        respond(
            DaemonResponse.from(
                codedErrorResult("Unauthorized daemon request.", code: .daemonUnauthorized),
                id: request.id
            ))
        if authorization.recordUnauthenticatedFailure(maxFailures: DaemonProtocolLimits.maxUnauthenticatedFailures) {
            daemonLog("closing daemon connection after unauthenticated request budget was exhausted")
            return .close
        }
        return .keepOpen
    }

    switch request.method {
    case "hello":
        guard let provided = request.authToken, constantTimeEqual(provided, authToken) else {
            return unauthorized()
        }
        let session: DaemonLogicalSession
        if let established = authorization.session {
            session = established
        } else {
            session = DaemonSessionRegistry.shared.establish(resumeToken: request.resumeToken)
            authorization.markAuthenticated(session: session)
        }
        respond(
            DaemonResponse(
                id: request.id, version: version, authenticated: true,
                buildStamp: executableBuildStamp, sessionID: session.id.uuidString,
                resumeToken: session.resumeToken, daemonIncarnationID: daemonIncarnationID,
                operationDeduplicationSupported: true
            ))
        return .keepOpen
    case "cancel":
        guard authorization.isAuthenticated, let sessionID = authorization.sessionID else {
            return unauthorized()
        }
        guard let rawOperationID = request.cancelOperationID,
            let operationID = UUID(uuidString: rawOperationID)
        else {
            respond(DaemonResponse.from(
                codedErrorResult("cancel requires a valid operation id.", code: nil),
                id: request.id))
            return .keepOpen
        }
        connectionTasks.start(id: request.id) {
            defer { connectionTasks.remove(id: request.id) }
            let disposition = await DaemonOperationRegistry.shared.cancel(
                operationID: operationID, sessionID: sessionID)
            if !Task.isCancelled {
                var response = disposition == .capacityExceeded
                    ? DaemonResponse.from(daemonOperationCapacityResult(), id: request.id)
                    : DaemonResponse(
                        id: request.id,
                        content: [DaemonContent(type: "text", text: disposition.rawValue)])
                response.operationID = operationID.uuidString
                response.cancellationDisposition = disposition.rawValue
                respond(response)
            }
        }
        return .keepOpen
    case "shutdown":
        guard authorization.isAuthenticated,
            let provided = request.authToken,
            constantTimeEqual(provided, authToken)
        else {
            return unauthorized()
        }
        guard daemonAllowsShutdown(
            requesterBuildStamp: request.buildStamp, daemonBuildStamp: executableBuildStamp
        ) else {
            daemonLog(
                "shutdown refused: requester buildStamp \(request.buildStamp ?? 0) is not newer than \(executableBuildStamp)"
            )
            respond(
                DaemonResponse.from(
                    codedErrorResult(
                        "Shutdown refused: requester build is not newer than this daemon.",
                        code: .daemonUnauthorized
                    ),
                    id: request.id
                ))
            return .keepOpen
        }
        daemonLog("shutdown requested by newer client (version handover)")
        respond(DaemonResponse(id: request.id))
        requestDaemonDrainAndExit()
        return .close
    default:
        guard authorization.isAuthenticated else {
            return unauthorized()
        }
        DaemonState.shared.noteActivity()
        guard let sessionID = authorization.sessionID else { return unauthorized() }
        let operationID: UUID
        if let rawOperationID = request.operationID {
            guard let parsed = UUID(uuidString: rawOperationID) else {
                respond(DaemonResponse.from(
                    codedErrorResult("operationID must be a UUID.", code: nil), id: request.id))
                return .keepOpen
            }
            operationID = parsed
        } else {
            operationID = UUID()
        }
        let arguments = request.arguments ?? [:]
        let requestFingerprint = daemonOperationFingerprint(
            method: request.method, arguments: arguments)
        let reservation = Config.bool("no_app_lease") == true
            ? nil
            : mutationSerializationKey(name: request.method, arguments: arguments)
                .map {
                    DaemonMutationSequencer.shared.reserve(
                        sessionID: sessionID, appKey: $0)
                }
        connectionTasks.start(id: request.id, reservation: reservation) {
            defer { connectionTasks.remove(id: request.id) }
            let result = await DaemonOperationRegistry.shared.run(
                operationID: operationID, sessionID: sessionID,
                requestFingerprint: requestFingerprint,
                retainCompleted: isMutatingTool(request.method)
            ) {
                await DaemonSessionContext.$sessionID.withValue(fd) {
                    await DaemonSessionContext.$logicalSessionID.withValue(sessionID) {
                        await DaemonSessionContext.$operationID.withValue(operationID) {
                            await ActionTransactionContext.$currentOperationID.withValue(operationID) {
                                await dispatchCoordinatedTool(
                                    name: request.method, arguments: arguments,
                                    sessionID: sessionID, operationID: operationID)
                            }
                        }
                    }
                }
            }
            var response = DaemonResponse.from(result, id: request.id)
            response.operationID = operationID.uuidString
            if !Task.isCancelled { respond(response) }
            DaemonState.shared.noteActivity()
        }
        return .keepOpen
    }
}

private func dispatchCoordinatedTool(
    name: String, arguments: [String: Value], sessionID: UUID, operationID: UUID
) async -> CallTool.Result {
    guard Config.bool("no_app_lease") != true,
        daemonCoordinatedToolNames.contains(name),
        let coordinationKey = coordinatedAppKey(name: name, arguments: arguments)
    else {
        return await dispatchTool(name: name, arguments: arguments)
    }

    let coordinatorQueuedAt = ContinuousClock.now
    let admission = await withTaskCancellationHandler {
        await AppMutationCoordinator.shared.acquire(
            key: coordinationKey, sessionID: sessionID, operationID: operationID)
    } onCancel: {
        Task {
            await AppMutationCoordinator.shared.cancelQueued(
                operationID: operationID, sessionID: sessionID)
        }
    }
    let accumulatedQueueLatency = daemonAccumulatedQueueLatency(
        coordinatorWaitMilliseconds: durationMilliseconds(
            coordinatorQueuedAt.duration(to: .now)))
    switch admission {
    case .busy(let ownerSessionID):
        return appBusyResult(ownerSessionID: ownerSessionID)
    case .cancelled:
        return codedErrorResult("Operation cancelled before execution.", code: nil)
    case .acquired:
        return await DaemonSessionContext.$queueLatencyMilliseconds.withValue(
            accumulatedQueueLatency
        ) {
            if Task.isCancelled {
                await AppMutationCoordinator.shared.release(
                    key: coordinationKey, sessionID: sessionID, operationID: operationID)
                return codedErrorResult("Operation cancelled before execution.", code: nil)
            }
            var priorCompositeCommit = false
            if name == "run_skill" {
                switch await prepareRunSkillTarget(arguments: arguments) {
                case .ready(_, let priorCommit):
                    priorCompositeCommit = priorCommit
                case .result(let result):
                    await AppMutationCoordinator.shared.release(
                        key: coordinationKey, sessionID: sessionID,
                        operationID: operationID)
                    return result
                }
            }
            if Task.isCancelled {
                await AppMutationCoordinator.shared.release(
                    key: coordinationKey, sessionID: sessionID, operationID: operationID)
                let cancelled = operationCancelledResult()
                return priorCompositeCommit
                    ? cancelled.withPartialCommitEvidence()
                    : cancelled
            }
            let result = await CompositeCommitContext.$priorMutationCommitted.withValue(
                priorCompositeCommit
            ) {
                await dispatchTool(name: name, arguments: arguments)
            }
            await AppMutationCoordinator.shared.release(
                key: coordinationKey, sessionID: sessionID, operationID: operationID)
            return result
        }
    }
}

func daemonAccumulatedQueueLatency(coordinatorWaitMilliseconds: Double) -> Double {
    (DaemonSessionContext.queueLatencyMilliseconds ?? 0)
        + max(0, coordinatorWaitMilliseconds)
}

private enum RunSkillPreparation {
    case ready(pid_t, priorCommit: Bool)
    case result(CallTool.Result)
}

private func prepareRunSkillTarget(arguments: [String: Value]) async -> RunSkillPreparation {
    guard case .string(let skillName)? = arguments["name"],
        let skill = try? SkillStore.load(skillName)
    else {
        return .result(await dispatchTool(name: "run_skill", arguments: arguments))
    }
    if let app = try? resolveApp(skill.app) { return .ready(app.pid, priorCommit: false) }
    // Preserve run_skill's confirmation behavior. An unconfirmed request is
    // dispatched normally and fails before mutation; confirmed/disabled-safety
    // requests launch first, then acquire the real PID before replaying steps.
    guard SafetyPolicy.confirmed(arguments) || !SafetyPolicy.isEnabled else {
        return .result(await dispatchTool(name: "run_skill", arguments: arguments))
    }
    let launch = await dispatchTool(
        name: "open_app", arguments: ["app": .string(skill.app), "confirm": .bool(true)])
    if launch.isError == true { return .result(launch) }
    if Task.isCancelled {
        return .result(operationCancelledResult().withPartialCommitEvidence())
    }
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if let app = try? resolveApp(skill.app) {
            return .ready(app.pid, priorCommit: true)
        }
        do {
            try await Task.sleep(for: .milliseconds(100))
        } catch {
            return .result(operationCancelledResult().withPartialCommitEvidence())
        }
    }
    return .result(codedErrorResult(
        "Skill target app did not become controllable in time.", code: .appNotFound)
        .withPartialCommitEvidence())
}

private func coordinatedAppPID(name: String, arguments: [String: Value]) -> pid_t? {
    if case .string(let appName)? = arguments["app"] {
        return try? resolveApp(appName).pid
    }
    if name == "run_skill", case .string(let skillName)? = arguments["name"],
        let skill = try? SkillStore.load(skillName)
    {
        return try? resolveApp(skill.app).pid
    }
    return nil
}

private let daemonCoordinatedToolNames = appScopedToolNames.union(["open_app"])

func canonicalAppCoordinationKey(
    identifier: String, resolvedPID: pid_t?, resolvedBundleIdentifier: String?,
    applicationURLResolver: (String) -> URL? = applicationURL
) -> AppCoordinationKey {
    if let bundleIdentifier = resolvedBundleIdentifier,
        !bundleIdentifier.isEmpty, bundleIdentifier != "unknown"
    {
        return .bundleIdentifier(bundleIdentifier.lowercased())
    }
    if let installed = applicationURLResolver(identifier)
        .flatMap(Bundle.init(url:))?.bundleIdentifier, !installed.isEmpty
    {
        return .bundleIdentifier(installed.lowercased())
    }
    if let resolvedPID { return .pid(resolvedPID) }
    return .unresolvedIdentity(identifier.lowercased())
}

private func coordinatedAppKey(
    name: String, arguments: [String: Value]
) -> AppCoordinationKey? {
    let identifier: String
    if case .string(let appName)? = arguments["app"] {
        identifier = appName
    } else if name == "run_skill", case .string(let skillName)? = arguments["name"],
        let skill = try? SkillStore.load(skillName)
    {
        identifier = skill.app
    } else {
        return nil
    }
    let resolved = try? resolveApp(identifier)
    return canonicalAppCoordinationKey(
        identifier: identifier, resolvedPID: resolved?.pid,
        resolvedBundleIdentifier: resolved?.bundleIdentifier)
}

func mutationSerializationKey(
    name: String, arguments: [String: Value],
    resolveKey: (String, [String: Value]) -> AppCoordinationKey? = coordinatedAppKey
) -> String? {
    guard daemonCoordinatedToolNames.contains(name) else { return nil }
    return resolveKey(name, arguments)?.serializationKey
}

/// Stop accepting new clients and exit shortly so in-flight replies can flush.
/// Newer clients then spawn a fresh daemon.
private func requestDaemonDrainAndExit() {
    DaemonState.shared.beginDrain()
    Thread.detachNewThread {
        Thread.sleep(forTimeInterval: 0.35)
        daemonLog("shutdown drain complete")
        exit(0)
    }
}

private func setReadTimeout(_ fd: Int32, seconds: Int) {
    var timeout = timeval(tv_sec: seconds, tv_usec: 0)
    withUnsafePointer(to: &timeout) { pointer in
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
    }
}

private func clearReadTimeout(_ fd: Int32) {
    var timeout = timeval(tv_sec: 0, tv_usec: 0)
    withUnsafePointer(to: &timeout) { pointer in
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
    }
}

/// Connection count + last activity, for the idle self-exit. Class with a
/// lock (not an actor): it is touched from raw connection threads.
private final class DaemonState: @unchecked Sendable {
    static let shared = DaemonState()
    private let lock = NSLock()
    private var connections = 0
    private var lastActivity = Date()
    private var listenFD: Int32 = -1
    private var draining = false

    func setListenFD(_ fd: Int32) {
        lock.lock()
        listenFD = fd
        lock.unlock()
    }

    func beginDrain() {
        lock.lock()
        draining = true
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 {
            // Unlink first so a replacement daemon can bind; then close so the
            // accept loop wakes and observes the drain flag.
            unlink(daemonSocketPath())
            close(fd)
        }
    }

    var isDraining: Bool {
        lock.lock()
        defer { lock.unlock() }
        return draining
    }

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
