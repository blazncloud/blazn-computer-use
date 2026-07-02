// In-process funnel telemetry: per-tool call/error/latency counters plus the
// perceive-to-act funnel (first get_app_state to first mutating tool call)
// for the current daemon lifetime.
//
// The daemon and `health_report` run in separate processes, so the metrics
// actor periodically persists a small JSON snapshot to the daemon runtime
// directory (throttled, best-effort, atomic) and `health_report` reads that
// file. "no_telemetry" / COMPUTER_USE_MCP_NO_TELEMETRY=1 disables recording.

import Foundation

/// Per-tool counters. The mean is derived from the total so only three
/// integers need to be stored and merged.
struct TelemetryCounter: Codable, Equatable {
    var calls: Int = 0
    var errors: Int = 0
    var totalMs: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case calls
        case errors
        case totalMs = "total_ms"
    }

    var meanMs: Double? {
        calls > 0 ? Double(totalMs) / Double(calls) : nil
    }
}

/// Pure counter state: per-tool tallies plus the global perceive-to-act
/// funnel. Kept as a value type with an injected `now` so the math is
/// testable without the actor or a real clock.
struct TelemetryCounters: Equatable {
    private(set) var tools: [String: TelemetryCounter] = [:]
    private(set) var firstPerceiveAt: Date?
    private(set) var firstActAt: Date?

    private static let perceiveToolName = "get_app_state"

    mutating func record(tool: String, isError: Bool, milliseconds: Int64, at now: Date) {
        var counter = tools[tool] ?? TelemetryCounter()
        counter.calls += 1
        if isError {
            counter.errors += 1
        }
        counter.totalMs += milliseconds
        tools[tool] = counter

        if tool == Self.perceiveToolName, firstPerceiveAt == nil {
            firstPerceiveAt = now
        }
        // First act = first mutating tool call after the first perceive,
        // whether or not it succeeded (an errored click is still an attempt
        // to act).
        if isMutatingTool(tool), firstPerceiveAt != nil, firstActAt == nil {
            firstActAt = now
        }
    }

    var firstPerceiveToFirstActSeconds: Double? {
        guard let firstPerceiveAt, let firstActAt else { return nil }
        return firstActAt.timeIntervalSince(firstPerceiveAt)
    }
}

/// Decides whether a snapshot write is due: at most one write per interval,
/// measured on an injected instant so the decision is testable.
struct TelemetrySnapshotThrottle {
    let interval: Duration
    private(set) var lastWrite: ContinuousClock.Instant?

    mutating func shouldWrite(now: ContinuousClock.Instant) -> Bool {
        if let lastWrite, lastWrite + interval > now {
            return false
        }
        lastWrite = now
        return true
    }
}

/// The on-disk snapshot the daemon persists and `health_report` reads.
struct TelemetrySnapshot: Codable, Equatable {
    var writtenAt: Date
    var startedAt: Date
    var tools: [String: TelemetryCounter]
    var firstPerceiveAt: Date?
    var firstActAt: Date?

    enum CodingKeys: String, CodingKey {
        case writtenAt = "written_at"
        case startedAt = "started_at"
        case tools
        case firstPerceiveAt = "first_perceive_at"
        case firstActAt = "first_act_at"
    }

    var uptimeSeconds: Double {
        max(0, writtenAt.timeIntervalSince(startedAt))
    }

    var firstPerceiveToFirstActSeconds: Double? {
        guard let firstPerceiveAt, let firstActAt else { return nil }
        return firstActAt.timeIntervalSince(firstPerceiveAt)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> TelemetrySnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(TelemetrySnapshot.self, from: data)
    }

    static func read(atPath path: String) -> TelemetrySnapshot? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? decode(data)
    }
}

func telemetrySnapshotPath(createRuntimeDirectory: Bool = false) -> String {
    URL(fileURLWithPath: daemonRuntimePaths(createRuntimeDirectory: createRuntimeDirectory).directory)
        .appendingPathComponent("telemetry.json").path
}

/// The metrics actor behind the dispatch funnel. Recording is in-memory;
/// a snapshot is persisted at most once per `snapshotInterval` so a busy
/// daemon does not turn every tool call into a disk write.
actor Telemetry {
    static let shared = Telemetry()
    static let snapshotInterval: Duration = .seconds(15)

    private let disabled: Bool
    private let startedAt = Date()
    private var counters = TelemetryCounters()
    private var throttle = TelemetrySnapshotThrottle(interval: Telemetry.snapshotInterval)

    init(disabled: Bool = Config.bool("no_telemetry") == true) {
        self.disabled = disabled
    }

    func record(tool: String, isError: Bool, since start: ContinuousClock.Instant) {
        guard !disabled else { return }
        let elapsed = start.duration(to: .now)
        let milliseconds =
            elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        counters.record(tool: tool, isError: isError, milliseconds: milliseconds, at: Date())
        guard throttle.shouldWrite(now: .now) else { return }
        writeSnapshot()
    }

    /// Best-effort atomic write; telemetry must never fail a tool call.
    private func writeSnapshot() {
        let snapshot = TelemetrySnapshot(
            writtenAt: Date(),
            startedAt: startedAt,
            tools: counters.tools,
            firstPerceiveAt: counters.firstPerceiveAt,
            firstActAt: counters.firstActAt
        )
        guard let data = try? snapshot.encoded() else { return }
        let url = URL(fileURLWithPath: telemetrySnapshotPath(createRuntimeDirectory: true))
        try? data.write(to: url, options: .atomic)
    }
}
