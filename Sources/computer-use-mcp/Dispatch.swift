// Shared tool dispatch — the one funnel every entry point (MCP serve, the
// daemon, the call harness) routes through: catalog lookup, optional rate
// limit, error capture, per-call logging.

import Foundation
import MCP

typealias DaemonToolCaller = @Sendable (String, [String: Value]) async throws -> CallTool.Result
typealias LocalToolDispatcher = @Sendable (String, [String: Value]) async -> CallTool.Result

func dispatchToolWithDaemonPolicy(
    name: String,
    arguments: [String: Value],
    useDaemon: Bool,
    daemonCall: DaemonToolCaller = { name, arguments in
        try await DaemonClient.shared.call(tool: name, arguments: arguments)
    },
    localDispatch: LocalToolDispatcher = dispatchTool
) async -> CallTool.Result {
    if useDaemon {
        do {
            return try await daemonCall(name, arguments)
        } catch {
            if isMutatingTool(name) {
                return .text(
                    "Engine daemon unavailable (\(error)); refusing to run mutating tool "
                        + "\"\(name)\" in-process. Set no_daemon / "
                        + "COMPUTER_USE_MCP_NO_DAEMON=1 to explicitly accept in-process dispatch.",
                    isError: true
                )
            }
            FileHandle.standardError.write(
                Data("[computer-use-mcp] daemon unavailable (\(error)); running read-only tool in-process\n".utf8)
            )
        }
    }
    return await localDispatch(name, arguments)
}

func dispatchTool(name: String, arguments: [String: Value]) async -> CallTool.Result {
    guard let spec = toolCatalog.first(where: { $0.name == name }) else {
        return .text("Unknown tool: \(name)", isError: true)
    }
    await RateLimiter.shared.acquire()
    let start = ContinuousClock.now
    await SleepAssertion.shared.noteActivity()
    if let refusal = await preflightRefusal(name: name, arguments: arguments) {
        logToolCall(name, isError: true, since: start)
        return .text(refusal, isError: true)
    }
    let result: CallTool.Result
    do {
        result = try await spec.handler(arguments)
    } catch {
        result = .text("\(error)", isError: true)
    }
    logToolCall(name, isError: result.isError == true, since: start)
    await Telemetry.shared.record(tool: name, isError: result.isError == true, since: start)
    return result
}

/// The gates every tool call passes before its handler runs: screen-lock
/// pause (mutating tools only), human-interference yield, and the browser
/// URL policy. Returns the first refusal message, or nil when clear to act.
private func preflightRefusal(name: String, arguments: [String: Value]) async -> String? {
    if let lockMessage = lockedScreenMessage(toolName: name, isLocked: screenIsLocked()) {
        return lockMessage
    }
    if let yieldMessage = await InterferenceGuard.waitForUserPause(toolName: name, arguments: arguments) {
        return yieldMessage
    }
    return URLPolicy.check(toolName: name, arguments: arguments)
}

/// Stderr per-call log line, enabled with COMPUTER_USE_MCP_LOG=1 (or "log" in
/// the config file). Stderr is safe on a stdio transport.
private func logToolCall(_ name: String, isError: Bool, since start: ContinuousClock.Instant) {
    guard Config.bool("log") == true else { return }
    let elapsed = start.duration(to: .now)
    let milliseconds = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
    FileHandle.standardError.write(
        Data("[computer-use-mcp] \(name) \(isError ? "error" : "ok") \(milliseconds)ms\n".utf8)
    )
}

/// Optional global action throttle ("max_actions_per_sec" /
/// COMPUTER_USE_MCP_MAX_ACTIONS_PER_SEC). Off by default; when set, tool
/// calls are spaced at least 1/n seconds apart as a runaway-agent backstop.
actor RateLimiter {
    static let shared = RateLimiter()
    private var lastCall: ContinuousClock.Instant?
    private let minimumInterval: Duration? = Config.double("max_actions_per_sec")
        .flatMap { $0 > 0 ? .seconds(1.0 / $0) : nil }

    func acquire() async {
        guard let minimumInterval else { return }
        let now = ContinuousClock.now
        if let lastCall, lastCall + minimumInterval > now {
            try? await Task.sleep(until: lastCall + minimumInterval)
            self.lastCall = lastCall + minimumInterval
        } else {
            lastCall = now
        }
    }
}
