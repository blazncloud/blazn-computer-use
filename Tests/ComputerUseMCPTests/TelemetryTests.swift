import Foundation
import Testing

@testable import computer_use_mcp

@Suite struct TelemetryTests {
    private let epoch = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: Counter math

    @Test func countersAccumulateCallsErrorsAndLatency() {
        var counters = TelemetryCounters()
        counters.record(tool: "click", isError: false, milliseconds: 40, at: epoch)
        counters.record(tool: "click", isError: true, milliseconds: 20, at: epoch)
        counters.record(tool: "find", isError: false, milliseconds: 5, at: epoch)

        #expect(counters.tools["click"] == TelemetryCounter(calls: 2, errors: 1, totalMs: 60))
        #expect(counters.tools["find"] == TelemetryCounter(calls: 1, errors: 0, totalMs: 5))
        #expect(counters.tools["scroll"] == nil)
    }

    @Test func meanIsDerivedFromTotalLatency() {
        let counter = TelemetryCounter(calls: 4, errors: 1, totalMs: 100)

        #expect(counter.meanMs == 25)
    }

    @Test func meanIsNilBeforeAnyCalls() {
        #expect(TelemetryCounter().meanMs == nil)
    }

    // MARK: Funnel

    @Test func funnelRecordsFirstPerceiveThenFirstAct() {
        var counters = TelemetryCounters()
        counters.record(tool: "get_app_state", isError: false, milliseconds: 10, at: epoch)
        counters.record(tool: "get_app_state", isError: false, milliseconds: 10, at: epoch + 5)
        counters.record(tool: "click", isError: false, milliseconds: 10, at: epoch + 12)
        counters.record(tool: "click", isError: false, milliseconds: 10, at: epoch + 90)

        #expect(counters.firstPerceiveAt == epoch)
        #expect(counters.firstActAt == epoch + 12)
        #expect(counters.firstPerceiveToFirstActSeconds == 12)
    }

    @Test func mutatingCallBeforeAnyPerceiveDoesNotStartFunnel() {
        var counters = TelemetryCounters()
        counters.record(tool: "click", isError: false, milliseconds: 10, at: epoch)

        #expect(counters.firstActAt == nil)
        #expect(counters.firstPerceiveToFirstActSeconds == nil)

        counters.record(tool: "get_app_state", isError: false, milliseconds: 10, at: epoch + 1)
        counters.record(tool: "type_text", isError: false, milliseconds: 10, at: epoch + 3)

        #expect(counters.firstPerceiveToFirstActSeconds == 2)
    }

    @Test func nonMutatingToolsNeverCountAsActs() {
        var counters = TelemetryCounters()
        counters.record(tool: "get_app_state", isError: false, milliseconds: 10, at: epoch)
        counters.record(tool: "find", isError: false, milliseconds: 10, at: epoch + 4)
        counters.record(tool: "read_text", isError: false, milliseconds: 10, at: epoch + 8)

        #expect(counters.firstActAt == nil)
        #expect(counters.firstPerceiveToFirstActSeconds == nil)
    }

    // MARK: Throttle

    @Test func throttleAllowsFirstWriteThenBlocksWithinInterval() {
        var throttle = TelemetrySnapshotThrottle(interval: .seconds(15))
        let base = ContinuousClock.now

        let first = throttle.shouldWrite(now: base)
        let afterOneSecond = throttle.shouldWrite(now: base + .seconds(1))
        let justInsideInterval = throttle.shouldWrite(now: base + .seconds(14))

        #expect(first)
        #expect(!afterOneSecond)
        #expect(!justInsideInterval)
    }

    @Test func throttleAllowsWriteOnceIntervalHasElapsed() {
        var throttle = TelemetrySnapshotThrottle(interval: .seconds(15))
        let base = ContinuousClock.now

        let first = throttle.shouldWrite(now: base)
        let blocked = throttle.shouldWrite(now: base + .seconds(14))
        let atInterval = throttle.shouldWrite(now: base + .seconds(15))
        // The blocked attempt at +14s must not have reset the window.
        let justAfterSecondWrite = throttle.shouldWrite(now: base + .seconds(16))
        let nextIntervalLater = throttle.shouldWrite(now: base + .seconds(30))

        #expect(first)
        #expect(!blocked)
        #expect(atInterval)
        #expect(!justAfterSecondWrite)
        #expect(nextIntervalLater)
    }

    // MARK: Snapshot round trip

    @Test func snapshotRoundTripsThroughJSON() throws {
        let snapshot = TelemetrySnapshot(
            writtenAt: epoch + 120,
            startedAt: epoch,
            tools: [
                "click": TelemetryCounter(calls: 3, errors: 1, totalMs: 90),
                "get_app_state": TelemetryCounter(calls: 2, errors: 0, totalMs: 400),
            ],
            firstPerceiveAt: epoch + 10,
            firstActAt: epoch + 25
        )

        let decoded = try TelemetrySnapshot.decode(snapshot.encoded())

        #expect(decoded == snapshot)
        #expect(decoded.uptimeSeconds == 120)
        #expect(decoded.firstPerceiveToFirstActSeconds == 15)
    }

    @Test func snapshotRoundTripsWithoutFunnelObservations() throws {
        let snapshot = TelemetrySnapshot(
            writtenAt: epoch,
            startedAt: epoch,
            tools: [:],
            firstPerceiveAt: nil,
            firstActAt: nil
        )

        let decoded = try TelemetrySnapshot.decode(snapshot.encoded())

        #expect(decoded == snapshot)
        #expect(decoded.firstPerceiveToFirstActSeconds == nil)
    }

    // MARK: Health-report shape

    @Test func telemetryReportDerivesMeansAndAge() throws {
        let snapshot = TelemetrySnapshot(
            writtenAt: epoch + 100,
            startedAt: epoch,
            tools: ["click": TelemetryCounter(calls: 4, errors: 2, totalMs: 100)],
            firstPerceiveAt: nil,
            firstActAt: nil
        )

        let report = TelemetryReport(snapshot: snapshot, path: "/tmp/telemetry.json", now: epoch + 103)

        #expect(report.snapshotAgeSeconds == 3)
        #expect(report.uptimeSeconds == 100)
        #expect(report.tools["click"]?.calls == 4)
        #expect(report.tools["click"]?.errors == 2)
        #expect(report.tools["click"]?.meanMs == 25)
        #expect(report.firstPerceiveToFirstActSeconds == nil)

        // An unobserved funnel is an explicit null in the JSON, not a missing key.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(report), as: UTF8.self)
        #expect(json.contains("\"first_perceive_to_first_act_seconds\":null"))
        #expect(json.contains("\"mean_ms\":25"))
    }
}
