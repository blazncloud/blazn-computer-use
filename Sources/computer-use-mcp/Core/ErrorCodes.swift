// Structured error codes for the driving agent.
//
// Tool errors surface as human prose, which an agent must parse case-by-case to
// decide what to do next. We tag each recoverable/thrown error at the dispatch
// boundary with a stable machine-readable code and a one-line recovery hint, so
// an agent can branch on `code` (retry with a fresh id, confirm, wait, open the
// app) without string-matching the message. The code rides as a `[CODE]` prefix
// on the error text and as a `computer-use-mcp/error` _meta field. isError is
// unchanged — coding is classification, not a new failure.

import Foundation
import MCP

/// Machine-readable classification of a tool error. rawValue is the wire code.
enum ToolErrorCode: String, Sendable, CaseIterable {
    case staleElement = "STALE_ELEMENT"
    case ambiguousTarget = "AMBIGUOUS_TARGET"
    case confirmationRequired = "CONFIRMATION_REQUIRED"
    case policyDenied = "POLICY_DENIED"
    case screenLocked = "SCREEN_LOCKED"
    case userInterference = "USER_INTERFERENCE"
    case appNotFound = "APP_NOT_FOUND"
    case elementNotFound = "ELEMENT_NOT_FOUND"
    case notSettable = "NOT_SETTABLE"
    case offscreenTarget = "OFFSCREEN_TARGET"
    case appLeaseHeld = "APP_LEASE_HELD"
    case daemonUnauthorized = "DAEMON_UNAUTHORIZED"
    case daemonUnavailable = "DAEMON_UNAVAILABLE"
    case daemonVersionMismatch = "DAEMON_VERSION_MISMATCH"
    case daemonResultUnknown = "DAEMON_RESULT_UNKNOWN"

    /// One-line, agent-directed next step for this failure class.
    var recovery: String {
        switch self {
        case .staleElement:
            return "The UI changed; call get_app_state and use a fresh element id."
        case .ambiguousTarget:
            return "Narrow the target — use a specific element id, or a more distinctive label."
        case .confirmationRequired:
            return "Re-run the same call with \"confirm\": true to proceed."
        case .policyDenied:
            return "Blocked by policy and not overridable with confirm; adjust the configuration if intended."
        case .screenLocked:
            return "Ask the user to unlock the Mac, then retry; read-only tools remain available."
        case .userInterference:
            return "The user is active in the target app; wait a moment and retry."
        case .appNotFound:
            return "Open or launch the app first (see list_apps), then retry."
        case .elementNotFound:
            return "Call get_app_state and use an element id from its latest result."
        case .notSettable:
            return "The element takes no direct value; use click or type_text, or target an editable field."
        case .offscreenTarget:
            return "The element has no on-screen frame; scroll it into view or target a visible element."
        case .appLeaseHeld:
            return "Wait for the other agent session's app lease to expire, or target a different app."
        case .daemonUnauthorized:
            return "Reconnect with a current CLI that can authenticate to the local engine daemon."
        case .daemonUnavailable:
            return "Retry after the local engine daemon is available."
        case .daemonVersionMismatch:
            return "Use matching computer-use-mcp client and daemon versions, then retry."
        case .daemonResultUnknown:
            return "Inspect fresh app state and reconcile the prior mutation before deciding whether to retry."
        }
    }
}

/// Ordered (fragment, code) rules matched against an error message. Fragments
/// are stable phrases from the real throw sites (Core/Snapshot, Core/Target,
/// Core/AppResolver, Tools/TextTools, Core/PointTarget, Core/URLPolicy,
/// Core/SessionPower, Core/InterferenceGuard). Order matters: earlier, more
/// specific rules win. Case-insensitive.
private let errorCodeRules: [(fragment: String, code: ToolErrorCode)] = [
    ("is stale:", .staleElement),
    ("older app state", .staleElement),
    ("is not an element id", .elementNotFound),
    ("no app state captured", .elementNotFound),
    ("is not running", .appNotFound),
    ("no app named", .appNotFound),
    ("has quit or crashed", .appNotFound),
    ("not editable via accessibility", .notSettable),
    ("does not accept a direct value", .notSettable),
    ("could not set the value", .notSettable),
    ("has no screen position", .offscreenTarget),
    ("exposes no frame", .offscreenTarget),
    ("denied by url policy", .policyDenied),
    ("screen is locked", .screenLocked),
    ("user activity detected", .userInterference),
    ("matches multiple", .ambiguousTarget),
    ("is ambiguous", .ambiguousTarget),
    ("confirmation required", .confirmationRequired),
    ("another agent session is mid-task", .appLeaseHeld),
    ("unauthorized daemon request", .daemonUnauthorized),
    ("shutdown refused: requester build", .daemonUnauthorized),
    ("engine daemon is newer", .daemonVersionMismatch),
    ("daemon handshake did not return a version", .daemonVersionMismatch),
    ("daemon mutation result is unknown", .daemonResultUnknown),
]

/// Classify an error message into a code, or nil when nothing matches (the
/// message is passed through uncoded). Pure, so the mapping is unit-tested.
func toolErrorCode(forMessage message: String) -> ToolErrorCode? {
    let lowered = message.lowercased()
    return errorCodeRules.first { lowered.contains($0.fragment) }?.code
}

/// Classify a thrown error: the safety-confirmation type is authoritative
/// (CONFIRMATION_REQUIRED), otherwise fall back to message classification.
func toolErrorCode(for error: Error) -> ToolErrorCode? {
    if error is SafetyError { return .confirmationRequired }
    return toolErrorCode(forMessage: "\(error)")
}

/// Build an error result, tagging it with a `[CODE]` prefix and a
/// `computer-use-mcp/error` _meta block when a code was classified. Uncoded
/// messages pass through unchanged. Always isError.
func codedErrorResult(_ message: String, code: ToolErrorCode?) -> CallTool.Result {
    guard let code else { return .text(message, isError: true) }
    return CallTool.Result.text("[\(code.rawValue)] \(message)", isError: true)
        .mergingMetaField(
            "computer-use-mcp/error",
            .object([
                "code": .string(code.rawValue),
                "recovery": .string(code.recovery),
            ]))
}
