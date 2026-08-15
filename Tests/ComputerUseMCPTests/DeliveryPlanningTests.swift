import Testing
import Foundation

@testable import computer_use_mcp

@Suite struct DeliveryPlanningTests {
    @Test func clickSelectsExactlyOneRouteFromPreflight() {
        #expect(clickDeliveryRoute(hasPressableElement: true) == .axPress)
        #expect(clickDeliveryRoute(hasPressableElement: false) == .synthetic)
    }

    @Test func textRouteIsChosenOnlyFromSettableCapabilities() {
        #expect(textDeliveryRoute(selectedTextSettable: true, valueSettable: true) == .selectedText)
        #expect(textDeliveryRoute(selectedTextSettable: false, valueSettable: true) == .valueSplice)
        #expect(textDeliveryRoute(selectedTextSettable: false, valueSettable: false) == .synthetic)
    }

    @Test func emptyTypeTextIsRejectedInsteadOfFalseVerified() {
        #expect(throws: (any Error).self) {
            try validateTypeTextArgument("")
        }
        #expect(throws: Never.self) {
            try validateTypeTextArgument("hello")
        }
    }

    @Test func verificationReadsImmediatelyAndAtDeadlineWithoutObserver() async {
        var reads = 0
        let immediate = await waitForDeliveryVerification(
            observer: nil, baselineRevision: nil, timeout: .zero,
            predicate: {
                reads += 1
                return true
            })
        #expect(immediate)
        #expect(reads == 1)

        reads = 0
        let final = await waitForDeliveryVerification(
            observer: nil, baselineRevision: nil, timeout: .zero,
            predicate: {
                reads += 1
                return reads == 2
            })
        #expect(final)
        #expect(reads == 2)
    }

    @Test func deliveryNotificationsWakeRereadsUntilTheExactPredicatePasses() async {
        let state = LockedTestState()
        let observer = ScriptedDeliveryObserver(changeCount: 2) { wake in
            if wake == 2 { state.setSatisfied() }
        }

        let verified = await waitForDeliveryVerification(
            observer: observer, baselineRevision: observer.revision,
            timeout: .seconds(1),
            predicate: {
                state.recordRead()
                return state.satisfied
            })

        #expect(verified)
        #expect(observer.waitCount == 2)
        #expect(observer.receivedBaselines == [0, 1])
        #expect(state.readCount == 3) // immediate + one read per wake
    }

    @Test func acknowledgedSingleClickNeverDispatchesASecondRoute() async {
        var axPresses = 0
        var syntheticClicks = 0
        let route = await deliverSelectedClick(
            hasPressableElement: true,
            axPress: {
                axPresses += 1
                return "ax"
            },
            synthetic: {
                syntheticClicks += 1
                return "synthetic"
            })

        #expect(route == "ax")
        #expect(axPresses == 1)
        #expect(syntheticClicks == 0)
    }
}

private final class LockedTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSatisfied = false
    private var storedReadCount = 0

    var satisfied: Bool {
        lock.withLock { storedSatisfied }
    }

    var readCount: Int {
        lock.withLock { storedReadCount }
    }

    func setSatisfied() {
        lock.withLock { storedSatisfied = true }
    }

    func recordRead() {
        lock.withLock { storedReadCount += 1 }
    }
}

private final class ScriptedDeliveryObserver: DeliveryChangeObserving, @unchecked Sendable {
    private let lock = NSLock()
    private let changeCount: Int
    private let onWake: @Sendable (Int) -> Void
    private var storedRevision: UInt64 = 0
    private var storedWaitCount = 0
    private var storedBaselines: [UInt64] = []

    init(changeCount: Int, onWake: @escaping @Sendable (Int) -> Void) {
        self.changeCount = changeCount
        self.onWake = onWake
    }

    var revision: UInt64 { lock.withLock { storedRevision } }
    var waitCount: Int { lock.withLock { storedWaitCount } }
    var receivedBaselines: [UInt64] { lock.withLock { storedBaselines } }

    func waitForChange(after baseline: UInt64, timeout: Duration) async -> Bool {
        let wake = lock.withLock { () -> Int? in
            storedBaselines.append(baseline)
            // Match the live observer: a stale baseline returns immediately
            // without consuming a new notification.
            guard baseline == storedRevision else { return 0 }
            guard storedWaitCount < changeCount else { return nil }
            storedWaitCount += 1
            storedRevision &+= 1
            return storedWaitCount
        }
        guard let wake else { return false }
        if wake == 0 { return true }
        try? await Task.sleep(for: .milliseconds(5))
        onWake(wake)
        return revision != baseline
    }
}
