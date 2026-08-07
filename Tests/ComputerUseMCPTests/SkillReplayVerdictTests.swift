import MCP
import Testing

@testable import computer_use_mcp

private func replaySkill(steps: Int) -> Skill {
    Skill(
        name: "fixture-replay",
        description: "test",
        app: "Fixture",
        steps: (0..<steps).map { index in
            SkillStep(tool: index == 0 ? "set_value" : "click", arguments: [:])
        }
    )
}

private func result(_ outcome: ActionOutcome) -> CallTool.Result {
    CallTool.Result.text(outcome.summary).withActionOutcome(outcome)
}

private func syntheticReplay(
    skill: Skill,
    outcomes: [CallTool.Result],
    startAtStep: Int = 1
) -> ReplayVerdict {
    var recorder = ReplayVerdictRecorder(skill: skill, startAtStep: startAtStep)
    for (offset, result) in outcomes.enumerated() {
        let step = startAtStep + offset
        if result.isError == true {
            recorder.recordFailure(
                step: step,
                result: result,
                reason: batchResultText(result),
                failureKind: .toolError
            )
            break
        }
        if let outcome = replayStepOutcome(from: result), outcome.classification != .success {
            recorder.recordFailure(
                step: step,
                result: result,
                reason: outcome.summary ?? "step outcome was \(outcome.classification.rawValue)",
                failureKind: .outcome
            )
            break
        }
        recorder.recordSuccess(step: step, result: result)
    }
    return recorder.verdict
}

@Suite struct SkillReplayVerdictTests {
    @Test func summaryMathAndFirstFailureUseAttemptedStepsOnly() {
        let skill = replaySkill(steps: 3)
        let verdict = syntheticReplay(skill: skill, outcomes: [
            result(.success("field updated")),
            result(.effectNotVerified(.verification, "liar button did not change UI")),
            result(.success("unreached")),
        ])

        #expect(verdict.attempted == 2)
        #expect(verdict.succeeded == 1)
        #expect(verdict.failed == 1)
        #expect(verdict.firstFailure?.step == 2)
        #expect(verdict.firstFailure?.reason == "liar button did not change UI")
        #expect(verdict.steps[2].attempted == false)
    }

    @Test func failFastLeavesLaterStepsNotAttempted() {
        let skill = replaySkill(steps: 4)
        let verdict = syntheticReplay(skill: skill, outcomes: [
            result(.success("first")),
            result(.unsupported(.unsupported, "disabled button")),
            result(.success("third")),
            result(.success("fourth")),
        ])

        #expect(verdict.steps.map(\.attempted) == [true, true, false, false])
        #expect(verdict.steps.map(\.succeeded) == [true, false, false, false])
        #expect(verdict.firstFailure?.step == 2)
    }

    @Test func perStepClassificationAndDomainPassThroughFromActionOutcome() {
        let skill = replaySkill(steps: 2)
        let verification = ActionVerification(
            renderedTextChanged: false,
            targetStateChanged: false,
            notes: ["No confirming change observed."]
        )
        let verdict = syntheticReplay(skill: skill, outcomes: [
            result(.effectNotVerified(.transport, "background event likely dropped", verification)),
            result(.success("unreached")),
        ])

        let step = verdict.steps[0]
        #expect(step.classification == .effectNotVerified)
        #expect(step.failureDomain == .transport)
        guard case .object(let outcomeFields)? = step.outcome else {
            Issue.record("expected raw outcome block")
            return
        }
        #expect(outcomeFields["classification"]?.stringValue == "effect_not_verified")
        #expect(outcomeFields["failure_domain"]?.stringValue == "transport")
    }

    @Test func replayMetaShapeIncludesSummaryFirstFailureAndSteps() {
        let skill = replaySkill(steps: 2)
        let verdict = syntheticReplay(skill: skill, outcomes: [
            result(.success("first")),
            result(.ambiguous(.targeting, "target relocated before reread")),
        ])
        let wrapped = CallTool.Result.text("stopped").withReplayVerdict(verdict)

        guard case .object(let replay)? = wrapped._meta?[replayMetaKey] else {
            Issue.record("expected replay meta block")
            return
        }
        guard case .object(let summary)? = replay["summary"] else {
            Issue.record("expected summary object")
            return
        }
        #expect(summary["attempted"]?.intValue == 2)
        #expect(summary["succeeded"]?.intValue == 1)
        #expect(summary["failed"]?.intValue == 1)
        guard case .object(let firstFailure)? = summary["first_failure"] else {
            Issue.record("expected first_failure object")
            return
        }
        #expect(firstFailure["step"]?.intValue == 2)
        #expect(firstFailure["tool"]?.stringValue == "click")
        #expect(firstFailure["reason"]?.stringValue == "target relocated before reread")
        guard case .array(let steps)? = replay["steps"] else {
            Issue.record("expected steps array")
            return
        }
        #expect(steps.count == 2)
    }

    @Test func successfulStepWithoutOutcomeDoesNotClaimVerifiedClassification() {
        let skill = replaySkill(steps: 1)
        var recorder = ReplayVerdictRecorder(skill: skill, startAtStep: 1)

        recorder.recordSuccess(step: 1, result: .text("legacy tool completed"))

        let step = recorder.verdict.steps[0]
        #expect(step.attempted == true)
        #expect(step.succeeded == true)
        #expect(step.classification == nil)
        guard case .object(let fields) = step.value else {
            Issue.record("expected step object")
            return
        }
        #expect(fields["classification"] == nil)
    }

    @Test func failureWithoutOutcomeDoesNotCarrySuccessClassification() {
        let skill = replaySkill(steps: 1)
        var recorder = ReplayVerdictRecorder(skill: skill, startAtStep: 1)

        recorder.recordFailure(
            step: 1,
            result: .text("expectation timed out", isError: true),
            reason: "the step ran but its expectation was not met — timed out",
            failureKind: .expectation
        )

        let step = recorder.verdict.steps[0]
        #expect(step.attempted == true)
        #expect(step.succeeded == false)
        #expect(step.classification == nil)
        #expect(step.failureKind == .expectation)
    }

    @Test func replayExpectationTimeoutRecognizesWaitForTimeoutText() {
        let timeout = CallTool.Result.text("TIMED OUT after 1s waiting for label \"Done\". Current state below.")
        let met = CallTool.Result.text("Condition met after 0.4s: label \"Done\" appeared.")

        #expect(replayExpectationTimedOut(timeout) == true)
        #expect(replayExpectationTimedOut(met) == false)
    }

    @Test func outcomeGateLetsExpectationsProveDelayedObservableEffects() {
        let delayed = ReplayStepOutcome(
            classification: .effectNotVerified,
            failureDomain: .verification,
            summary: nil,
            rawValue: .object([:])
        )
        let unsupported = ReplayStepOutcome(
            classification: .unsupported,
            failureDomain: .unsupported,
            summary: nil,
            rawValue: .object([:])
        )
        let success = ReplayStepOutcome(
            classification: .success,
            failureDomain: nil,
            summary: nil,
            rawValue: .object([:])
        )

        #expect(replayOutcomeFailsBeforeExpectation(delayed, canExpectationProve: true) == false)
        #expect(replayOutcomeFailsBeforeExpectation(delayed, canExpectationProve: false) == true)
        #expect(replayOutcomeFailsBeforeExpectation(unsupported, canExpectationProve: true) == true)
        #expect(replayOutcomeFailsBeforeExpectation(success, canExpectationProve: false) == false)
    }

    @Test func mutatingStepWithoutOutcomeRequiresExpectationProof() {
        #expect(replayMissingOutcomeFails(tool: "select_text", canExpectationProve: false) == true)
        #expect(replayMissingOutcomeFails(tool: "select_text", canExpectationProve: true) == false)
        #expect(replayMissingOutcomeFails(tool: "read_text", canExpectationProve: false) == false)
        #expect(replayMissingOutcomeFails(tool: "wait_for", canExpectationProve: false) == false)
    }

    @Test func firstFailingCommittedLeafRequiresReconciliationInsteadOfSameStepRetry() {
        let guidance = replayFailureGuidance(
            name: "fixture", app: "Fixture", step: 1, completedSteps: [],
            currentLeafEvidence: .definite)
        #expect(guidance.contains("mutation was delivered"))
        #expect(guidance.contains("get_app_state"))
        #expect(guidance.contains("Do not replay step 1"))
        #expect(!guidance.contains("No earlier steps ran"))
        #expect(!guidance.contains("start_at_step: 1"))
    }

    @Test func firstFailingUnknownLeafRequiresReconciliationInsteadOfSameStepRetry() {
        let guidance = replayFailureGuidance(
            name: "fixture", app: "Fixture", step: 1, completedSteps: [],
            currentLeafEvidence: .unknown)
        #expect(guidance.contains("may have delivered"))
        #expect(guidance.contains("get_app_state"))
        #expect(!guidance.contains("No earlier steps ran"))
        #expect(!guidance.contains("start_at_step: 1"))
    }

    @Test func firstFailingPreDeliveryLeafCanRetryTheSameStep() {
        let guidance = replayFailureGuidance(
            name: "fixture", app: "Fixture", step: 1, completedSteps: [],
            currentLeafEvidence: .none)
        #expect(guidance.contains("No earlier steps ran"))
        #expect(guidance.contains("start_at_step: 1"))
    }

    @Test func committedNonIdempotentStepFollowedByExpectationTimeoutRetainsCommitEvidence() {
        let stepResult = CallTool.Result.text("Created item")
            .withActionOutcome(.success("created").withDispatchSucceeded(true))
            .withCommittedEvidence()
        let waitResult = CallTool.Result.text("TIMED OUT after 2 seconds", isError: true)
            .withNotCommittedEvidence()

        let combined = replayExpectationFailureEvidence(
            stepResult: stepResult, waitResult: waitResult)
        #expect(leafCommitEvidence(combined) == .definite)

        let guidance = replayFailureGuidance(
            name: "create-item", app: "Fixture", step: 1, completedSteps: [],
            currentLeafEvidence: leafCommitEvidence(combined))
        #expect(guidance.contains("get_app_state"))
        #expect(guidance.contains("Do not replay step 1"))
        #expect(!guidance.contains("start_at_step: 1"))
    }

    @Test func unknownStepCommitFollowedByExpectationTimeoutStaysUnknown() {
        let stepResult = CallTool.Result.text("delivery uncertain", isError: true)
            .withUnknownCommitEvidence()
        let waitResult = CallTool.Result.text("TIMED OUT after 2 seconds", isError: true)
            .withNotCommittedEvidence()
        let combined = replayExpectationFailureEvidence(
            stepResult: stepResult, waitResult: waitResult)
        #expect(leafCommitEvidence(combined) == .unknown)
    }

    @Test func preDeliveryStepAndExpectationFailureRemainNotCommitted() {
        let stepResult = CallTool.Result.text("not delivered", isError: true)
            .withNotCommittedEvidence()
        let waitResult = CallTool.Result.text("TIMED OUT after 2 seconds", isError: true)
            .withNotCommittedEvidence()
        let combined = replayExpectationFailureEvidence(
            stepResult: stepResult, waitResult: waitResult)
        #expect(leafCommitEvidence(combined) == .none)
    }

}
