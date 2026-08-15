import Foundation
import MCP
import Testing

@testable import computer_use_mcp

private func sampleSkill(name: String = "file-report", steps: [SkillStep]? = nil) -> Skill {
    Skill(
        name: name, description: "test", app: "Fixture",
        params: [SkillParam(name: "value", description: "what to type")],
        steps: steps ?? [
            SkillStep(
                tool: "set_value", locator: SkillLocator(role: "AXTextField"),
                arguments: ["value": .string("{{value}}")])
        ])
}

@Suite struct SkillValidationTests {
    @Test func wellFormedSkillValidates() throws {
        try validateSkill(sampleSkill())
    }

    @Test func rejectsBadNamesStepsAndParams() {
        #expect(throws: SkillValidationError.self) { try validateSkill(sampleSkill(name: "Bad Name!")) }
        #expect(throws: SkillValidationError.self) { try validateSkill(sampleSkill(steps: [])) }
        let tooMany = Array(
            repeating: SkillStep(tool: "click", arguments: [:]), count: maxSkillSteps + 1)
        #expect(throws: SkillValidationError.self) { try validateSkill(sampleSkill(steps: tooMany)) }
        #expect(throws: SkillValidationError.self) {
            try validateSkill(sampleSkill(steps: [SkillStep(tool: "run_skill", arguments: [:])]))
        }
    }

    @Test func stepToolSetAllowsActionsWaitForAndExtracts() {
        #expect(skillStepToolNames.contains("click"))
        #expect(skillStepToolNames.contains("wait_for"))
        #expect(skillStepToolNames.contains("read_text"))
        #expect(!skillStepToolNames.contains("run_skill"))
        #expect(!batchableToolNames.contains("read_text"))
    }
}

@Suite struct SkillTemplatingTests {
    @Test func substitutesNestedPlaceholders() {
        let value: Value = .object([
            "text": .string("report-{{week}}.pdf"),
            "list": .array([.string("{{week}}"), .int(3)]),
        ])
        let result = substituteParams(value, params: ["week": "2026-W27"])
        guard case .object(let fields) = result else {
            Issue.record("expected object")
            return
        }
        #expect(fields["text"]?.stringValue == "report-2026-W27.pdf")
        #expect(unresolvedPlaceholders(result).isEmpty)
    }
}

private func skillSnapshot(_ elements: [CapturedNode]) -> AppSnapshot {
    AppSnapshot(
        pid: 1, bundleIdentifier: "com.example", windowTitle: "Doc",
        windowOrigin: [0, 0], pixelsPerPoint: 1, windowSize: [800, 600],
        createdAt: Date(timeIntervalSince1970: 0), generation: "s1",
        elements: elements)
}

@Suite struct SkillLocatorTests {
    @Test func uniqueRoleLabelResolves() {
        let save = CapturedNode(
            id: "e0@s1", role: "AXButton", label: "Save", frame: [0, 0, 1, 1])
        #expect(resolveSkillLocator(
            SkillLocator(role: "AXButton", label: "Save"),
            in: skillSnapshot([save])) == .found(save))
    }

    @Test func ambiguousAndMissingLocatorsFailLoudly() {
        let buttons = [
            CapturedNode(id: "e0@s1", role: "AXButton", label: "Save", frame: [0, 0, 1, 1]),
            CapturedNode(id: "e1@s1", role: "AXButton", label: "Save", frame: [0, 0, 1, 1]),
        ]
        guard case .failed(let ambiguous) = resolveSkillLocator(
            SkillLocator(role: "AXButton", label: "Save"), in: skillSnapshot(buttons))
        else {
            Issue.record("expected ambiguity")
            return
        }
        #expect(ambiguous.contains("ambiguous"))
        guard case .failed(let missing) = resolveSkillLocator(
            SkillLocator(role: "AXCheckBox", label: "Nope"), in: skillSnapshot(buttons))
        else {
            Issue.record("expected missing failure")
            return
        }
        #expect(missing.contains("no element matching"))
    }

    @Test func textEntryLabelChurnFailsWithoutGuessing() {
        let field = CapturedNode(
            id: "e0@s1", role: "AXTextArea", label: "Draft body", frame: [0, 0, 1, 1])
        guard case .failed(let reason) = resolveSkillLocator(
            SkillLocator(role: "AXTextArea", label: "old body"),
            in: skillSnapshot([field]))
        else {
            Issue.record("expected stale skill anchor")
            return
        }
        #expect(reason.contains("no element matching"))
    }
}

@Suite struct SkillCodableTests {
    @Test func skillRoundTripsThroughJSON() throws {
        let skill = sampleSkill()
        let decoded = try JSONDecoder().decode(Skill.self, from: JSONEncoder().encode(skill))
        #expect(decoded == skill)
    }
}
