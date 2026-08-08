import Dispatch
import Foundation
import MCP

let metricsMetaKey = "computer-use-mcp/metrics"
private let metricsSchemaVersion = 1

/// Privacy-safe, daemon-wide operational metrics. This schema intentionally has
/// no fields for accessibility labels/values, screenshots, tree text, typed
/// text, URLs, window titles, or other user content.
struct OperationMetric: Codable, Equatable, Sendable {
  let operation: String
  let tool: String
  let appBundleIdentifier: String?
  let axRole: String?
  let attemptedDeliveryStrategies: [String]
  let finalDeliveryStrategy: String?
  let effectOutcome: String?
  let queueLatencyMs: Int64
  let executionLatencyMs: Int64

  enum CodingKeys: String, CodingKey {
    case operation
    case tool
    case appBundleIdentifier = "app_bundle_identifier"
    case axRole = "ax_role"
    case attemptedDeliveryStrategies = "attempted_delivery_strategies"
    case finalDeliveryStrategy = "final_delivery_strategy"
    case effectOutcome = "effect_outcome"
    case queueLatencyMs = "queue_latency_ms"
    case executionLatencyMs = "execution_latency_ms"
  }

  init(
    operation: String,
    tool: String,
    appBundleIdentifier: String?,
    axRole: String?,
    attemptedDeliveryStrategies: [String],
    finalDeliveryStrategy: String?,
    effectOutcome: String?,
    queueLatencyMs: Int64,
    executionLatencyMs: Int64
  ) {
    self.operation = safeMetricDimension(operation)
    self.tool = safeMetricDimension(tool)
    self.appBundleIdentifier = appBundleIdentifier.map(safeMetricDimension)
    self.axRole = axRole.map(safeMetricDimension)
    self.attemptedDeliveryStrategies = attemptedDeliveryStrategies.map(safeMetricDimension)
    self.finalDeliveryStrategy = finalDeliveryStrategy.map(safeMetricDimension)
    self.effectOutcome = effectOutcome.map(safeMetricDimension)
    self.queueLatencyMs = max(0, queueLatencyMs)
    self.executionLatencyMs = max(0, executionLatencyMs)
  }
}

struct PerceptionMetric: Codable, Equatable, Sendable {
  let operation: String
  let tool: String
  let appBundleIdentifier: String?
  let elapsedMs: Int64
  let elementsVisited: Int
  let elementsReturned: Int
  let partial: Bool
  let diff: Bool
  let contextBytes: Int

  enum CodingKeys: String, CodingKey {
    case operation
    case tool
    case appBundleIdentifier = "app_bundle_identifier"
    case elapsedMs = "elapsed_ms"
    case elementsVisited = "elements_visited"
    case elementsReturned = "elements_returned"
    case partial
    case diff
    case contextBytes = "context_bytes"
  }

  init(
    operation: String,
    tool: String,
    appBundleIdentifier: String?,
    elapsedMs: Int64,
    elementsVisited: Int,
    elementsReturned: Int,
    partial: Bool,
    diff: Bool,
    contextBytes: Int
  ) {
    self.operation = safeMetricDimension(operation)
    self.tool = safeMetricDimension(tool)
    self.appBundleIdentifier = appBundleIdentifier.map(safeMetricDimension)
    self.elapsedMs = max(0, elapsedMs)
    self.elementsVisited = max(0, elementsVisited)
    self.elementsReturned = max(0, elementsReturned)
    self.partial = partial
    self.diff = diff
    self.contextBytes = max(0, contextBytes)
  }
}

extension OperationMetric {
  var value: Value {
    var fields: [String: Value] = [
      "operation": .string(operation),
      "tool": .string(tool),
      "attempted_delivery_strategies": .array(
        attemptedDeliveryStrategies.map(Value.string)),
      "queue_latency_ms": .int(Int(clamping: queueLatencyMs)),
      "execution_latency_ms": .int(Int(clamping: executionLatencyMs)),
    ]
    if let appBundleIdentifier {
      fields["app_bundle_identifier"] = .string(appBundleIdentifier)
    }
    if let axRole { fields["ax_role"] = .string(axRole) }
    if let finalDeliveryStrategy {
      fields["final_delivery_strategy"] = .string(finalDeliveryStrategy)
    }
    if let effectOutcome { fields["effect_outcome"] = .string(effectOutcome) }
    return .object(fields)
  }
}

extension PerceptionMetric {
  var value: Value {
    var fields: [String: Value] = [
      "operation": .string(operation),
      "tool": .string(tool),
      "elapsed_ms": .int(Int(clamping: elapsedMs)),
      "elements_visited": .int(elementsVisited),
      "elements_returned": .int(elementsReturned),
      "partial": .bool(partial),
      "diff": .bool(diff),
      "context_bytes": .int(contextBytes),
    ]
    if let appBundleIdentifier {
      fields["app_bundle_identifier"] = .string(appBundleIdentifier)
    }
    return .object(fields)
  }
}

extension CallTool.Result {
  func withOperationMetric(_ metric: OperationMetric) -> CallTool.Result {
    withMetric("operation", value: metric.value)
  }

  func withPerceptionMetric(_ metric: PerceptionMetric) -> CallTool.Result {
    withMetric("perception", value: metric.value)
  }

  private func withMetric(_ name: String, value: Value) -> CallTool.Result {
    var envelope: [String: Value]
    if case .object(let existing)? = _meta?[metricsMetaKey] {
      envelope = existing
    } else {
      envelope = [:]
    }
    envelope["schema_version"] = .int(metricsSchemaVersion)
    envelope[name] = value
    return mergingMetaField(metricsMetaKey, .object(envelope))
  }
}

private func safeMetricDimension(_ value: String) -> String {
  guard !value.isEmpty, value.utf8.count <= 128,
    value.unicodeScalars.allSatisfy({
      CharacterSet.alphanumerics.contains($0) || "._:-".unicodeScalars.contains($0)
    })
  else {
    return "unknown"
  }
  return value
}

enum MetricsEventPayload: Equatable, Sendable {
  case operation(OperationMetric)
  case perception(PerceptionMetric)
}

struct MetricsEvent: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let timestamp: Date
  let payload: MetricsEventPayload

  init(timestamp: Date = Date(), payload: MetricsEventPayload) {
    schemaVersion = 1
    self.timestamp = timestamp
    self.payload = payload
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case timestamp
    case type
    case operation
    case perception
  }

  private enum EventType: String, Codable {
    case operation
    case perception
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    timestamp = try container.decode(Date.self, forKey: .timestamp)
    switch try container.decode(EventType.self, forKey: .type) {
    case .operation:
      payload = .operation(try container.decode(OperationMetric.self, forKey: .operation))
    case .perception:
      payload = .perception(try container.decode(PerceptionMetric.self, forKey: .perception))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(timestamp, forKey: .timestamp)
    switch payload {
    case .operation(let metric):
      try container.encode(EventType.operation, forKey: .type)
      try container.encode(metric, forKey: .operation)
    case .perception(let metric):
      try container.encode(EventType.perception, forKey: .type)
      try container.encode(metric, forKey: .perception)
    }
  }
}

struct MetricCounter: Codable, Equatable, Sendable {
  var count = 0
  var total = 0

  mutating func record(_ value: Int) {
    count += 1
    total += value
  }
}

struct MetricsAggregateSnapshot: Codable, Equatable, Sendable {
  var schemaVersion = 1
  var updatedAt: Date
  var events = 0
  var operations = 0
  var perceptions = 0
  var tools: [String: Int] = [:]
  var appBundleIdentifiers: [String: Int] = [:]
  var axRoles: [String: Int] = [:]
  var attemptedDeliveryStrategies: [String: Int] = [:]
  var finalDeliveryStrategies: [String: Int] = [:]
  var effectOutcomes: [String: Int] = [:]
  var queueLatencyMs = MetricCounter()
  var executionLatencyMs = MetricCounter()
  var perceptionLatencyMs = MetricCounter()
  var elementsVisited = MetricCounter()
  var elementsReturned = MetricCounter()
  var partialPerceptions = 0
  var diffPerceptions = 0
  var contextBytes = MetricCounter()

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case updatedAt = "updated_at"
    case events
    case operations
    case perceptions
    case tools
    case appBundleIdentifiers = "app_bundle_identifiers"
    case axRoles = "ax_roles"
    case attemptedDeliveryStrategies = "attempted_delivery_strategies"
    case finalDeliveryStrategies = "final_delivery_strategies"
    case effectOutcomes = "effect_outcomes"
    case queueLatencyMs = "queue_latency_ms"
    case executionLatencyMs = "execution_latency_ms"
    case perceptionLatencyMs = "perception_latency_ms"
    case elementsVisited = "elements_visited"
    case elementsReturned = "elements_returned"
    case partialPerceptions = "partial_perceptions"
    case diffPerceptions = "diff_perceptions"
    case contextBytes = "context_bytes"
  }

  init(updatedAt: Date = Date()) {
    self.updatedAt = updatedAt
  }

  mutating func record(_ event: MetricsEvent) {
    updatedAt = event.timestamp
    events += 1
    switch event.payload {
    case .operation(let metric):
      operations += 1
      increment(metric.tool, in: &tools)
      metric.appBundleIdentifier.map { increment($0, in: &appBundleIdentifiers) }
      metric.axRole.map { increment($0, in: &axRoles) }
      for strategy in metric.attemptedDeliveryStrategies {
        increment(strategy, in: &attemptedDeliveryStrategies)
      }
      metric.finalDeliveryStrategy.map { increment($0, in: &finalDeliveryStrategies) }
      metric.effectOutcome.map { increment($0, in: &effectOutcomes) }
      queueLatencyMs.record(clampedInt(metric.queueLatencyMs))
      executionLatencyMs.record(clampedInt(metric.executionLatencyMs))
    case .perception(let metric):
      perceptions += 1
      increment(metric.tool, in: &tools)
      metric.appBundleIdentifier.map { increment($0, in: &appBundleIdentifiers) }
      perceptionLatencyMs.record(clampedInt(metric.elapsedMs))
      elementsVisited.record(max(0, metric.elementsVisited))
      elementsReturned.record(max(0, metric.elementsReturned))
      partialPerceptions += metric.partial ? 1 : 0
      diffPerceptions += metric.diff ? 1 : 0
      contextBytes.record(max(0, metric.contextBytes))
    }
  }
}

private func increment(_ key: String, in values: inout [String: Int]) {
  values[key, default: 0] += 1
}

private func clampedInt(_ value: Int64) -> Int {
  Int(clamping: max(0, value))
}

struct MetricsRecorderConfiguration: Sendable {
  let eventsPath: String
  let summaryPath: String
  let maxFileBytes: Int
  let retainedFiles: Int
  let batchSize: Int
  let flushIntervalMilliseconds: Int
  let enabled: Bool

  static func runtime(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    arguments: [String] = CommandLine.arguments,
    productionDirectory: @autoclosure () -> String = daemonRuntimePaths(
      createRuntimeDirectory: true
    ).directory
  ) -> MetricsRecorderConfiguration {
    let enabled = arguments.dropFirst().first == "daemon"
      && !isMetricsTestProcess(environment: environment, arguments: arguments)
    let directory: String
    if enabled {
      directory = productionDirectory()
    } else {
      // Never resolve, create, chmod, or read the production runtime directory
      // from a test process. The disabled recorder will not create this inert
      // path either.
      directory =
        FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "computer-use-mcp-disabled-metrics-\(ProcessInfo.processInfo.processIdentifier)",
          isDirectory: true
        ).path
    }
    return MetricsRecorderConfiguration(
      eventsPath: URL(fileURLWithPath: directory).appendingPathComponent("metrics.jsonl").path,
      summaryPath: URL(fileURLWithPath: directory).appendingPathComponent("metrics-summary.json")
        .path,
      maxFileBytes: 1_048_576,
      retainedFiles: 3,
      batchSize: 32,
      flushIntervalMilliseconds: 250,
      enabled: enabled
    )
  }
}

/// Swift Testing runs inside an XCTest bundle. Explicitly constructed
/// recorders remain enabled for persistence tests; the process-level recorder
/// writes only in the daemon process.
func isMetricsTestProcess(environment: [String: String], arguments: [String]) -> Bool {
  if environment["XCTestConfigurationFilePath"] != nil
    || environment["XCTestBundlePath"] != nil
    || environment["SWIFT_TESTING_ENABLED"] != nil
  {
    return true
  }
  return arguments.first.map { URL(fileURLWithPath: $0).pathExtension == "xctest" } ?? false
}

actor MetricsRecorder {
  static let shared = MetricsRecorder(configuration: .runtime())

  private let configuration: MetricsRecorderConfiguration
  private let writer: MetricsFileWriter
  private var aggregate: MetricsAggregateSnapshot
  private var bufferedEvents: [MetricsEvent] = []
  private var flushTask: Task<Void, Never>?
  private var timerTask: Task<Void, Never>?
  private var timerGeneration: UInt64 = 0

  init(configuration: MetricsRecorderConfiguration) {
    self.configuration = configuration
    let writer = MetricsFileWriter()
    self.writer = writer
    aggregate =
      configuration.enabled
      ? writer.readSummary(atPath: configuration.summaryPath)
        ?? MetricsAggregateSnapshot()
      : MetricsAggregateSnapshot()
  }

  func record(_ event: MetricsEvent) {
    guard configuration.enabled else { return }
    bufferedEvents.append(event)
    aggregate.record(event)
    if bufferedEvents.count >= max(1, configuration.batchSize) {
      timerTask?.cancel()
      timerTask = nil
      beginFlushIfNeeded()
    } else {
      scheduleTimerIfNeeded()
    }
  }

  /// Persist every event accepted before this call returns. Intended for
  /// deterministic tests and reliable daemon shutdown points.
  func flush() async {
    guard configuration.enabled else { return }
    timerTask?.cancel()
    timerTask = nil
    while true {
      if let active = flushTask {
        await active.value
        continue
      }
      guard !bufferedEvents.isEmpty else { return }
      beginFlushIfNeeded()
    }
  }

  func snapshot() -> MetricsAggregateSnapshot {
    aggregate
  }

  private func beginFlushIfNeeded() {
    guard flushTask == nil, !bufferedEvents.isEmpty else { return }
    let events = bufferedEvents
    bufferedEvents.removeAll(keepingCapacity: true)
    let aggregate = aggregate
    let configuration = configuration
    let writer = writer
    flushTask = Task {
      await writer.persist(events: events, aggregate: aggregate, configuration: configuration)
      self.flushFinished()
    }
  }

  private func flushFinished() {
    flushTask = nil
    if bufferedEvents.count >= max(1, configuration.batchSize) {
      beginFlushIfNeeded()
    } else {
      scheduleTimerIfNeeded()
    }
  }

  private func scheduleTimerIfNeeded() {
    guard timerTask == nil, flushTask == nil, !bufferedEvents.isEmpty else { return }
    timerGeneration &+= 1
    let generation = timerGeneration
    let delay = max(1, configuration.flushIntervalMilliseconds)
    timerTask = Task {
      try? await Task.sleep(for: .milliseconds(delay))
      guard !Task.isCancelled else { return }
      self.timerFired(generation: generation)
    }
  }

  private func timerFired(generation: UInt64) {
    guard generation == timerGeneration else { return }
    timerTask = nil
    beginFlushIfNeeded()
  }
}

/// Daemon-owned disk writer. Every Foundation file operation runs on this
/// private serial queue, never on the MetricsRecorder actor executor.
private final class MetricsFileWriter: @unchecked Sendable {
  private let queue = DispatchQueue(label: "computer-use-mcp.metrics-writer")

  func readSummary(atPath path: String) -> MetricsAggregateSnapshot? {
    queue.sync { MetricsAggregateSnapshot.read(atPath: path) }
  }

  func persist(
    events: [MetricsEvent],
    aggregate: MetricsAggregateSnapshot,
    configuration: MetricsRecorderConfiguration
  ) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      queue.async {
        defer { continuation.resume() }
        do {
          let encoder = JSONEncoder()
          encoder.dateEncodingStrategy = .secondsSince1970
          encoder.outputFormatting = [.sortedKeys]
          for event in events {
            var line = try encoder.encode(event)
            line.append(0x0A)
            try self.rotateIfNeeded(addingBytes: line.count, configuration: configuration)
            try self.append(line, atPath: configuration.eventsPath)
          }
          try aggregate.write(toPath: configuration.summaryPath)
        } catch {
          // Metrics are best effort and must never fail a tool operation.
        }
      }
    }
  }

  private func append(_ data: Data, atPath path: String) throws {
    let manager = FileManager.default
    let url = URL(fileURLWithPath: path)
    try manager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !manager.fileExists(atPath: path) {
      try data.write(to: url, options: .atomic)
      return
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
  }

  private func rotateIfNeeded(
    addingBytes: Int, configuration: MetricsRecorderConfiguration
  ) throws {
    let manager = FileManager.default
    let path = configuration.eventsPath
    let currentSize =
      (try? manager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
    guard currentSize > 0, currentSize + addingBytes > max(1, configuration.maxFileBytes)
    else { return }

    if configuration.retainedFiles <= 0 {
      try? manager.removeItem(atPath: path)
      return
    }
    try? manager.removeItem(atPath: "\(path).\(configuration.retainedFiles)")
    if configuration.retainedFiles > 1 {
      for index in stride(from: configuration.retainedFiles - 1, through: 1, by: -1) {
        let source = "\(path).\(index)"
        let destination = "\(path).\(index + 1)"
        if manager.fileExists(atPath: source) {
          try manager.moveItem(atPath: source, toPath: destination)
        }
      }
    }
    try manager.moveItem(atPath: path, toPath: "\(path).1")
  }
}

extension MetricsAggregateSnapshot {
  static func read(atPath path: String) -> MetricsAggregateSnapshot? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return try? decoder.decode(MetricsAggregateSnapshot.self, from: data)
  }

  func write(toPath path: String) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(self).write(to: url, options: .atomic)
  }
}

func operationMetricsSummaryPath(createRuntimeDirectory: Bool = false) -> String {
  URL(
    fileURLWithPath: daemonRuntimePaths(
      createRuntimeDirectory: createRuntimeDirectory
    ).directory
  ).appendingPathComponent("metrics-summary.json").path
}
