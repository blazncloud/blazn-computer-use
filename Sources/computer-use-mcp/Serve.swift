// `serve` — run the MCP server over stdio. This is what MCP clients spawn.
//
// By default serve is a thin shim: tool calls are forwarded to the shared
// engine daemon (one per user, spawned on demand), so any number of
// concurrent agent sessions go through a single process that owns screen
// capture, accessibility, input delivery, and the cursor.

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
            tools: toolCatalog.map(\.tool)
        )
    }

    await server.withMethodHandler(CallTool.self) { params in
        let arguments = params.arguments ?? [:]
        return await dispatchToolThroughDaemon(name: params.name, arguments: arguments)
    }

    do {
        try await server.start(transport: StdioTransport())
    } catch {
        FileHandle.standardError.write(Data("Failed to start MCP server: \(error)\n".utf8))
        exit(1)
    }
    await server.waitUntilCompleted()
}
