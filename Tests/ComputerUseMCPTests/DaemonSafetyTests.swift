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
