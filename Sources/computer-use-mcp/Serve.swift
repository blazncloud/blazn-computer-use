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
        do {
            return try await spec.handler(params.arguments ?? [:])
        } catch {
            return .text("\(error)", isError: true)
        }
    }

    do {
        try await server.start(transport: StdioTransport())
    } catch {
        FileHandle.standardError.write(Data("Failed to start MCP server: \(error)\n".utf8))
        exit(1)
    }
    await server.waitUntilCompleted()
}
