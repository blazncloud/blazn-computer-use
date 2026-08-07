import Foundation
import MCP
import Testing

@testable import computer_use_mcp

private final class InvocationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var invoked = false
    func markInvoked() { lock.withLock { invoked = true } }
    var value: Bool { lock.withLock { invoked } }
}

@Suite struct SkillMutationDeliveryTests {
    @Test(arguments: ["save_skill", "delete_skill", "record_skill_start", "record_skill_stop"])
    func cancellationBeforeDeliveryDoesNotInvokeSkillPrimitive(_ operation: String) async {
        let invocation = InvocationBox()
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try performSkillMutation {
                invocation.markInvoked()
                return operation
            }
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected pre-delivery cancellation")
        } catch {
            #expect(error is PreDeliveryCancellationError)
        }
        #expect(invocation.value == false)
    }

    @Test func successfulSkillMutationCarriesExplicitDeliveryAndCommitEvidence() {
        let result = successfulSkillMutationResult("done", summary: "saved")
        #expect(leafCommitEvidence(result) == .definite)
        #expect(replayStepOutcome(from: result)?.classification == .success)
    }
}
