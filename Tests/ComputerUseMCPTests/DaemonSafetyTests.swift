import Foundation
import MCP
import Testing

@testable import computer_use_mcp

@Suite struct DaemonSafetyTests {
    @Test func daemonRequestCarriesAuthToken() throws {
        let request = DaemonRequest(id: 7, method: "hello", version: "test-version", authToken: "secret")
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(DaemonRequest.self, from: data)

        #expect(decoded.id == 7)
        #expect(decoded.method == "hello")
        #expect(decoded.version == "test-version")
        #expect(decoded.authToken == "secret")
    }

    @Test func daemonHelloResponseCarriesAuthenticatedMarker() throws {
        let response = DaemonResponse(id: 7, version: "test-version", authenticated: true)
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(DaemonResponse.self, from: data)

        #expect(decoded.id == 7)
        #expect(decoded.version == "test-version")
        #expect(decoded.authenticated == true)
    }

    @Test func constantTimeEqualityChecksValueAndLength() {
        #expect(constantTimeEqual("secret", "secret"))
        #expect(!constantTimeEqual("secret", "SECRET"))
        #expect(!constantTimeEqual("secret", "secret2"))
    }

    @Test func daemonLineBufferDecodesCompleteFramesAndKeepsPartialData() throws {
        let first = try JSONEncoder().encode(DaemonRequest(id: 1, method: "hello", authToken: "secret"))
        let second = try JSONEncoder().encode(DaemonRequest(id: 2, method: "list_apps"))
        var buffer = DaemonLineBuffer<DaemonRequest>(maxFrameBytes: 256)

        let partialFrames = try buffer.append(contentsOf: Array(first))
        #expect(partialFrames.isEmpty)

        let frames = try buffer.append(contentsOf: Array("\n".utf8) + Array(second) + Array("\n".utf8))
        let requests = decodedRequests(frames)

        #expect(requests.count == 2)
        #expect(requests[0].id == 1)
        #expect(requests[0].method == "hello")
        #expect(requests[1].id == 2)
        #expect(requests[1].method == "list_apps")
    }

    @Test func daemonLineBufferRejectsOversizedFrameBeforeUnboundedGrowth() throws {
        var buffer = DaemonLineBuffer<DaemonRequest>(maxFrameBytes: 8)

        do {
            _ = try buffer.append(contentsOf: Array("123456789".utf8))
            Issue.record("expected oversized frame rejection")
        } catch DaemonProtocolViolation.frameTooLarge(let maxBytes) {
            #expect(maxBytes == 8)
        }
    }

    @Test func daemonLineBufferReportsMalformedFrames() throws {
        var buffer = DaemonLineBuffer<DaemonRequest>(maxFrameBytes: 256)
        let frames = try buffer.append(contentsOf: Array("not-json\n".utf8))

        guard frames.count == 1 else {
            Issue.record("expected exactly one decoded frame")
            return
        }
        guard case .malformed = frames[0] else {
            Issue.record("expected malformed frame")
            return
        }
    }

    @Test func daemonResponseBufferAllowsScreenshotPayloadsBeyondRequestLimit() throws {
        let imageData = String(repeating: "a", count: DaemonProtocolLimits.maxRequestFrameBytes + 1)
        let response = DaemonResponse(
            id: 3,
            content: [DaemonContent(type: "image", data: imageData, mimeType: "image/png")]
        )
        var encoded = try JSONEncoder().encode(response)
        encoded.append(0x0A)
        var buffer = DaemonLineBuffer<DaemonResponse>(maxFrameBytes: DaemonProtocolLimits.maxResponseFrameBytes)

        let frames = try buffer.append(contentsOf: encoded)
        guard frames.count == 1, case .message(let decoded) = frames[0] else {
            Issue.record("expected one decoded response frame")
            return
        }

        #expect(decoded.id == 3)
        #expect(decoded.content?.first?.data?.count == imageData.count)
    }

    @Test func daemonAuthorizationBudgetsUnauthenticatedFailures() {
        let authorization = DaemonConnectionAuthorization()

        for _ in 0..<DaemonProtocolLimits.maxUnauthenticatedFailures {
            #expect(!authorization.recordUnauthenticatedFailure(maxFailures: DaemonProtocolLimits.maxUnauthenticatedFailures))
        }
        #expect(authorization.recordUnauthenticatedFailure(maxFailures: DaemonProtocolLimits.maxUnauthenticatedFailures))

        authorization.markAuthenticated()
        #expect(!authorization.recordUnauthenticatedFailure(maxFailures: DaemonProtocolLimits.maxUnauthenticatedFailures))
    }

    @Test func daemonConnectionLimiterCapsConcurrentConnections() {
        let limiter = DaemonConnectionLimiter(maxConnections: 2)

        #expect(limiter.tryOpen())
        #expect(limiter.tryOpen())
        #expect(!limiter.tryOpen())
        #expect(limiter.currentCount == 2)

        limiter.close()
        #expect(limiter.tryOpen())
        #expect(limiter.currentCount == 2)
    }

    @Test func mutatingToolClassifierCoversSystemSideEffects() {
        for name in ["click", "type_text", "open_app", "open_url", "manage_window", "write_clipboard"] {
            #expect(isMutatingTool(name), "\(name) should fail closed when daemon arbitration is unavailable")
        }
        for name in ["list_apps", "get_app_state", "find", "list_windows", "read_clipboard", "wait_for", "read_text"] {
            #expect(!isMutatingTool(name), "\(name) should be eligible for read-only in-process fallback")
        }
    }

    @Test func mutatingFallbackFailsClosedWhenDaemonUnavailable() async {
        let probe = LocalDispatchProbe()
        let result = await dispatchToolWithDaemonPolicy(
            name: "click",
            arguments: [:],
            useDaemon: true,
            daemonCall: { _, _ in throw ToolError.failed("boom") },
            localDispatch: { name, arguments in await probe.dispatch(name: name, arguments: arguments) }
        )

        #expect(result.isError == true)
        #expect(textContent(result).contains("refusing to run mutating tool \"click\" in-process"))
        #expect(await probe.wasCalled() == false)
    }

    @Test func readOnlyFallbackMayRunInProcessWhenDaemonUnavailable() async {
        let probe = LocalDispatchProbe()
        let result = await dispatchToolWithDaemonPolicy(
            name: "read_clipboard",
            arguments: [:],
            useDaemon: true,
            daemonCall: { _, _ in throw ToolError.failed("boom") },
            localDispatch: { name, arguments in await probe.dispatch(name: name, arguments: arguments) }
        )

        #expect(result.isError != true)
        #expect(textContent(result) == "local read_clipboard")
        #expect(await probe.wasCalled())
    }

    @Test func noDaemonAllowsExplicitMutatingInProcessDispatch() async {
        let probe = LocalDispatchProbe()
        let result = await dispatchToolWithDaemonPolicy(
            name: "click",
            arguments: [:],
            useDaemon: false,
            daemonCall: { _, _ in throw ToolError.failed("should not call daemon") },
            localDispatch: { name, arguments in await probe.dispatch(name: name, arguments: arguments) }
        )

        #expect(result.isError != true)
        #expect(textContent(result) == "local click")
        #expect(await probe.wasCalled())
    }
}

private actor LocalDispatchProbe {
    private var called = false

    func dispatch(name: String, arguments: [String: Value]) -> CallTool.Result {
        called = true
        return .text("local \(name)")
    }

    func wasCalled() -> Bool {
        called
    }
}

private func textContent(_ result: CallTool.Result) -> String {
    guard case .text(let text, _, _)? = result.content.first else {
        return ""
    }
    return text
}

private func decodedRequests(_ frames: [DaemonDecodedFrame<DaemonRequest>]) -> [DaemonRequest] {
    frames.compactMap { frame in
        guard case .message(let request) = frame else {
            return nil
        }
        return request
    }
}
