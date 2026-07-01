import MCP
import Testing

@testable import computer_use_mcp

@Suite struct BatchToolTests {
    @Test func batchNeverContainsItselfAndAllowsWaitFor() {
        #expect(!batchableToolNames.contains("batch"))
        #expect(batchableToolNames.contains("wait_for"))
        #expect(batchableToolNames.contains("click"))
        #expect(batchableToolNames.contains("type_text"))
        // Not app-scoped: must not be batchable.
        #expect(!batchableToolNames.contains("open_url"))
        #expect(!batchableToolNames.contains("write_clipboard"))
    }

    @Test func batchIsGatedLikeOtherAppScopedMutatingTools() {
        #expect(isMutatingTool("batch"))
        #expect(appScopedToolNames.contains("batch"))
    }

    @Test func rejectsMissingEmptyAndOversizedActions() async {
        await #expect(throws: ToolError.self) {
            _ = try await batchImpl(["app": .string("Finder")])
        }
        await #expect(throws: ToolError.self) {
            _ = try await batchImpl(["app": .string("Finder"), "actions": .array([])])
        }
        let tooMany = Value.array(
            Array(repeating: .object(["tool": .string("click")]), count: maxBatchActions + 1))
        await #expect(throws: ToolError.self) {
            _ = try await batchImpl(["app": .string("Finder"), "actions": tooMany])
        }
    }

    @Test func rejectsUnknownStepToolBeforeRunningAnything() async {
        let actions = Value.array([
            .object(["tool": .string("click"), "element_id": .string("e1@s1")]),
            .object(["tool": .string("open_url"), "url": .string("https://example.com")]),
        ])
        let message = await errorMessage {
            _ = try await batchImpl(["app": .string("Finder"), "actions": actions])
        }
        #expect(message.contains("open_url"))
        #expect(message.contains("cannot run in a batch"))
    }

    @Test func rejectsStepWithoutTool() async {
        let actions = Value.array([.object(["element_id": .string("e1@s1")])])
        let message = await errorMessage {
            _ = try await batchImpl(["app": .string("Finder"), "actions": actions])
        }
        #expect(message.contains("missing \"tool\""))
    }
}

private func errorMessage(_ body: () async throws -> Void) async -> String {
    do {
        try await body()
        return ""
    } catch {
        return "\(error)"
    }
}
