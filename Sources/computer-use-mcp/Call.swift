// `call` — invoke a single tool from the shell, bypassing the MCP transport.
// The development and self-test harness:
//
//   computer-use-mcp call get_app_state '{"app": "Calculator"}'
//
// Text content prints to stdout; image content is written to a temp PNG and its
// path printed. Exits non-zero when the tool reports an error.

import Foundation
import MCP

func runCall(_ args: [String]) async {
    guard let toolName = args.first else {
        FileHandle.standardError.write(Data("Usage: computer-use-mcp call <tool> [<json-arguments>]\n".utf8))
        exit(2)
    }
    guard toolCatalog.contains(where: { $0.name == toolName }) else {
        let names = toolCatalog.map(\.name).joined(separator: ", ")
        FileHandle.standardError.write(Data("Unknown tool: \(toolName)\nAvailable tools: \(names)\n".utf8))
        exit(2)
    }

    var arguments: [String: Value] = [:]
    if args.count > 1 {
        do {
            arguments = try JSONDecoder().decode([String: Value].self, from: Data(args[1].utf8))
        } catch {
            FileHandle.standardError.write(Data("Arguments must be a JSON object: \(error)\n".utf8))
            exit(2)
        }
    }

    // Route through the shared daemon (same engine state as live agent
    // sessions); fall back to in-process if it cannot be reached.
    var result: CallTool.Result
    if Config.bool("no_daemon") != true {
        do {
            result = try await DaemonClient.shared.call(tool: toolName, arguments: arguments)
        } catch {
            FileHandle.standardError.write(Data("daemon unavailable (\(error)); running in-process\n".utf8))
            result = await dispatchTool(name: toolName, arguments: arguments)
        }
    } else {
        result = await dispatchTool(name: toolName, arguments: arguments)
    }

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
                    .appendingPathComponent("computer-use-mcp-\(toolName).\(ext)")
                try? data.write(to: url)
                print("[image \(mimeType), \(data.count) bytes] \(url.path)")
            } else {
                print("[image \(mimeType): invalid base64]")
            }
        default:
            print("[unsupported content type]")
        }
    }

    if result.isError == true {
        exit(1)
    }
}
