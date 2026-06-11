// Wire protocol between serve shims and the engine daemon: newline-delimited
// JSON over a unix domain socket. One connection per agent session; the
// connection is the session identity for app leases.

import Foundation
import MCP

func daemonSocketPath() -> String {
    runtimeDirectory().appendingPathComponent("daemon.sock").path
}

func daemonLockPath() -> String {
    runtimeDirectory().appendingPathComponent("daemon.lock").path
}

func daemonLogPath() -> String {
    runtimeDirectory().appendingPathComponent("daemon.log").path
}

func runtimeDirectory() -> URL {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
    let directory = base.appendingPathComponent("computer-use-mcp", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

struct DaemonRequest: Codable {
    var id: Int
    /// "hello" (handshake), "shutdown", or a tool name.
    var method: String
    var arguments: [String: Value]?
    /// Shim version, sent with "hello" so a stale daemon can be replaced.
    var version: String?
}

struct DaemonResponse: Codable {
    var id: Int
    var isError: Bool?
    var content: [DaemonContent]?
    var version: String?
}

/// Tool.Content is not Codable in a stable wire shape; mirror the two kinds
/// this server produces.
struct DaemonContent: Codable {
    var type: String  // "text" | "image"
    var text: String?
    var data: String?  // base64
    var mimeType: String?

    static func from(_ content: Tool.Content) -> DaemonContent {
        switch content {
        case .text(let text, _, _):
            return DaemonContent(type: "text", text: text)
        case .image(let data, let mimeType, _, _):
            return DaemonContent(type: "image", data: data, mimeType: mimeType)
        default:
            return DaemonContent(type: "text", text: "[unsupported content type]")
        }
    }

    var asToolContent: Tool.Content {
        if type == "image", let data {
            return .image(data: data, mimeType: mimeType ?? "image/png", annotations: nil, _meta: nil)
        }
        return .text(text: text ?? "", annotations: nil, _meta: nil)
    }
}

extension DaemonResponse {
    static func from(_ result: CallTool.Result, id: Int) -> DaemonResponse {
        DaemonResponse(id: id, isError: result.isError, content: result.content.map(DaemonContent.from))
    }

    var asCallToolResult: CallTool.Result {
        .init(content: (content ?? []).map(\.asToolContent), isError: isError)
    }
}

/// Append one JSON line to a socket fd. Writes from concurrent responders are
/// serialized by the caller. Returns false when the peer is gone.
func writeJSONLine<T: Encodable>(_ value: T, to fd: Int32) -> Bool {
    guard var data = try? JSONEncoder().encode(value) else { return false }
    data.append(0x0A)
    return data.withUnsafeBytes { buffer in
        var sent = 0
        while sent < buffer.count {
            let n = write(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
            if n <= 0 { return false }
            sent += n
        }
        return true
    }
}
