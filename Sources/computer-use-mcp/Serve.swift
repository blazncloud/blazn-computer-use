// `serve` — run the MCP server over stdio. This is what MCP clients spawn.
//
// By default serve is a thin shim: tool calls are forwarded to the shared
// engine daemon (one per user, spawned on demand), so any number of
// concurrent agent sessions go through a single process that owns screen
// capture, accessibility, input delivery, and the cursor — collisions between
// sessions are impossible by construction. Set no_daemon /
// COMPUTER_USE_MCP_NO_DAEMON=1 to run the engine in-process instead.

import Foundation
import MCP

func runServe() async {
    let useDaemon = Config.bool("no_daemon") != true

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
        let arguments = params.arguments ?? [:]
        return await dispatchToolWithDaemonPolicy(name: params.name, arguments: arguments, useDaemon: useDaemon)
    }

    do {
        try await server.start(transport: StdioTransport())
    } catch {
        FileHandle.standardError.write(Data("Failed to start MCP server: \(error)\n".utf8))
        exit(1)
    }
    await server.waitUntilCompleted()
}
