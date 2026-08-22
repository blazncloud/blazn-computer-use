import Foundation
import MCP
import Testing

@testable import computer_use_mcp

@Suite struct CallJSONTests {
    @Test func parsesJSONFlagBeforeOrAfterToolName() throws {
        let before = try parseCallInvocation(["--json", "health_report", "{\"probe_capture\":true}"])
        let after = try parseCallInvocation(["health_report", "{\"probe_capture\":true}", "--json"])

        #expect(before.toolName == "health_report")
        #expect(after.toolName == "health_report")
        #expect(before.jsonOutput)
        #expect(after.jsonOutput)
        #expect(before.arguments == after.arguments)
        #expect(before.arguments["probe_capture"]?.boolValue == true)
    }

    @Test func rejectsUnknownToolsAndNonObjectArguments() {
        #expect(throws: (any Error).self) {
            try parseCallInvocation(["missing_tool"])
        }
        #expect(throws: (any Error).self) {
            try parseCallInvocation(["health_report", "[]"])
        }
    }

    @Test func JSONEnvelopePreservesMCPResultShape() throws {
        let result = CallTool.Result.text("ok").withActionOutcome(.success("fixture"))

        let data = try encodeJSONCallResult(toolName: "health_report", result: result)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedResult = try #require(object["result"] as? [String: Any])

        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["tool"] as? String == "health_report")
        #expect(encodedResult["isError"] as? Bool == false)
        #expect(encodedResult["content"] != nil)
        #expect(encodedResult["_meta"] != nil)
    }
}
