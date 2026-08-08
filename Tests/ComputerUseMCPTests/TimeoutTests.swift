import Testing

@testable import computer_use_mcp

@Suite struct TimeoutTests {
    /// Regression guard for a cold ScreenCaptureKit/replayd capture that can
    /// suspend forever and ignore
    /// cancellation. withTimeout must still return by its deadline instead of
    /// waiting on the wedged operation (the old task-group form implicitly
    /// awaited the un-cancellable child and hung indefinitely).
    @Test func boundsAnUncancellableOperation() async {
        let start = ContinuousClock.now
        var threw = false
        do {
            _ = try await withTimeout(seconds: 0.2, label: "wedged") { () -> Int in
                // Never resumed, never observes cancellation — stands in for a
                // wedged replayd handshake.
                await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
                return 0
            }
        } catch {
            threw = true
        }
        let elapsed = start.duration(to: .now)
        #expect(threw)
        #expect(elapsed < .seconds(3))
    }

    /// A fast operation returns its value and is not penalized by the deadline.
    @Test func returnsResultBeforeDeadline() async throws {
        let value = try await withTimeout(seconds: 5, label: "fast") { 42 }
        #expect(value == 42)
    }

    /// An operation that throws before the deadline surfaces its own error, not
    /// the timeout.
    @Test func propagatesOperationError() async {
        struct Marker: Error {}
        await #expect(throws: Marker.self) {
            try await withTimeout(seconds: 5, label: "throwing") { () -> Int in throw Marker() }
        }
    }
}
