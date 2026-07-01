// Skill model: a named, parameterized, assertion-bearing action sequence that
// replays deterministically — no model in the loop on the happy path.
//
// Steps are anchored by locators (role + label + locator path), not element
// ids or pixels: ids expire with app restarts, but a locator re-resolves
// against the live tree the same way action tools already re-resolve ids.
// Parameters appear as {{name}} placeholders in any string argument and are
// substituted at run time.

import Foundation
import MCP

struct SkillParam: Codable, Equatable {
    let name: String
    let description: String
}

/// Durable element anchor. Resolution order: exact locator path (with role
/// and label verified), then unique role+label match anywhere in the tree —
/// the fallback that survives layout shifts.
struct SkillLocator: Codable, Equatable {
    let role: String
    var label: String? = nil
    var path: [LocatorStep]? = nil
}

/// Post-condition checked after a step, in wait_for terms. A step whose
/// expectation fails stops the replay with a repairable report.
struct SkillExpectation: Codable, Equatable {
    var role: String? = nil
    var label: String? = nil
    var valueContains: String? = nil
    var gone: Bool? = nil
    var timeoutSeconds: Double? = nil
}

struct SkillStep: Codable, Equatable {
    let tool: String
    var locator: SkillLocator? = nil
    var arguments: [String: Value] = [:]
    var expect: SkillExpectation? = nil
}

struct Skill: Codable, Equatable {
    let name: String
    let description: String
    /// Target app (name or bundle id) — one app per skill, like batch.
    let app: String
    var params: [SkillParam] = []
    let steps: [SkillStep]
    var updatedAt: Date? = nil
}

let maxSkillSteps = 25

/// Step tools a skill may contain: the batchable set (app-scoped actions +
/// wait_for; never batch or run_skill themselves).
var skillStepToolNames: Set<String> { batchableToolNames }

enum SkillValidationError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String {
        switch self {
        case .invalid(let message): return message
        }
    }
}

func validateSkill(_ skill: Skill) throws {
    guard skill.name.wholeMatch(of: /[a-z0-9][a-z0-9-]{0,63}/) != nil else {
        throw SkillValidationError.invalid(
            "Skill names are 1-64 chars of lowercase letters, digits, and hyphens (got \"\(skill.name)\").")
    }
    guard !skill.steps.isEmpty else {
        throw SkillValidationError.invalid("A skill needs at least one step.")
    }
    guard skill.steps.count <= maxSkillSteps else {
        throw SkillValidationError.invalid("Skills are limited to \(maxSkillSteps) steps (got \(skill.steps.count)).")
    }
    for (index, step) in skill.steps.enumerated() where !skillStepToolNames.contains(step.tool) {
        throw SkillValidationError.invalid(
            "steps[\(index)]: \"\(step.tool)\" cannot be a skill step. Allowed: "
                + skillStepToolNames.sorted().joined(separator: ", ") + ".")
    }
    for param in skill.params where param.name.wholeMatch(of: /[a-z0-9_]{1,32}/) == nil {
        throw SkillValidationError.invalid(
            "Param names are 1-32 chars of lowercase letters, digits, and underscores (got \"\(param.name)\").")
    }
}

// MARK: - parameter templating

/// Replace {{name}} placeholders in every string of a Value tree.
func substituteParams(_ value: Value, params: [String: String]) -> Value {
    switch value {
    case .string(let text):
        return .string(substituteParams(in: text, params: params))
    case .array(let items):
        return .array(items.map { substituteParams($0, params: params) })
    case .object(let fields):
        return .object(fields.mapValues { substituteParams($0, params: params) })
    default:
        return value
    }
}

func substituteParams(in text: String, params: [String: String]) -> String {
    var result = text
    for (name, value) in params {
        result = result.replacingOccurrences(of: "{{\(name)}}", with: value)
    }
    return result
}

/// Placeholders still present after substitution (unknown or missing params).
func unresolvedPlaceholders(_ value: Value) -> [String] {
    switch value {
    case .string(let text):
        return text.matches(of: /\{\{([a-z0-9_]+)\}\}/).map { String($0.1) }
    case .array(let items):
        return items.flatMap(unresolvedPlaceholders)
    case .object(let fields):
        return fields.values.flatMap(unresolvedPlaceholders)
    default:
        return []
    }
}

// MARK: - locator resolution

enum SkillLocatorResolution: Equatable {
    case found(SnapshotElement)
    case failed(String)
}

extension SnapshotElement: Equatable {
    static func == (lhs: SnapshotElement, rhs: SnapshotElement) -> Bool {
        lhs.id == rhs.id && lhs.role == rhs.role && lhs.label == rhs.label && lhs.path == rhs.path
    }
}

/// Resolve a locator against the latest snapshot. Exact path first (role and
/// label verified), then a unique role+label match anywhere in the tree.
func resolveSkillLocator(
    _ locator: SkillLocator, in snapshot: AppSnapshot
) -> SkillLocatorResolution {
    if let path = locator.path,
        let element = snapshot.elements.first(where: { $0.path == path }),
        element.role == locator.role,
        locator.label == nil || element.label == locator.label
    {
        return .found(element)
    }
    let candidates = snapshot.elements.filter { element in
        element.role == locator.role && (locator.label == nil || element.label == locator.label)
    }
    let described = "\(locator.role)\(locator.label.map { " \"\($0)\"" } ?? "")"
    switch candidates.count {
    case 1:
        return .found(candidates[0])
    case 0:
        return .failed("no element matching \(described) is in the current tree")
    default:
        return .failed(
            "\(candidates.count) elements match \(described) and the saved path matches none of them "
                + "— the locator is ambiguous; re-save this step with a more specific label or a fresh element_id")
    }
}
