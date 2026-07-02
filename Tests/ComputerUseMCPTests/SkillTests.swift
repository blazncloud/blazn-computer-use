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
                tool: "set_value",
                locator: SkillLocator(role: "AXTextField"),
                arguments: ["value": .string("{{value}}")]
            )
        ]
    )
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
        #expect(throws: SkillValidationError.self) {
            try validateSkill(sampleSkill(steps: [SkillStep(tool: "batch", arguments: [:])]))
        }
        #expect(throws: SkillValidationError.self) {
            try validateSkill(sampleSkill(steps: [SkillStep(tool: "open_url", arguments: [:])]))
        }
    }

    @Test func stepToolSetAllowsActionsWaitForAndExtracts() {
        #expect(skillStepToolNames.contains("click"))
        #expect(skillStepToolNames.contains("wait_for"))
        #expect(skillStepToolNames.contains("read_text"))
        #expect(!skillStepToolNames.contains("run_skill"))
        #expect(!skillStepToolNames.contains("batch"))
        // read_text is a skill extract step but stays out of batch.
        #expect(!batchableToolNames.contains("read_text"))
    }

    @Test func skillToolsAreClassifiedForGating() {
        #expect(isMutatingTool("run_skill"))
        #expect(isMutatingTool("save_skill"))
        #expect(isMutatingTool("delete_skill"))
        #expect(!isMutatingTool("list_skills"))
        #expect(appScopedToolNames.contains("run_skill"))
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
        guard case .array(let items)? = fields["list"] else {
            Issue.record("expected array")
            return
        }
        #expect(items[0].stringValue == "2026-W27")
        #expect(items[1].intValue == 3)
    }

    @Test func reportsUnresolvedPlaceholders() {
        let value: Value = .object(["text": .string("{{week}} and {{missing}}")])
        let leftover = unresolvedPlaceholders(substituteParams(value, params: ["week": "W1"]))
        #expect(leftover == ["missing"])
        #expect(unresolvedPlaceholders(substituteParams(value, params: ["week": "a", "missing": "b"])).isEmpty)
    }
}

@Suite struct SkillLocatorTests {
    private let fieldPath = [LocatorStep(role: "AXTextField", indexOfRole: 0)]

    private func snapshot(elements: [SnapshotElement]) -> AppSnapshot {
        AppSnapshot(
            pid: 1, bundleIdentifier: "com.example", windowTitle: "Doc",
            windowOrigin: [0, 0], pixelsPerPoint: 1, windowSize: [800, 600],
            createdAt: Date(timeIntervalSince1970: 0), generation: "s1",
            elements: elements
        )
    }

    @Test func exactPathWins() {
        let snapshot = snapshot(elements: [
            SnapshotElement(id: "e0@s1", role: "AXTextField", label: nil, path: fieldPath, frame: [0, 0, 1, 1]),
            SnapshotElement(
                id: "e1@s1", role: "AXTextField", label: nil,
                path: [LocatorStep(role: "AXTextField", indexOfRole: 1)], frame: [0, 0, 1, 1]),
        ])
        let locator = SkillLocator(role: "AXTextField", label: nil, path: fieldPath)
        #expect(resolveSkillLocator(locator, in: snapshot) == .found(snapshot.elements[0], viaFallback: false))
    }

    @Test func uniqueRoleLabelFallbackSurvivesLayoutShiftAndSignalsHealing() {
        let movedPath = [LocatorStep(role: "AXGroup", indexOfRole: 0), LocatorStep(role: "AXButton", indexOfRole: 2)]
        let snapshot = snapshot(elements: [
            SnapshotElement(id: "e0@s1", role: "AXButton", label: "Save", path: movedPath, frame: [0, 0, 1, 1])
        ])
        // Saved path no longer exists; the unique Save button still resolves,
        // and viaFallback tells the executor to heal the saved path.
        let locator = SkillLocator(
            role: "AXButton", label: "Save", path: [LocatorStep(role: "AXButton", indexOfRole: 0)])
        #expect(resolveSkillLocator(locator, in: snapshot) == .found(snapshot.elements[0], viaFallback: true))
    }

    @Test func missingElementFailureNamesNearestCandidates() {
        let snapshot = snapshot(elements: [
            SnapshotElement(id: "e0@s1", role: "AXButton", label: "Export", path: fieldPath, frame: [0, 0, 1, 1]),
            SnapshotElement(
                id: "e1@s1", role: "AXButton", label: "Share",
                path: [LocatorStep(role: "AXButton", indexOfRole: 1)], frame: [0, 0, 1, 1]),
        ])
        guard case .failed(let reason) = resolveSkillLocator(
            SkillLocator(role: "AXButton", label: "Export…"), in: snapshot)
        else {
            Issue.record("expected failure")
            return
        }
        #expect(reason.contains("no element matching"))
        #expect(reason.contains("\"Export\""))
        #expect(reason.contains("\"Share\""))
    }

    @Test func missingAndAmbiguousFailWithReasons() {
        let twoButtons = snapshot(elements: [
            SnapshotElement(id: "e0@s1", role: "AXButton", label: "Save", path: fieldPath, frame: [0, 0, 1, 1]),
            SnapshotElement(
                id: "e1@s1", role: "AXButton", label: "Save",
                path: [LocatorStep(role: "AXButton", indexOfRole: 1)], frame: [0, 0, 1, 1]),
        ])
        guard case .failed(let ambiguous) = resolveSkillLocator(
            SkillLocator(role: "AXButton", label: "Save"), in: twoButtons)
        else {
            Issue.record("expected ambiguity failure")
            return
        }
        #expect(ambiguous.contains("2 elements match"))

        guard case .failed(let missing) = resolveSkillLocator(
            SkillLocator(role: "AXCheckBox", label: "Nope"), in: twoButtons)
        else {
            Issue.record("expected missing failure")
            return
        }
        #expect(missing.contains("no element matching"))
    }
}

@Suite struct SkillCodableTests {
    @Test func skillRoundTripsThroughJSON() throws {
        let skill = sampleSkill()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Skill.self, from: encoder.encode(skill))
        #expect(decoded == skill)
    }
}
