import Foundation
import MCP

struct DaemonLogicalSession: Equatable, Sendable {
    let id: UUID
    let resumeToken: String
}

final class DaemonSessionRegistry: @unchecked Sendable {
    static let shared = DaemonSessionRegistry()

    private let lock = NSCondition()
    private var sessionsByToken: [String: DaemonLogicalSession] = [:]
    private var connectionCounts: [UUID: Int] = [:]
    private var cleaningSessions: Set<UUID> = []

    func establish(resumeToken: String?) -> DaemonLogicalSession {
        lock.lock()
        defer { lock.unlock() }
        if let resumeToken, let existing = sessionsByToken[resumeToken] {
            while cleaningSessions.contains(existing.id) { lock.wait() }
            connectionCounts[existing.id, default: 0] += 1
            return existing
        }
        let session = DaemonLogicalSession(
            id: UUID(), resumeToken: generateDaemonResumeToken())
        sessionsByToken[session.resumeToken] = session
        connectionCounts[session.id] = 1
        return session
    }

    /// Returns true only when the logical session has no remaining connection.
    func detach(sessionID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, (connectionCounts[sessionID] ?? 1) - 1)
        connectionCounts[sessionID] = remaining
        if remaining == 0 { cleaningSessions.insert(sessionID) }
        return remaining == 0
    }

    func finishCleanup(sessionID: UUID) {
        lock.lock()
        cleaningSessions.remove(sessionID)
        lock.broadcast()
        lock.unlock()
    }
}

enum AppMutationAdmission: Equatable, Sendable {
    case acquired
    case busy(ownerSessionID: UUID)
    case cancelled
}

enum AppCoordinationKey: Hashable, Sendable {
    case bundleIdentifier(String)
    case pid(pid_t)
    case unresolvedIdentity(String)

    var serializationKey: String {
        switch self {
        case .bundleIdentifier(let value): return "bundle:" + value
        case .pid(let value): return "pid:\(value)"
        case .unresolvedIdentity(let value): return "app:" + value
        }
    }
}

/// Reserves logical-session/app FIFO order synchronously at request receipt.
/// The lock establishes order before any unstructured request Task can run.
final class DaemonMutationSequencer: @unchecked Sendable {
    struct Key: Hashable {
        let sessionID: UUID
        let appKey: String
    }

    final class Reservation: @unchecked Sendable {
        fileprivate let key: Key
        let predecessor: Task<Void, Never>?
        fileprivate let completion: Task<Void, Never>
        fileprivate let continuation: AsyncStream<Void>.Continuation
        let enqueuedAt = ContinuousClock.now

        fileprivate init(key: Key, predecessor: Task<Void, Never>?) {
            self.key = key
            self.predecessor = predecessor
            var continuation: AsyncStream<Void>.Continuation!
            let stream = AsyncStream<Void> { continuation = $0 }
            self.continuation = continuation
            self.completion = Task {
                for await _ in stream {}
            }
        }
    }

    static let shared = DaemonMutationSequencer()

    private let lock = NSLock()
    private var tails: [Key: Reservation] = [:]

    func reserve(sessionID: UUID, appKey: String) -> Reservation {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(sessionID: sessionID, appKey: appKey)
        let reservation = Reservation(key: key, predecessor: tails[key]?.completion)
        tails[key] = reservation
        return reservation
    }

    func finish(_ reservation: Reservation) {
        lock.lock()
        if let current = tails[reservation.key], current === reservation {
            tails[reservation.key] = nil
        }
        lock.unlock()
        reservation.continuation.finish()
    }
}

/// Serializes mutations per canonical application identity. A session may pipeline work,
/// but its operations execute FIFO. Other sessions fail fast instead of
/// silently waiting behind an owner whose intent they cannot observe.
actor AppMutationCoordinator {
    static let shared = AppMutationCoordinator()

    private struct Owner {
        let sessionID: UUID
        let operationID: UUID
    }
    private struct Waiter {
        let sessionID: UUID
        let operationID: UUID
        let continuation: CheckedContinuation<AppMutationAdmission, Never>
    }

    private var owners: [AppCoordinationKey: Owner] = [:]
    private var queues: [AppCoordinationKey: [Waiter]] = [:]

    func acquire(pid: pid_t, sessionID: UUID, operationID: UUID) async -> AppMutationAdmission {
        await acquire(key: .pid(pid), sessionID: sessionID, operationID: operationID)
    }

    func acquire(
        key: AppCoordinationKey, sessionID: UUID, operationID: UUID
    ) async -> AppMutationAdmission {
        if Task.isCancelled { return .cancelled }
        if let owner = owners[key] {
            guard owner.sessionID == sessionID else {
                return .busy(ownerSessionID: owner.sessionID)
            }
            return await withCheckedContinuation { continuation in
                queues[key, default: []].append(
                    Waiter(sessionID: sessionID, operationID: operationID, continuation: continuation))
            }
        }
        owners[key] = Owner(sessionID: sessionID, operationID: operationID)
        return .acquired
    }

    func release(pid: pid_t, sessionID: UUID, operationID: UUID) {
        release(key: .pid(pid), sessionID: sessionID, operationID: operationID)
    }

    func release(key: AppCoordinationKey, sessionID: UUID, operationID: UUID) {
        guard let owner = owners[key], owner.sessionID == sessionID,
            owner.operationID == operationID
        else { return }
        var queue = queues[key] ?? []
        if queue.isEmpty {
            owners[key] = nil
            queues[key] = nil
            return
        }
        let next = queue.removeFirst()
        queues[key] = queue.isEmpty ? nil : queue
        owners[key] = Owner(sessionID: next.sessionID, operationID: next.operationID)
        next.continuation.resume(returning: .acquired)
    }

    @discardableResult
    func cancelQueued(operationID: UUID, sessionID: UUID) -> Bool {
        for key in Array(queues.keys) {
            guard var queue = queues[key],
                let index = queue.firstIndex(where: {
                    $0.operationID == operationID && $0.sessionID == sessionID
                })
            else { continue }
            let waiter = queue.remove(at: index)
            queues[key] = queue.isEmpty ? nil : queue
            waiter.continuation.resume(returning: .cancelled)
            return true
        }
        return false
    }

    func disconnect(sessionID: UUID) {
        for key in Array(queues.keys) {
            let queue = queues[key] ?? []
            let removed = queue.filter { $0.sessionID == sessionID }
            let retained = queue.filter { $0.sessionID != sessionID }
            queues[key] = retained.isEmpty ? nil : retained
            for waiter in removed {
                waiter.continuation.resume(returning: .cancelled)
            }
        }
        // Active ownership is released only by the active operation's defer.
    }

    func queuedOperationIDs(pid: pid_t) -> [UUID] {
        queuedOperationIDs(key: .pid(pid))
    }

    func queuedOperationIDs(key: AppCoordinationKey) -> [UUID] {
        (queues[key] ?? []).map(\.operationID)
    }
}

actor DaemonOperationRegistry {
    /// Longer than the default 120-second RPC timeout, leaving time for a
    /// disconnect, daemon reconnect, and replay with the same operation id.
    static let minimumDedupeRetention: TimeInterval = 10 * 60
    static func defaultDedupeRetention() -> TimeInterval {
        max(minimumDedupeRetention, daemonRPCTimeoutSeconds() * 2)
    }

    enum CancellationDisposition: String, Sendable {
        /// The operation was cancelled before its handler began executing.
        case cancelled
        /// The handler was already active; cancellation is cooperative and its final result is cached.
        case cancellationRequested = "cancellation_requested"
        case notRunning = "not_running"
        /// The cancel request was not retained and therefore is not guaranteed.
        case capacityExceeded = "capacity_exceeded"
    }

    static let shared = DaemonOperationRegistry()

    private struct Entry {
        let sessionID: UUID
        let requestFingerprint: String
        let task: Task<CallTool.Result, Never>
        let retainCompleted: Bool
        var completed: CallTool.Result?
        var completedAt: Date?
    }
    private struct CancellationTombstone {
        let sessionID: UUID
        let createdAt: Date
    }
    private final class RegistrationGate: @unchecked Sendable {
        private let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() {
            var continuation: AsyncStream<Void>.Continuation!
            stream = AsyncStream<Void> { continuation = $0 }
            self.continuation = continuation
        }

        func wait() async {
            for await _ in stream {}
        }

        func open() {
            continuation.finish()
        }
    }
    private var entries: [UUID: Entry] = [:]
    private let maxRetainedOperations: Int
    private var cancellationTombstones: [UUID: CancellationTombstone] = [:]
    private let maxCancellationTombstones: Int
    private let retention: TimeInterval
    private let now: @Sendable () -> Date
    private let coordinator: AppMutationCoordinator

    init(
        coordinator: AppMutationCoordinator = .shared,
        maxRetainedOperations: Int = 1_024,
        maxCancellationTombstones: Int = 1_024,
        retention: TimeInterval = defaultDedupeRetention(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.coordinator = coordinator
        self.maxRetainedOperations = maxRetainedOperations
        self.maxCancellationTombstones = maxCancellationTombstones
        self.retention = retention
        self.now = now
    }

    func run(
        operationID: UUID, sessionID: UUID, requestFingerprint: String,
        retainCompleted: Bool = true,
        operation: @escaping @Sendable () async -> CallTool.Result
    ) async -> CallTool.Result {
        pruneExpired(now: now())
        // A disconnected outer connection task can reach this actor after its
        // disconnect cleanup already scanned the registry. Refuse it before
        // consulting or creating any operation child task.
        guard !Task.isCancelled else { return operationCancelledResult() }
        if let entry = entries[operationID] {
            guard entry.sessionID == sessionID else {
                return codedErrorResult(
                    "Operation id belongs to a different daemon session.", code: .daemonUnauthorized)
            }
            guard entry.requestFingerprint == requestFingerprint else {
                return operationConflictResult()
            }
            if let completed = entry.completed { return completed }
            return await entry.task.value
        }
        if let tombstone = cancellationTombstones[operationID] {
            guard tombstone.sessionID == sessionID else {
                return codedErrorResult(
                    "Operation id belongs to a different daemon session.",
                    code: .daemonUnauthorized)
            }
            guard entries.count < maxRetainedOperations else {
                return daemonOperationCapacityResult()
            }
            cancellationTombstones[operationID] = nil
            let result = operationCancelledResult()
            let task = Task { result }
            entries[operationID] = Entry(
                sessionID: sessionID, requestFingerprint: requestFingerprint,
                task: task, retainCompleted: true,
                completed: result, completedAt: now())
            return result
        }

        guard entries.count < maxRetainedOperations else {
            return daemonOperationCapacityResult()
        }

        // Keep the handler behind a synchronous registration barrier so the
        // entry is visible before any operation code can execute.
        let registration = RegistrationGate()
        let task = Task {
            await registration.wait()
            guard !Task.isCancelled else { return operationCancelledResult() }
            return await operation()
        }
        entries[operationID] = Entry(
            sessionID: sessionID, requestFingerprint: requestFingerprint,
            task: task, retainCompleted: retainCompleted,
            completed: nil, completedAt: nil)
        registration.open()
        let result = await task.value
        if var entry = entries[operationID], entry.sessionID == sessionID {
            if entry.retainCompleted {
                entry.completed = result
                entry.completedAt = now()
                entries[operationID] = entry
            } else {
                entries[operationID] = nil
            }
        }
        return result
    }

    @discardableResult
    func cancel(operationID: UUID, sessionID: UUID) async -> CancellationDisposition {
        pruneExpired(now: now())
        if let entry = entries[operationID] {
            guard entry.sessionID == sessionID, entry.completed == nil else {
                return .notRunning
            }
            let cancelledBeforeExecution = await coordinator.cancelQueued(
                operationID: operationID, sessionID: sessionID)
            entry.task.cancel()
            return cancelledBeforeExecution ? .cancelled : .cancellationRequested
        }
        if let existing = cancellationTombstones[operationID] {
            return existing.sessionID == sessionID ? .cancelled : .notRunning
        }
        guard cancellationTombstones.count < maxCancellationTombstones else {
            return .capacityExceeded
        }
        cancellationTombstones[operationID] = CancellationTombstone(
            sessionID: sessionID, createdAt: now())
        return .cancelled
    }

    func disconnect(sessionID: UUID) async {
        for entry in entries.values where entry.sessionID == sessionID && entry.completed == nil {
            entry.task.cancel()
        }
        await coordinator.disconnect(sessionID: sessionID)
    }

    private func pruneExpired(now: Date) {
        entries = entries.filter { _, entry in
            guard let completedAt = entry.completedAt else { return true }
            return now.timeIntervalSince(completedAt) < retention
        }
        cancellationTombstones = cancellationTombstones.filter { _, tombstone in
            now.timeIntervalSince(tombstone.createdAt) < retention
        }
    }
}

func daemonOperationCapacityResult() -> CallTool.Result {
    CallTool.Result.text(
        "[DAEMON_CAPACITY] Operation deduplication capacity is temporarily full.",
        isError: true
    ).mergingMetaField(
        "computer-use-mcp/error",
        .object([
            "code": .string("DAEMON_CAPACITY"),
            "recovery": .string("Retry later with the same operation id."),
            "retryable": .bool(true),
        ]))
}

func appBusyResult(ownerSessionID _: UUID) -> CallTool.Result {
    CallTool.Result.text(
        "[APP_BUSY] Another daemon session owns this application.", isError: true
    ).mergingMetaField(
        "computer-use-mcp/error",
        .object([
            "code": .string("APP_BUSY"),
            "recovery": .string("Retry after the owning operation completes."),
            "retryable": .bool(true),
        ]))
}

func operationConflictResult() -> CallTool.Result {
    CallTool.Result.text(
        "[OPERATION_CONFLICT] Operation id was already used for a different request.",
        isError: true
    ).mergingMetaField(
        "computer-use-mcp/error",
        .object([
            "code": .string("OPERATION_CONFLICT"),
            "recovery": .string("Generate a new operation id for the different request."),
            "retryable": .bool(false),
        ]))
}

func operationCancelledResult() -> CallTool.Result {
    CallTool.Result.text(
        "[CANCELLED] Operation was cancelled before execution.", isError: true
    ).mergingMetaField(
        "computer-use-mcp/error",
        .object([
            "code": .string("CANCELLED"),
            "recovery": .string("Start a new operation only if the action is still needed."),
            "retryable": .bool(false),
        ]))
}

func daemonOperationFingerprint(method: String, arguments: [String: Value]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encoded = (try? encoder.encode(arguments)) ?? Data()
    return method + "\n" + encoded.base64EncodedString()
}
