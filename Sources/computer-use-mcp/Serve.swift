// `serve` — run the MCP server over stdio. This is what MCP clients spawn.

import Foundation
import MCP

func runServe() async {
    let server = Server(
        name: "computer-use-mcp",
        version: version,
        capabilities: .init(tools: .init(listChanged: false))
    )

    await server.withMethodHandler(ListTools.self) { _ in
        .init(
            tools: toolCatalog.map {
                Tool(name: $0.name, description: $0.description, inputSchema: $0.inputSchema)
            }
        )
    }

    await server.withMethodHandler(CallTool.self) { params in
        guard let spec = toolCatalog.first(where: { $0.name == params.name }) else {
            return .text("Unknown tool: \(params.name)", isError: true)
        }
        await RateLimiter.shared.acquire()
        let start = ContinuousClock.now
        let result: CallTool.Result
        do {
            result = try await spec.handler(params.arguments ?? [:])
        } catch {
            result = .text("\(error)", isError: true)
        }
        logToolCall(params.name, isError: result.isError == true, since: start)
        return result
    }

    do {
        try await server.start(transport: StdioTransport())
    } catch {
        FileHandle.standardError.write(Data("Failed to start MCP server: \(error)\n".utf8))
        exit(1)
    }
    await server.waitUntilCompleted()
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
