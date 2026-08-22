// `call` — invoke a single tool from the shell, bypassing the MCP transport.
// The development and self-test harness:
//
//   computer-use-mcp call get_app_state '{"app": "Calculator"}'
//
// Text content prints to stdout; image content is written to a temp PNG and its
// path printed. Exits non-zero when the tool reports an error.

import Foundation
import MCP

struct CallInvocation {
    let toolName: String
    let arguments: [String: Value]
    let jsonOutput: Bool
}

private struct JSONCallEnvelope: Encodable {
    let schemaVersion = 1
    let tool: String
    let result: CallTool.Result
}

func parseCallInvocation(_ args: [String]) throws -> CallInvocation {
    let jsonOutput = args.contains("--json")
    let positional = args.filter { $0 != "--json" }
    guard let toolName = positional.first else {
        throw ToolError.failed("Usage: computer-use-mcp call [--json] <tool> [<json-arguments>]")
    }
    guard toolCatalog.contains(where: { $0.name == toolName }) else {
        let names = toolCatalog.map(\.name).joined(separator: ", ")
        throw ToolError.failed("Unknown tool: \(toolName)\nAvailable tools: \(names)")
    }
    guard positional.count <= 2 else {
        throw ToolError.failed("Usage: computer-use-mcp call [--json] <tool> [<json-arguments>]")
    }
    let arguments: [String: Value]
    if positional.count == 2 {
        do {
            arguments = try JSONDecoder().decode(
                [String: Value].self, from: Data(positional[1].utf8))
        } catch {
            throw ToolError.failed("Arguments must be a JSON object: \(error)")
        }
    } else {
        arguments = [:]
    }
    return CallInvocation(toolName: toolName, arguments: arguments, jsonOutput: jsonOutput)
}

func encodeJSONCallResult(toolName: String, result: CallTool.Result) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(JSONCallEnvelope(tool: toolName, result: result))
}

func runCall(_ args: [String]) async {
    let invocation: CallInvocation
    do {
        invocation = try parseCallInvocation(args)
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(2)
    }

    // Route through the shared daemon (same engine state as live agent
    // sessions). Daemon failures fail fast; tools never run in this process.
    let result = await dispatchToolThroughDaemon(
        name: invocation.toolName,
        arguments: invocation.arguments
    )

    if invocation.jsonOutput {
        do {
            let data = try encodeJSONCallResult(toolName: invocation.toolName, result: result)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("Failed to encode JSON result: \(error)\n".utf8))
            exit(2)
        }
    } else {
        for content in result.content {
            switch content {
            case .text(let text, _, _):
                print(text)
            case .image(let base64, let mimeType, _, _):
                if let data = Data(base64Encoded: base64) {
                    let ext = mimeType.split(separator: "/").last.map(String.init) ?? "bin"
                    // Stable name (no pid) so repeated calls overwrite rather than
                    // accumulate one temp file per invocation.
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("computer-use-mcp-\(invocation.toolName).\(ext)")
                    try? data.write(to: url)
                    print("[image \(mimeType), \(data.count) bytes] \(url.path)")
                } else {
                    print("[image \(mimeType): invalid base64]")
                }
            default:
                print("[unsupported content type]")
            }
        }

        // Opt-in _meta dump (COMPUTER_USE_MCP_SHOW_META=1): the focus / delivery /
        // outcome telemetry blocks are otherwise invisible on the CLI.
        if Config.bool("show_meta") == true, let fields = result._meta?.fields, !fields.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(fields), let json = String(data: data, encoding: .utf8) {
                print("_meta: \(json)")
            }
        }
    }

    if result.isError == true {
        exit(1)
    }
}
