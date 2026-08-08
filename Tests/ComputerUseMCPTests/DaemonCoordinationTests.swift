import Foundation
import MCP
import Testing

@testable import computer_use_mcp

@Suite struct DaemonCoordinationTests {
    @Test func protocolRoundTripsSessionAndOperationFields() throws {
        let operationID = UUID().uuidString
        let request = DaemonRequest(
            id: 1, method: "click", resumeToken: "resume", operationID: operationID,
            cancelOperationID: operationID)
        let decodedRequest = try JSONDecoder().decode(
            DaemonRequest.self, from: JSONEncoder().encode(request))
        #expect(decodedRequest.resumeToken == "resume")
        #expect(decodedRequest.operationID == operationID)
        #expect(decodedRequest.cancelOperationID == operationID)

        let response = DaemonResponse(
            id: 1, sessionID: UUID().uuidString, resumeToken: "resume",
            operationID: operationID, cancellationDisposition: "cancellation_requested",
            daemonIncarnationID: "daemon-a",
            operationDeduplicationSupported: true)
        let decodedResponse = try JSONDecoder().decode(
            DaemonResponse.self, from: JSONEncoder().encode(response))
        #expect(decodedResponse.sessionID == response.sessionID)
        #expect(decodedResponse.resumeToken == "resume")
        #expect(decodedResponse.operationID == operationID)
        #expect(decodedResponse.daemonIncarnationID == "daemon-a")
        #expect(decodedResponse.operationDeduplicationSupported == true)
        #expect(decodedResponse.cancellationDisposition == "cancellation_requested")
    }

    @Test func retryNeverCrossesDaemonIncarnation() {
        #expect(daemonRetryAllowed(
            originalIncarnationID: "a", currentIncarnationID: "a", connectionChanged: true))
        #expect(!daemonRetryAllowed(
            originalIncarnationID: "a", currentIncarnationID: "b", connectionChanged: true))
        #expect(!daemonRetryAllowed(
            originalIncarnationID: nil, currentIncarnationID: nil, connectionChanged: true))
        #expect(daemonRetryAllowed(
            originalIncarnationID: nil, currentIncarnationID: nil, connectionChanged: false))
    }

    @Test func legacyDaemonNeverRetriesMutationButReadOnlyMayRetry() {
        #expect(!daemonRetryPermitted(
            isMutating: true, deduplicationSupported: false,
            daemonIncarnationID: nil))
        #expect(!daemonRetryPermitted(
            isMutating: true, deduplicationSupported: true,
            daemonIncarnationID: nil))
        #expect(daemonRetryPermitted(
            isMutating: true, deduplicationSupported: true,
            daemonIncarnationID: "current"))
        #expect(daemonRetryPermitted(
            isMutating: false, deduplicationSupported: false,
            daemonIncarnationID: nil))
    }

    @Test func helloResumeTokenRestoresLogicalSession() {
        let registry = DaemonSessionRegistry()
        let first = registry.establish(resumeToken: nil)
        let resumed = registry.establish(resumeToken: first.resumeToken)
        let unknown = registry.establish(resumeToken: "unknown")

        #expect(resumed == first)
        #expect(unknown.id != first.id)
        #expect(unknown.resumeToken != "unknown")
        #expect(!registry.detach(sessionID: first.id))
        #expect(registry.detach(sessionID: first.id))
    }

    @Test func sameSessionQueuesFIFOAndCrossSessionIsBusy() async {
        let coordinator = AppMutationCoordinator()
        let session = UUID()
        let otherSession = UUID()
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let pid: pid_t = 7_001

        #expect(await coordinator.acquire(pid: pid, sessionID: session, operationID: first) == .acquired)
        let secondTask = Task {
            await coordinator.acquire(pid: pid, sessionID: session, operationID: second)
        }
        await waitUntil { await coordinator.queuedOperationIDs(pid: pid) == [second] }
        let thirdTask = Task {
            await coordinator.acquire(pid: pid, sessionID: session, operationID: third)
        }
        await waitUntil { await coordinator.queuedOperationIDs(pid: pid) == [second, third] }

        let busy = await coordinator.acquire(pid: pid, sessionID: otherSession, operationID: UUID())
        #expect(busy == .busy(ownerSessionID: session))

        await coordinator.release(pid: pid, sessionID: session, operationID: first)
        #expect(await secondTask.value == .acquired)
        #expect(await coordinator.queuedOperationIDs(pid: pid) == [third])
        await coordinator.release(pid: pid, sessionID: session, operationID: second)
        #expect(await thirdTask.value == .acquired)
        await coordinator.release(pid: pid, sessionID: session, operationID: third)
    }

    @Test func connectionMutationSchedulerPreservesWireOrder() async {
        let tasks = DaemonConnectionTasks()
        let sequencer = DaemonMutationSequencer()
        let sessionID = UUID()
        let gate = AsyncGate()
        let order = AsyncOrder()
        tasks.start(
            id: 1, reservation: sequencer.reserve(sessionID: sessionID, appKey: "pid:1"),
            sequencer: sequencer
        ) {
            await order.append(1)
            await gate.wait()
        }
        await waitUntil { await order.values == [1] }
        tasks.start(
            id: 2, reservation: sequencer.reserve(sessionID: sessionID, appKey: "pid:1"),
            sequencer: sequencer
        ) {
            await order.append(2)
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(await order.values == [1])
        await gate.open()
        await tasks.waitForAll()
        #expect(await order.values == [1, 2])
    }

    @Test func connectionTaskFinishHookRunsWhenQueuedWorkIsCancelled() async {
        let tasks = DaemonConnectionTasks()
        let sequencer = DaemonMutationSequencer()
        let sessionID = UUID()
        let gate = AsyncGate()
        let firstStarted = AsyncGate()
        let queuedExecutions = AsyncCounter()
        let finished = AsyncCounter()
        tasks.start(
            id: 1,
            reservation: sequencer.reserve(sessionID: sessionID, appKey: "pid:drain"),
            sequencer: sequencer,
            onFinish: { Task { await finished.increment() } }
        ) {
            await firstStarted.open()
            await gate.wait()
        }
        await firstStarted.wait()
        tasks.start(
            id: 2,
            reservation: sequencer.reserve(sessionID: sessionID, appKey: "pid:drain"),
            sequencer: sequencer,
            onFinish: { Task { await finished.increment() } }
        ) {
            await queuedExecutions.increment()
        }

        tasks.cancelAll()
        await gate.open()
        await waitUntil { await finished.value == 2 }

        #expect(await queuedExecutions.value == 0)
    }

    @Test func resumedConnectionsPreserveSharedLogicalSessionRequestOrder() async {
        let connectionA = DaemonConnectionTasks()
        let connectionB = DaemonConnectionTasks()
        let sequencer = DaemonMutationSequencer()
        let sessionID = UUID()
        let appKey = "bundle:com.example.shared"
        let firstGate = AsyncGate()
        let order = AsyncOrder()

        // Reservations are deliberately made A1, A2, B1 before any Task gets
        // a chance to determine the ordering itself.
        let a1 = sequencer.reserve(sessionID: sessionID, appKey: appKey)
        let a2 = sequencer.reserve(sessionID: sessionID, appKey: appKey)
        let b1 = sequencer.reserve(sessionID: sessionID, appKey: appKey)
        connectionA.start(id: 1, reservation: a1, sequencer: sequencer) {
            await order.append(1)
            await firstGate.wait()
        }
        connectionA.start(id: 2, reservation: a2, sequencer: sequencer) {
            await order.append(2)
        }
        connectionB.start(id: 1, reservation: b1, sequencer: sequencer) {
            await order.append(3)
        }

        await waitUntil { await order.values == [1] }
        await firstGate.open()
        await connectionA.waitForAll()
        await connectionB.waitForAll()
        #expect(await order.values == [1, 2, 3])
    }

    @Test func cancelBeforeRegistryRegistrationPreventsQueuedHandler() async {
        let tasks = DaemonConnectionTasks()
        let registry = DaemonOperationRegistry()
        let gate = AsyncGate()
        let firstStarted = AsyncGate()
        let executions = AsyncCounter()
        let resultBox = AsyncResult()
        let sessionID = UUID()
        let operationID = UUID()
        let sequencer = DaemonMutationSequencer()

        tasks.start(
            id: 1,
            reservation: sequencer.reserve(sessionID: sessionID, appKey: "pid:cancel-race"),
            sequencer: sequencer
        ) {
            await firstStarted.open()
            await gate.wait()
        }
        await firstStarted.wait()
        tasks.start(
            id: 2,
            reservation: sequencer.reserve(sessionID: sessionID, appKey: "pid:cancel-race"),
            sequencer: sequencer
        ) {
            let result = await registry.run(
                operationID: operationID, sessionID: sessionID,
                requestFingerprint: "click:{}"
            ) {
                await executions.increment()
                return .text("must not execute")
            }
            await resultBox.set(result)
        }

        #expect(
            await registry.cancel(operationID: operationID, sessionID: sessionID)
                == .cancelled)
        await gate.open()
        await tasks.waitForAll()

        #expect(await executions.value == 0)
        #expect(await resultBox.value?.isError == true)
        #expect(resultText(await resultBox.value ?? .text("missing")).contains("CANCELLED"))
    }

    @Test func disconnectBeforeActorRegistrationRejectsCancelledOuterTask() async {
        let registry = DaemonOperationRegistry()
        let enterRegistry = AsyncGate()
        let sessionID = UUID()
        let executions = AsyncCounter()
        let outer = Task {
            await enterRegistry.wait()
            return await registry.run(
                operationID: UUID(), sessionID: sessionID,
                requestFingerprint: "late", retainCompleted: true
            ) {
                await executions.increment()
                return .text("must not execute")
            }
        }

        outer.cancel()
        await registry.disconnect(sessionID: sessionID)
        await enterRegistry.open()

        let result = await outer.value
        #expect(result.isError == true)
        #expect(resultText(result).contains("CANCELLED"))
        #expect(await executions.value == 0)
    }

    @Test func acceptedAliasesForSamePIDShareWireOrderLane() async {
        let pid: pid_t = 42_424
        let resolver: (String, [String: Value]) -> AppCoordinationKey? = { _, arguments in
            switch arguments["app"]?.stringValue {
            case "Safari", "com.apple.Safari": return .pid(pid)
            default: return nil
            }
        }
        let nameKey = mutationSerializationKey(
            name: "click", arguments: ["app": .string("Safari")], resolveKey: resolver)
        let bundleKey = mutationSerializationKey(
            name: "type_text", arguments: ["app": .string("com.apple.Safari")],
            resolveKey: resolver)
        #expect(nameKey == "pid:\(pid)")
        #expect(bundleKey == nameKey)

        let tasks = DaemonConnectionTasks()
        let sequencer = DaemonMutationSequencer()
        let sessionID = UUID()
        let gate = AsyncGate()
        let order = AsyncOrder()
        let latency = AsyncDouble()
        tasks.start(
            id: 1, reservation: sequencer.reserve(sessionID: sessionID, appKey: nameKey!),
            sequencer: sequencer
        ) {
            await order.append(1)
            await gate.wait()
        }
        await waitUntil { await order.values == [1] }
        tasks.start(
            id: 2, reservation: sequencer.reserve(sessionID: sessionID, appKey: bundleKey!),
            sequencer: sequencer
        ) {
            await latency.set(DaemonSessionContext.queueLatencyMilliseconds)
            await order.append(2)
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(await order.values == [1])
        await gate.open()
        await tasks.waitForAll()
        #expect(await order.values == [1, 2])
        #expect(await latency.value != nil)
        #expect(await latency.value ?? 0 > 0)
    }

    @Test func stoppedAppOwnershipPrecedesLaunchAndCoversAliases() async throws {
        let utilityURL = try #require(applicationURL(for: "Activity Monitor"))
        #expect(utilityURL.path == "/System/Applications/Utilities/Activity Monitor.app")
        let installedResolver: (String) -> URL? = { identifier in
            switch identifier {
            case "Activity Monitor", "com.apple.ActivityMonitor": return utilityURL
            default: return nil
            }
        }
        let nameKey = canonicalAppCoordinationKey(
            identifier: "Activity Monitor", resolvedPID: nil, resolvedBundleIdentifier: nil,
            applicationURLResolver: installedResolver)
        let bundleKey = canonicalAppCoordinationKey(
            identifier: "com.apple.ActivityMonitor", resolvedPID: nil,
            resolvedBundleIdentifier: nil,
            applicationURLResolver: installedResolver)
        #expect(nameKey == bundleKey)
        #expect(
            mutationSerializationKey(
                name: "open_app", arguments: ["app": .string("Activity Monitor")],
                resolveKey: { _, _ in nameKey })
                == nameKey.serializationKey)

        let coordinator = AppMutationCoordinator()
        let ownerSession = UUID()
        let otherSession = UUID()
        let ownerOperation = UUID()
        let queuedOperation = UUID()
        let launches = AsyncCounter()
        #expect(await coordinator.acquire(
            key: nameKey, sessionID: ownerSession,
            operationID: ownerOperation) == .acquired)
        await launches.increment()  // launch happens only after ownership

        let contender = await coordinator.acquire(
            key: bundleKey, sessionID: otherSession, operationID: UUID())
        #expect(contender == .busy(ownerSessionID: ownerSession))
        #expect(await launches.value == 1)

        let queued = Task {
            await coordinator.acquire(
                key: bundleKey, sessionID: ownerSession,
                operationID: queuedOperation)
        }
        await waitUntil {
            await coordinator.queuedOperationIDs(key: nameKey) == [queuedOperation]
        }
        #expect(await coordinator.cancelQueued(
            operationID: queuedOperation, sessionID: ownerSession))
        #expect(await queued.value == .cancelled)
        await coordinator.release(
            key: nameKey, sessionID: ownerSession,
            operationID: ownerOperation)

        #expect(await coordinator.acquire(
            key: bundleKey, sessionID: otherSession,
            operationID: UUID()) == .acquired)
    }

    @Test func connectionMutationSchedulerAllowsDifferentApps() async {
        let tasks = DaemonConnectionTasks()
        let sequencer = DaemonMutationSequencer()
        let sessionID = UUID()
        let gate = AsyncGate()
        let order = AsyncOrder()
        tasks.start(
            id: 1, reservation: sequencer.reserve(sessionID: sessionID, appKey: "pid:1"),
            sequencer: sequencer
        ) {
            await order.append(1)
            await gate.wait()
        }
        await waitUntil { await order.values == [1] }
        tasks.start(
            id: 2, reservation: sequencer.reserve(sessionID: sessionID, appKey: "pid:2"),
            sequencer: sequencer
        ) {
            await order.append(2)
        }
        await waitUntil { await order.values == [1, 2] }
        await gate.open()
        await tasks.waitForAll()
    }

    @Test func differentAppsProceedConcurrently() async {
        let coordinator = AppMutationCoordinator()
        let sessionA = UUID()
        let sessionB = UUID()
        #expect(await coordinator.acquire(pid: 8_001, sessionID: sessionA, operationID: UUID()) == .acquired)
        #expect(await coordinator.acquire(pid: 8_002, sessionID: sessionB, operationID: UUID()) == .acquired)
    }

    @Test func queuedOperationCanBeCancelledWithoutReleasingOwner() async {
        let coordinator = AppMutationCoordinator()
        let session = UUID()
        let owner = UUID()
        let queued = UUID()
        let pid: pid_t = 9_001
        #expect(await coordinator.acquire(pid: pid, sessionID: session, operationID: owner) == .acquired)
        let queuedTask = Task {
            await coordinator.acquire(pid: pid, sessionID: session, operationID: queued)
        }
        await waitUntil { await coordinator.queuedOperationIDs(pid: pid) == [queued] }

        #expect(await coordinator.cancelQueued(operationID: queued, sessionID: session))
        #expect(await queuedTask.value == .cancelled)
        #expect(
            await coordinator.acquire(pid: pid, sessionID: UUID(), operationID: UUID())
                == .busy(ownerSessionID: session))
    }

    @Test func coordinatorWaitAccumulatesAcrossConnections() async {
        let coordinator = AppMutationCoordinator()
        let session = UUID()
        let first = UUID()
        let second = UUID()
        let pid: pid_t = 9_051
        #expect(await coordinator.acquire(
            pid: pid, sessionID: session, operationID: first) == .acquired)
        let latency = AsyncDouble()
        let queued = Task {
            await DaemonSessionContext.$queueLatencyMilliseconds.withValue(3) {
                let started = ContinuousClock.now
                let admission = await coordinator.acquire(
                    pid: pid, sessionID: session, operationID: second)
                let wait = testDurationMilliseconds(started.duration(to: .now))
                await latency.set(daemonAccumulatedQueueLatency(
                    coordinatorWaitMilliseconds: wait))
                return admission
            }
        }
        await waitUntil { await coordinator.queuedOperationIDs(pid: pid) == [second] }
        await coordinator.release(pid: pid, sessionID: session, operationID: first)
        #expect(await queued.value == .acquired)
        #expect(await latency.value ?? 0 > 3)
        await coordinator.release(pid: pid, sessionID: session, operationID: second)
    }

    @Test func disconnectCancelsQueuedWorkButKeepsActiveOwnership() async {
        let coordinator = AppMutationCoordinator()
        let session = UUID()
        let owner = UUID()
        let queued = UUID()
        let pid: pid_t = 9_101
        #expect(await coordinator.acquire(pid: pid, sessionID: session, operationID: owner) == .acquired)
        let queuedTask = Task {
            await coordinator.acquire(pid: pid, sessionID: session, operationID: queued)
        }
        await waitUntil { await coordinator.queuedOperationIDs(pid: pid) == [queued] }

        await coordinator.disconnect(sessionID: session)
        #expect(await queuedTask.value == .cancelled)
        #expect(
            await coordinator.acquire(pid: pid, sessionID: UUID(), operationID: UUID())
                == .busy(ownerSessionID: session))
        await coordinator.release(pid: pid, sessionID: session, operationID: owner)
    }

    @Test func duplicateOperationExecutesOnceAndSharesResult() async {
        let registry = DaemonOperationRegistry()
        let counter = AsyncCounter()
        let gate = AsyncGate()
        let operationID = UUID()
        let sessionID = UUID()
        let first = Task {
            await registry.run(
                operationID: operationID, sessionID: sessionID, requestFingerprint: "same"
            ) {
                await counter.increment()
                await gate.wait()
                return .text("once")
            }
        }
        await waitUntil { await counter.value == 1 }
        let duplicate = Task {
            await registry.run(
                operationID: operationID, sessionID: sessionID, requestFingerprint: "same"
            ) {
                await counter.increment()
                return .text("twice")
            }
        }
        await gate.open()
        #expect(resultText(await first.value) == "once")
        #expect(resultText(await duplicate.value) == "once")
        #expect(await counter.value == 1)
    }

    @Test func duplicateOperationRejectsDifferentRequest() async {
        let registry = DaemonOperationRegistry()
        let operationID = UUID()
        let sessionID = UUID()
        let original = await registry.run(
            operationID: operationID, sessionID: sessionID, requestFingerprint: "click:a"
        ) { .text("original") }
        let conflict = await registry.run(
            operationID: operationID, sessionID: sessionID, requestFingerprint: "click:b"
        ) { .text("must not execute") }

        #expect(resultText(original) == "original")
        #expect(conflict.isError == true)
        #expect(resultText(conflict).contains("OPERATION_CONFLICT"))
    }

    @Test func unexpiredDedupeCapacityNeverEvictsOldestMutation() async {
        let clock = LockedTestClock()
        let registry = DaemonOperationRegistry(
            maxRetainedOperations: 2, retention: 600, now: clock.now)
        let sessionID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let rejectedID = UUID()
        let executions = AsyncCounter()

        let first = await registry.run(
            operationID: firstID, sessionID: sessionID, requestFingerprint: "first"
        ) {
            await executions.increment()
            return .text("first")
        }
        _ = await registry.run(
            operationID: secondID, sessionID: sessionID, requestFingerprint: "second"
        ) {
            await executions.increment()
            return .text("second")
        }
        let oldestRetry = await registry.run(
            operationID: firstID, sessionID: sessionID, requestFingerprint: "first"
        ) {
            await executions.increment()
            return .text("replayed")
        }
        let capacity = await registry.run(
            operationID: rejectedID, sessionID: sessionID, requestFingerprint: "third"
        ) {
            await executions.increment()
            return .text("third")
        }

        #expect(resultText(first) == "first")
        #expect(resultText(oldestRetry) == "first")
        #expect(resultText(capacity).contains("DAEMON_CAPACITY"))
        #expect(capacity.isError == true)
        #expect(await executions.value == 2)

        clock.advance(seconds: 601)
        let afterExpiry = await registry.run(
            operationID: rejectedID, sessionID: sessionID, requestFingerprint: "third"
        ) {
            await executions.increment()
            return .text("third")
        }
        #expect(resultText(afterExpiry) == "third")
        #expect(await executions.value == 3)
    }

    @Test func completedReadsDoNotConsumeRetentionCapacity() async {
        let registry = DaemonOperationRegistry(maxRetainedOperations: 2)
        let sessionID = UUID()
        let executions = AsyncCounter()

        for index in 0..<10 {
            let result = await registry.run(
                operationID: UUID(), sessionID: sessionID,
                requestFingerprint: "read:\(index)", retainCompleted: false
            ) {
                await executions.increment()
                return .text("read:\(index)")
            }
            #expect(resultText(result) == "read:\(index)")
        }
        #expect(await executions.value == 10)
    }

    @Test func activeReadsRemainBoundedAndDeduplicateInFlight() async {
        let registry = DaemonOperationRegistry(maxRetainedOperations: 1)
        let sessionID = UUID()
        let operationID = UUID()
        let gate = AsyncGate()
        let started = AsyncGate()
        let executions = AsyncCounter()
        let first = Task {
            await registry.run(
                operationID: operationID, sessionID: sessionID,
                requestFingerprint: "read", retainCompleted: false
            ) {
                await executions.increment()
                await started.open()
                await gate.wait()
                return .text("shared")
            }
        }
        await started.wait()
        let duplicate = Task {
            await registry.run(
                operationID: operationID, sessionID: sessionID,
                requestFingerprint: "read", retainCompleted: false
            ) {
                await executions.increment()
                return .text("must not execute")
            }
        }
        let capacity = await registry.run(
            operationID: UUID(), sessionID: sessionID,
            requestFingerprint: "other-read", retainCompleted: false
        ) {
            .text("must not execute")
        }
        #expect(resultText(capacity).contains("DAEMON_CAPACITY"))
        await gate.open()
        #expect(resultText(await first.value) == "shared")
        #expect(resultText(await duplicate.value) == "shared")
        #expect(await executions.value == 1)

        let afterCompletion = await registry.run(
            operationID: UUID(), sessionID: sessionID,
            requestFingerprint: "after", retainCompleted: false
        ) {
            .text("after")
        }
        #expect(resultText(afterCompletion) == "after")
    }

    @Test func cancellationTombstonesRejectOverflowWithoutEvictingOldest() async {
        let clock = LockedTestClock()
        let registry = DaemonOperationRegistry(
            maxCancellationTombstones: 1, retention: 600, now: clock.now)
        let sessionID = UUID()
        let retainedID = UUID()

        #expect(
            await registry.cancel(operationID: retainedID, sessionID: sessionID) == .cancelled)
        #expect(
            await registry.cancel(operationID: UUID(), sessionID: sessionID) == .capacityExceeded)
        let retained = await registry.run(
            operationID: retainedID, sessionID: sessionID, requestFingerprint: "retained"
        ) {
            .text("must not execute")
        }
        #expect(resultText(retained).contains("CANCELLED"))
    }

    @Test func activeOperationCancellationReachesExecutionTask() async {
        let registry = DaemonOperationRegistry()
        let started = AsyncGate()
        let operationID = UUID()
        let sessionID = UUID()
        let task = Task {
            await registry.run(
                operationID: operationID, sessionID: sessionID, requestFingerprint: "slow"
            ) {
                await started.open()
                do {
                    try await Task.sleep(for: .seconds(30))
                    return .text("not cancelled")
                } catch {
                    return .text("cancelled")
                }
            }
        }
        await started.wait()
        #expect(
            await registry.cancel(operationID: operationID, sessionID: sessionID)
                == .cancellationRequested)
        #expect(resultText(await task.value) == "cancelled")
        let cached = await registry.run(
            operationID: operationID, sessionID: sessionID, requestFingerprint: "slow"
        ) {
            .text("must not execute")
        }
        #expect(resultText(cached) == "cancelled")
    }
}

private actor AsyncCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private final class LockedTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000)

    func now() -> Date {
        lock.withLock { date }
    }

    func advance(seconds: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(seconds) }
    }
}

private actor AsyncOrder {
    private(set) var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
}

private actor AsyncDouble {
    private(set) var value: Double?
    func set(_ value: Double?) { self.value = value }
}

private actor AsyncResult {
    private(set) var value: CallTool.Result?
    func set(_ value: CallTool.Result) { self.value = value }
}

private actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private func waitUntil(_ predicate: @escaping @Sendable () async -> Bool) async {
    for _ in 0..<100 {
        if await predicate() { return }
        await Task.yield()
    }
    Issue.record("condition was not reached")
}

private func resultText(_ result: CallTool.Result) -> String {
    guard case .text(let text, _, _)? = result.content.first else { return "" }
    return text
}

private func testDurationMilliseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000
        + Double(components.attoseconds) / 1_000_000_000_000_000
}
