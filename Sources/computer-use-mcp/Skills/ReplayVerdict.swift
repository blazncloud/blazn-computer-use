import MCP

let replayMetaKey = "computer-use-mcp/replay"

struct ReplayStepOutcome {
    let classification: ActionClassification
    let failureDomain: FailureDomain?
    let summary: String?
    let rawValue: Value
}

enum ReplayFailureKind: String {
    case arguments
    case locator
    case toolError = "tool_error"
    case outcome
    case expectation
}

struct ReplayStepVerdict {
    let step: Int
    let tool: String
    var attempted: Bool = false
    var succeeded: Bool = false
    var classification: ActionClassification? = nil
    var failureDomain: FailureDomain? = nil
    var reason: String? = nil
    var failureKind: ReplayFailureKind? = nil
    var outcome: Value? = nil

    var value: Value {
        var fields: [String: Value] = [
            "step": .int(step),
            "tool": .string(tool),
            "attempted": .bool(attempted),
            "succeeded": .bool(succeeded),
        ]
        if let classification {
            fields["classification"] = .string(classification.rawValue)
        }
        if let failureDomain {
            fields["failure_domain"] = .string(failureDomain.rawValue)
        }
        if let reason {
            fields["reason"] = .string(reason)
        }
        if let failureKind {
            fields["failure_kind"] = .string(failureKind.rawValue)
        }
        if let outcome {
            fields["outcome"] = outcome
        }
        return .object(fields)
    }
}

struct ReplayVerdict {
    let skill: String
    let app: String
    let startAtStep: Int
    let totalSteps: Int
    let steps: [ReplayStepVerdict]

    var attempted: Int { steps.filter(\.attempted).count }
    var succeeded: Int { steps.filter { $0.attempted && $0.succeeded }.count }
    var failed: Int { steps.filter { $0.attempted && !$0.succeeded }.count }
    var firstFailure: ReplayStepVerdict? {
        steps.first { $0.attempted && !$0.succeeded }
    }

    var value: Value {
        var summary: [String: Value] = [
            "attempted": .int(attempted),
            "succeeded": .int(succeeded),
            "failed": .int(failed),
        ]
        if let firstFailure {
            summary["first_failure"] = .object([
                "step": .int(firstFailure.step),
                "tool": .string(firstFailure.tool),
                "reason": .string(firstFailure.reason ?? "step failed"),
            ])
        }

        return .object([
            "skill": .string(skill),
            "app": .string(app),
            "start_at_step": .int(startAtStep),
            "total_steps": .int(totalSteps),
            "summary": .object(summary),
            "steps": .array(steps.map(\.value)),
        ])
    }
}

struct ReplayVerdictRecorder {
    private let skill: Skill
    private let startAtStep: Int
    private var steps: [ReplayStepVerdict]

    init(skill: Skill, startAtStep: Int) {
        self.skill = skill
        self.startAtStep = startAtStep
        steps = skill.steps.enumerated().map { index, step in
            ReplayStepVerdict(step: index + 1, tool: step.tool)
        }
    }

    var verdict: ReplayVerdict {
        ReplayVerdict(
            skill: skill.name,
            app: skill.app,
            startAtStep: startAtStep,
            totalSteps: skill.steps.count,
            steps: steps
        )
    }

    mutating func recordSuccess(step index: Int, result: CallTool.Result) {
        let outcome = replayStepOutcome(from: result)
        steps[index - 1] = ReplayStepVerdict(
            step: index,
            tool: steps[index - 1].tool,
            attempted: true,
            succeeded: true,
            classification: outcome?.classification,
            failureDomain: outcome?.failureDomain,
            reason: nil,
            failureKind: nil,
            outcome: outcome?.rawValue
        )
    }

    mutating func recordFailure(
        step index: Int,
        result: CallTool.Result?,
        reason: String,
        failureKind: ReplayFailureKind
    ) {
        let outcome = result.flatMap(replayStepOutcome)
        steps[index - 1] = ReplayStepVerdict(
            step: index,
            tool: steps[index - 1].tool,
            attempted: true,
            succeeded: false,
            classification: outcome?.classification,
            failureDomain: outcome?.failureDomain,
            reason: reason,
            failureKind: failureKind,
            outcome: outcome?.rawValue
        )
    }
}

func replayStepOutcome(from result: CallTool.Result) -> ReplayStepOutcome? {
    guard case .object(let fields)? = result._meta?[actionOutcomeMetaKey],
        let rawClassification = fields["classification"]?.stringValue,
        let classification = ActionClassification(rawValue: rawClassification)
    else {
        return nil
    }
    let failureDomain = fields["failure_domain"]?.stringValue.flatMap(FailureDomain.init(rawValue:))
    return ReplayStepOutcome(
        classification: classification,
        failureDomain: failureDomain,
        summary: fields["summary"]?.stringValue,
        rawValue: .object(fields)
    )
}

extension CallTool.Result {
    func withReplayVerdict(_ verdict: ReplayVerdict) -> CallTool.Result {
        mergingMetaField(replayMetaKey, verdict.value)
    }
}
