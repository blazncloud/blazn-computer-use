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

    @Test func handshakeAcceptsSameVersionAndCurrentBuild() {
        #expect(
            daemonHandshakeAccepts(
                replyVersion: "0.2.0", replyAuthenticated: true, replyBuildStamp: 100,
                localVersion: "0.2.0", localBuildStamp: 100
            ))
        #expect(
            daemonHandshakeAccepts(
                replyVersion: "0.2.0", replyAuthenticated: true, replyBuildStamp: 200,
                localVersion: "0.2.0", localBuildStamp: 100
            ))
    }

    @Test func handshakeRetiresOlderOrUnstampedDaemonBuilds() {
        // Same semantic version but the daemon binary is older: hand over.
        #expect(
            !daemonHandshakeAccepts(
                replyVersion: "0.2.0", replyAuthenticated: true, replyBuildStamp: 50,
                localVersion: "0.2.0", localBuildStamp: 100
            ))
        // Pre-buildStamp daemons report nothing: retire once, then converge.
        #expect(
            !daemonHandshakeAccepts(
                replyVersion: "0.2.0", replyAuthenticated: true, replyBuildStamp: nil,
                localVersion: "0.2.0", localBuildStamp: 100
            ))
    }

    @Test func handshakeRejectsVersionMismatchOrUnauthenticated() {
        #expect(
            !daemonHandshakeAccepts(
                replyVersion: "0.1.0", replyAuthenticated: true, replyBuildStamp: 100,
                localVersion: "0.2.0", localBuildStamp: 100
            ))
        #expect(
            !daemonHandshakeAccepts(
                replyVersion: "0.2.0", replyAuthenticated: nil, replyBuildStamp: 100,
                localVersion: "0.2.0", localBuildStamp: 100
            ))
    }

    @Test func newerClientShutsDownOlderDaemon() {
        #expect(
            daemonClientShouldRequestShutdown(
                replyVersion: "0.4.1", replyBuildStamp: 50,
                localVersion: "0.4.1", localBuildStamp: 100
            ))
        #expect(
            daemonClientShouldRequestShutdown(
                replyVersion: "0.4.0", replyBuildStamp: nil,
                localVersion: "0.4.1", localBuildStamp: 100
            ))
        #expect(daemonAllowsShutdown(requesterBuildStamp: 100, daemonBuildStamp: 50))
    }

    @Test func olderClientDefersToNewerDaemon() {
        #expect(
            !daemonClientShouldRequestShutdown(
                replyVersion: "0.4.1", replyBuildStamp: 200,
                localVersion: "0.4.1", localBuildStamp: 100
            ))
        #expect(
            !daemonAllowsShutdown(requesterBuildStamp: 100, daemonBuildStamp: 200)
        )
        let message = daemonUpgradeRequiredMessage(daemonVersion: "0.4.1", localVersion: "0.3.0")
        #expect(message.contains("newer"))
        #expect(message.contains("upgrade this CLI"))
    }

    @Test func equalBuildStampDefersWithoutShutdown() {
        #expect(
            !daemonClientShouldRequestShutdown(
                replyVersion: "0.4.1", replyBuildStamp: 100,
                localVersion: "0.4.1", localBuildStamp: 100
            ))
        #expect(!daemonAllowsShutdown(requesterBuildStamp: 100, daemonBuildStamp: 100))
        #expect(!daemonAllowsShutdown(requesterBuildStamp: nil, daemonBuildStamp: 100))
    }

    @Test func malformedFrameBudgetSkipsUntilExhausted() {
        var budget = DaemonMalformedFrameBudget(maxFrames: 3)
        let first = budget.record()
        let second = budget.record()
        let third = budget.record()
        let fourth = budget.record()
        #expect(!first)
        #expect(!second)
        #expect(!third)
        #expect(fourth)
        #expect(budget.count == 4)
    }

    @Test func pendingRegistryFailureDropsOnlyOneId() {
        var pending = DaemonPendingRegistry<String>()
        pending.store(id: 1, handler: "one")
        pending.store(id: 2, handler: "two")
        pending.store(id: 3, handler: "three")

        let removed = pending.take(id: 2)
        #expect(removed == "two")
        #expect(pending.count == 2)
        #expect(pending.ids == [1, 3])
        let missing = pending.take(id: 2)
        #expect(missing == nil)

        let remaining = pending.takeAll().sorted()
        #expect(remaining == ["one", "three"])
        #expect(pending.count == 0)
    }

    @Test func daemonRPCTimeoutDefaultIsGenerous() {
        #expect(DaemonProtocolLimits.defaultRPCTimeoutSeconds == 120)
    }

    @Test func daemonResponsePreservesCallToolMetadata() throws {
        let result = CallTool.Result(
            content: [.text(text: "ok", annotations: nil, _meta: nil)],
            _meta: Metadata(additionalFields: ["computer-use-mcp/focus": .object(["focus_changed": .bool(false)])])
        )
        let response = DaemonResponse.from(result, id: 9)
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(DaemonResponse.self, from: data).asCallToolResult

        guard case let .object(fields)? = decoded._meta?["computer-use-mcp/focus"] else {
            Issue.record("expected focus metadata")
            return
        }
        #expect(fields["focus_changed"]?.boolValue == false)
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
            #expect(isMutatingTool(name), "\(name) should be coordinated as mutating")
        }
        for name in ["list_apps", "get_app_state", "find", "list_windows", "read_clipboard", "wait_for", "read_text"] {
            #expect(!isMutatingTool(name), "\(name) should remain classified as read-only")
        }
    }

    @Test(arguments: ["click", "read_clipboard", "get_app_state"])
    func everyToolFailsFastWhenDaemonUnavailable(name: String) async {
        let result = await dispatchToolThroughDaemon(
            name: name,
            arguments: [:],
            daemonCall: { _, _ in throw ToolError.failed("boom") }
        )

        #expect(result.isError == true)
        #expect(textContent(result).contains("tool \"\(name)\" was not run"))
        guard case .object(let metadata)? = result._meta?["computer-use-mcp/error"] else {
            Issue.record("Missing structured daemon failure metadata")
            return
        }
        #expect(metadata["code"] == .string("DAEMON_UNAVAILABLE"))
    }

    @Test func successfulExternalRouteReturnsOnlyDaemonResult() async {
        let result = await dispatchToolThroughDaemon(
            name: "list_apps",
            arguments: [:],
            daemonCall: { name, _ in .text("daemon \(name)") }
        )

        #expect(result.isError != true)
        #expect(textContent(result) == "daemon list_apps")
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
