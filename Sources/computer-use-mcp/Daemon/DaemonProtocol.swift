// Wire protocol between serve shims and the engine daemon: newline-delimited
// JSON over a unix domain socket. One connection per agent session; the
// connection is the session identity for app leases.

import Foundation
import Security
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

func daemonSecretPath() -> String {
    runtimeDirectory().appendingPathComponent("daemon.secret").path
}

func runtimeDirectory() -> URL {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
    let directory = base.appendingPathComponent("computer-use-mcp", isDirectory: true)
    try? FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    return directory
}

struct DaemonRequest: Codable {
    var id: Int
    /// "hello" (handshake), "shutdown", or a tool name.
    var method: String
    var arguments: [String: Value]? = nil
    /// Shim version, sent with "hello" so a stale daemon can be replaced.
    var version: String? = nil
    /// Shared local bearer token proving the client read the per-user daemon secret.
    var authToken: String? = nil
}

struct DaemonResponse: Codable {
    var id: Int
    var isError: Bool? = nil
    var content: [DaemonContent]? = nil
    var version: String? = nil
    /// Present and true only after the daemon accepted the auth token.
    var authenticated: Bool? = nil
}

enum DaemonProtocolLimits {
    static let maxRequestFrameBytes = 1_048_576
    static let maxResponseFrameBytes = 32 * 1_048_576
    static let readChunkBytes = 64 * 1024
    static let maxMalformedFrames = 3
    static let maxUnauthenticatedFailures = 3
    static let authenticationTimeoutSeconds = 5
    static let maxConcurrentConnections = 64
}

enum DaemonProtocolViolation: Error, Equatable {
    case frameTooLarge(maxBytes: Int)
}

enum DaemonDecodedFrame<Message> {
    case message(Message)
    case malformed
}

struct DaemonLineBuffer<Message: Decodable> {
    private var buffer = Data()
    private let maxFrameBytes: Int
    private let decoder: JSONDecoder

    init(maxFrameBytes: Int = DaemonProtocolLimits.maxRequestFrameBytes, decoder: JSONDecoder = JSONDecoder()) {
        self.maxFrameBytes = maxFrameBytes
        self.decoder = decoder
    }

    mutating func append<C: Collection>(contentsOf bytes: C) throws -> [DaemonDecodedFrame<Message>] where C.Element == UInt8 {
        buffer.append(contentsOf: bytes)
        var frames: [DaemonDecodedFrame<Message>] = []

        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            guard line.count <= maxFrameBytes else {
                throw DaemonProtocolViolation.frameTooLarge(maxBytes: maxFrameBytes)
            }
            buffer.removeSubrange(...newline)

            if let message = try? decoder.decode(Message.self, from: Data(line)) {
                frames.append(.message(message))
            } else {
                frames.append(.malformed)
            }
        }

        guard buffer.count <= maxFrameBytes else {
            throw DaemonProtocolViolation.frameTooLarge(maxBytes: maxFrameBytes)
        }
        return frames
    }
}

final class DaemonConnectionLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let maxConnections: Int
    private var connections = 0

    init(maxConnections: Int) {
        self.maxConnections = maxConnections
    }

    func tryOpen() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard connections < maxConnections else {
            return false
        }
        connections += 1
        return true
    }

    func close() {
        lock.lock()
        connections = max(0, connections - 1)
        lock.unlock()
    }

    var currentCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections
    }
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

enum DaemonAuthError: Error, CustomStringConvertible {
    case randomFailed
    case writeFailed(String)

    var description: String {
        switch self {
        case .randomFailed:
            return "Could not generate a daemon auth token."
        case .writeFailed(let path):
            return "Could not write daemon auth token at \(path)."
        }
    }
}

func daemonAuthToken() throws -> String {
    let path = daemonSecretPath()
    if let token = readDaemonAuthToken(path: path) {
        return token
    }

    let token = try generateDaemonAuthToken()
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    if fd >= 0 {
        let data = Data((token + "\n").utf8)
        let wrote = data.withUnsafeBytes { buffer -> Bool in
            var sent = 0
            while sent < buffer.count {
                let n = write(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
        close(fd)
        if wrote {
            return token
        }
        unlink(path)
        throw DaemonAuthError.writeFailed(path)
    }

    if errno == EEXIST, let token = readDaemonAuthToken(path: path) {
        return token
    }
    throw DaemonAuthError.writeFailed(path)
}

private func readDaemonAuthToken(path: String) -> String? {
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return token.isEmpty ? nil : token
}

private func generateDaemonAuthToken() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = bytes.withUnsafeMutableBytes { buffer in
        SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
    }
    guard status == errSecSuccess else {
        throw DaemonAuthError.randomFailed
    }
    return Data(bytes).base64EncodedString()
}

func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    var mismatch = left.count ^ right.count
    for index in 0..<max(left.count, right.count) {
        let a = index < left.count ? Int(left[index]) : 0
        let b = index < right.count ? Int(right[index]) : 0
        mismatch |= a ^ b
    }
    return mismatch == 0
}
