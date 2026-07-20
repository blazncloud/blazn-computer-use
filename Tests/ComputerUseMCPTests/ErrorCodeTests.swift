import MCP
import Testing

@testable import computer_use_mcp

@Suite struct ErrorCodeTests {
    // MARK: Message → code mapping (fragments copied from the real throw sites)

    @Test func staleElementMessagesMapToStaleElement() {
        #expect(
            toolErrorCode(forMessage:
                "Element e12@s1 (AXButton \"Save\") is stale: no element at path …") == .staleElement)
        #expect(
            toolErrorCode(forMessage:
                "\"e3@s1\" is from an older app state and did not survive the UI change") == .staleElement)
    }

    @Test func unknownIdMapsToElementNotFound() {
        #expect(
            toolErrorCode(forMessage:
                "\"e9@s2\" is not an element id from the latest Safari state.") == .elementNotFound)
        #expect(
            toolErrorCode(forMessage:
                "No app state captured for Finder yet. Call get_app_state first.") == .elementNotFound)
    }

    @Test func missingAppMessagesMapToAppNotFound() {
        #expect(
            toolErrorCode(forMessage:
                "\"Xcode\" is not running. Only running apps can be controlled.") == .appNotFound)
        #expect(toolErrorCode(forMessage: "No app named \"Foo\" found.") == .appNotFound)
        #expect(
            toolErrorCode(forMessage:
                "Notes (pid 42) has quit or crashed since it was resolved.") == .appNotFound)
    }

    @Test func unsettableTargetMapsToNotSettable() {
        #expect(
            toolErrorCode(forMessage:
                "the focused element (AXGroup) is not editable via accessibility.") == .notSettable)
        #expect(
            toolErrorCode(forMessage:
                "e5@s1 (AXSlider) does not accept a direct value; nothing was set.") == .notSettable)
        #expect(toolErrorCode(forMessage: "Could not set the value of e5@s1.") == .notSettable)
    }

    @Test func framelessTargetMapsToOffscreen() {
        #expect(
            toolErrorCode(forMessage:
                "e7@s1 has no screen position (the element exposes no frame).") == .offscreenTarget)
    }

    @Test func policyAndSessionMessagesMap() {
        #expect(
            toolErrorCode(forMessage: "Denied by URL policy: matched \"internal\".") == .policyDenied)
        #expect(
            toolErrorCode(forMessage:
                "The screen is locked, so mutating computer-use actions are paused.") == .screenLocked)
        #expect(
            toolErrorCode(forMessage:
                "User activity detected: the target app \"Mail\" is the app the user is working in.")
                == .userInterference)
    }

    @Test func unrecognizedMessageIsUncoded() {
        #expect(toolErrorCode(forMessage: "Some entirely novel failure.") == nil)
    }

    @Test func daemonDenialMessagesMapToStructuredCodes() {
        #expect(
            toolErrorCode(forMessage:
                "Another agent session is mid-task in Safari (lease expires in 3s). Retry shortly, "
                    + "or work in a different app to avoid interleaving with it.")
                == .appLeaseHeld)
        #expect(toolErrorCode(forMessage: "Unauthorized daemon request.") == .daemonUnauthorized)
        #expect(
            toolErrorCode(forMessage: "Shutdown refused: requester build is not newer than this daemon.")
                == .daemonUnauthorized)
    }

    @Test func daemonDenialCodedResultsPrefixAndAttachMeta() {
        let lease = codedErrorResult(
            "Another agent session is mid-task in Notes.", code: .appLeaseHeld
        )
        #expect(text(of: lease).hasPrefix("[APP_LEASE_HELD] "))
        #expect(lease.isError == true)

        let unauthorized = codedErrorResult("Unauthorized daemon request.", code: .daemonUnauthorized)
        #expect(text(of: unauthorized).hasPrefix("[DAEMON_UNAUTHORIZED] "))
        guard case let .object(fields)? = unauthorized._meta?["computer-use-mcp/error"] else {
            Issue.record("expected computer-use-mcp/error meta object")
            return
        }
        #expect(fields["code"]?.stringValue == "DAEMON_UNAUTHORIZED")
    }

    @Test func earlierRuleWinsWhenSeveralCouldMatch() {
        // "is stale" is the specific, actionable signal even though a stale
        // message also mentions an element id.
        #expect(
            toolErrorCode(forMessage:
                "Element e1@s1 is stale: the element id no longer resolves.") == .staleElement)
    }

    // MARK: Error type → code

    @Test func safetyErrorIsConfirmationRequiredByType() {
        let error: Error = SafetyError(reason: "this looks destructive.")
        #expect(toolErrorCode(for: error) == .confirmationRequired)
    }

    @Test func toolErrorFallsBackToMessageClassification() {
        let error: Error = ToolError.failed("e2@s1 (AXButton) is stale: gone.")
        #expect(toolErrorCode(for: error) == .staleElement)
    }

    // MARK: Result shaping

    @Test func codedResultPrefixesTextAndAttachesMeta() {
        let result = codedErrorResult("e1@s1 is stale: gone.", code: .staleElement)
        #expect(result.isError == true)
        #expect(text(of: result).hasPrefix("[STALE_ELEMENT] "))
        guard case let .object(fields)? = result._meta?["computer-use-mcp/error"] else {
            Issue.record("expected computer-use-mcp/error meta object")
            return
        }
        #expect(fields["code"]?.stringValue == "STALE_ELEMENT")
        #expect(fields["recovery"]?.stringValue == ToolErrorCode.staleElement.recovery)
    }

    @Test func uncodedResultPassesThroughWithoutPrefixOrMeta() {
        let result = codedErrorResult("Some novel failure.", code: nil)
        #expect(result.isError == true)
        #expect(text(of: result) == "Some novel failure.")
        #expect(result._meta?["computer-use-mcp/error"] == nil)
    }

    @Test func everyCodeHasARecoveryHint() {
        for code in ToolErrorCode.allCases {
            #expect(!code.recovery.isEmpty, "\(code.rawValue) needs a recovery hint")
        }
    }

    private func text(of result: CallTool.Result) -> String {
        for case let .text(text, _, _) in result.content { return text }
        return ""
    }
}
