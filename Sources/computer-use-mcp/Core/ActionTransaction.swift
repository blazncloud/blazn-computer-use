// Reusable mutation-transaction state machine.
//
// The shared dispatch envelope and composite handlers use this sequencing and
// cancellation contract without coupling the pure model to AX, CoreGraphics,
// MCP delivery implementations, or a particular mutation primitive.

import Foundation
import MCP

enum ActionTransactionPhase: String, CaseIterable, Sendable {
    case resolve
    case gate
    case before
    case deliver
    case after
    case verify
    case commit
    case aborted

    fileprivate var next: ActionTransactionPhase? {
        if self == .aborted { return nil }
        guard let index = Self.allCases.firstIndex(of: self) else { return nil }
        let nextIndex = Self.allCases.index(after: index)
        guard nextIndex < Self.allCases.endIndex else { return nil }
        let candidate = Self.allCases[nextIndex]
        return candidate == .aborted ? nil : candidate
    }

    /// Cancellation is safe before delivery begins. Once delivery may have
    /// happened, the transaction must observe and commit an honest outcome.
    var isCancellationSafeBoundary: Bool {
        switch self {
        case .resolve, .gate, .before: return true
        case .deliver, .after, .verify, .commit, .aborted: return false
        }
    }
}

/// What is known about transport independently of whether an effect was seen.
enum ActionDeliveryStatus: String, Sendable {
    /// No delivery attempt has begun, or cancellation stopped it beforehand.
    case notDelivered = "not_delivered"
    /// A semantic API acknowledged the delivery operation.
    case delivered
    /// A fire-and-forget transport accepted an event for posting.
    case posted
    /// Delivery began, but the transaction cannot determine whether it landed.
    case unknown
}

/// What is known about the intended effect independently of transport.
enum ActionEffectStatus: String, Sendable {
    case verified
    case unverified
    case notChecked = "not_checked"
}

/// Commit records what remains true after the transaction. There is no rollback
/// promise: an orchestrating batch/skill can honestly report that earlier leaf
/// mutations committed before a later leaf stopped.
enum ActionCommitStatus: String, Sendable {
    case notCommitted = "not_committed"
    case committed
    case partiallyCommitted = "partially_committed"
    /// Delivery or mutation may have happened, but no structured evidence
    /// proves whether durable application state changed.
    case unknown
}

enum ActionCancellationDisposition: Equatable, Sendable {
    /// Stop now; no delivery can have occurred.
    case cancelBeforeDelivery
    /// Delivery may have occurred, so finish after/verify/commit first.
    case continueToCommit
    /// The transaction is already committed.
    case alreadyCommitted
    /// The transaction stopped before delivery.
    case alreadyAborted
}

enum ActionTransactionError: Error, Equatable, Sendable {
    case invalidTransition(from: ActionTransactionPhase, to: ActionTransactionPhase)
    case cancelledAtSafeBoundary(ActionTransactionPhase)
    case deliveryStatusBeforeDelivery(ActionTransactionPhase)
    case effectStatusBeforeVerification(ActionTransactionPhase)
    case commitStatusBeforeCommit(ActionTransactionPhase)
}

struct ActionTransaction: Equatable, Sendable {
    /// Runtime-generated correlation only; tool arguments never provide these.
    let operationID: UUID
    let parentOperationID: UUID?
    private(set) var phase: ActionTransactionPhase = .resolve
    private(set) var deliveryStatus: ActionDeliveryStatus = .notDelivered
    private(set) var effectStatus: ActionEffectStatus = .notChecked
    private(set) var commitStatus: ActionCommitStatus = .notCommitted
    private(set) var cancellationRequested = false

    /// Create a root transaction from the canonical request id supplied by the
    /// daemon protocol (or generated explicitly by the no-daemon dispatcher).
    init(rootOperationID: UUID) {
        operationID = rootOperationID
        parentOperationID = nil
    }

    /// Create a nested leaf under the current transaction. Nested ids are
    /// runtime-generated; callers never supply them through tool arguments.
    init() {
        operationID = UUID()
        parentOperationID = ActionTransactionContext.currentOperationID
    }

    var isCommitted: Bool { commitStatus != .notCommitted }
    var isAborted: Bool { phase == .aborted }

    mutating func requestCancellation() {
        cancellationRequested = true
    }

    func cancellationDisposition() -> ActionCancellationDisposition? {
        guard cancellationRequested else { return nil }
        if isCommitted { return .alreadyCommitted }
        if isAborted { return .alreadyAborted }
        return phase.isCancellationSafeBoundary ? .cancelBeforeDelivery : .continueToCommit
    }

    /// Call at cooperative boundaries. Cancellation throws only while it is
    /// still certain that delivery has not started.
    func checkCancellationAtSafeBoundary() throws {
        if cancellationDisposition() == .cancelBeforeDelivery {
            throw ActionTransactionError.cancelledAtSafeBoundary(phase)
        }
    }

    /// Advance exactly one phase. Skipping phases would lose a safety or
    /// evidence boundary, so it is rejected.
    mutating func advance(to next: ActionTransactionPhase) throws {
        try checkCancellationAtSafeBoundary()
        guard phase.next == next else {
            throw ActionTransactionError.invalidTransition(from: phase, to: next)
        }
        phase = next
    }

    mutating func recordDelivery(_ status: ActionDeliveryStatus) throws {
        guard phase == .deliver || phase == .after || phase == .verify || phase == .commit else {
            throw ActionTransactionError.deliveryStatusBeforeDelivery(phase)
        }
        deliveryStatus = status
    }

    mutating func recordEffect(_ status: ActionEffectStatus) throws {
        guard phase == .verify || phase == .commit else {
            throw ActionTransactionError.effectStatusBeforeVerification(phase)
        }
        effectStatus = status
    }

    mutating func recordCommit(_ status: ActionCommitStatus) throws {
        guard phase == .commit else {
            throw ActionTransactionError.commitStatusBeforeCommit(phase)
        }
        commitStatus = status
    }

    /// Terminal pre-delivery refusal/cancellation. This intentionally preserves
    /// not_delivered / not_checked / not_committed.
    mutating func abortBeforeDelivery() throws {
        guard phase == .resolve || phase == .gate || phase == .before else {
            throw ActionTransactionError.invalidTransition(from: phase, to: .aborted)
        }
        phase = .aborted
    }
}

/// Internal structured-concurrency lineage. A nested handler creates its own
/// transaction inside `withCurrentOperation`; external tool arguments cannot
/// choose or forge operation ids. This carries correlation only — each leaf
/// still runs its own gates and records its own delivery/effect/commit.
enum ActionTransactionContext {
    @TaskLocal static var currentOperationID: UUID?
    @TaskLocal static var depth = 0

    static func withCurrentOperation<T>(
        _ transaction: ActionTransaction,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await $currentOperationID.withValue(transaction.operationID) {
            try await $depth.withValue(depth + 1) {
                try await operation()
            }
        }
    }
}

/// Carries evidence for a composite mutation performed before its handler
/// starts (currently the daemon's stopped-app run_skill preparation).
enum CompositeCommitContext {
    @TaskLocal static var priorMutationCommitted = false
}

struct PreDeliveryCancellationError: Error, Sendable {}

final class DeliveryBoundaryTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var began = false

    func markBegan() {
        lock.lock()
        began = true
        lock.unlock()
    }

    var deliveryBegan: Bool {
        lock.lock()
        defer { lock.unlock() }
        return began
    }
}

enum DeliveryBoundaryContext {
    @TaskLocal static var tracker: DeliveryBoundaryTracker?
}

func checkCancellationBeforeDelivery() throws {
    if Task.isCancelled {
        throw PreDeliveryCancellationError()
    }
    DeliveryBoundaryContext.tracker?.markBegan()
}

let actionTransactionMetaKey = "computer-use-mcp/transaction"

extension ActionTransaction {
    var value: Value {
        var fields: [String: Value] = [
            "operation_id": .string(operationID.uuidString),
            "scope": .string("dispatch_envelope"),
            "phase": .string(phase.rawValue),
            "delivery_status": .string(deliveryStatus.rawValue),
            "effect_status": .string(effectStatus.rawValue),
            "commit_status": .string(commitStatus.rawValue),
        ]
        if let parentOperationID {
            fields["parent_operation_id"] = .string(parentOperationID.uuidString)
        }
        return .object(fields)
    }
}

extension CallTool.Result {
    func withActionTransaction(_ transaction: ActionTransaction) -> CallTool.Result {
        mergingMetaField(actionTransactionMetaKey, transaction.value)
    }

    /// Composite handlers call this only after observing that an earlier
    /// mutating leaf completed. The outer dispatch envelope consumes this
    /// evidence before replacing the nested transaction metadata.
    func withPartialCommitEvidence() -> CallTool.Result {
        withCommitEvidence(.partiallyCommitted)
    }

    func withUnknownCommitEvidence() -> CallTool.Result {
        withCommitEvidence(.unknown)
    }

    func withCommittedEvidence() -> CallTool.Result {
        withCommitEvidence(.committed)
    }

    func withNotCommittedEvidence() -> CallTool.Result {
        withCommitEvidence(.notCommitted)
    }

    private func withCommitEvidence(_ status: ActionCommitStatus) -> CallTool.Result {
        var evidence = ActionTransaction()
        while evidence.phase != .commit {
            try? evidence.advance(to: evidence.phase.next!)
        }
        try? evidence.recordCommit(status)
        return withActionTransaction(evidence)
    }
}

func applyingCompositeCommitEvidence(
    to result: CallTool.Result,
    priorMutationCommitted: Bool
) -> CallTool.Result {
    priorMutationCommitted ? result.withPartialCommitEvidence() : result
}

func applyingSuccessfulCompositeCommitEvidence(
    to result: CallTool.Result,
    definiteCommit: Bool,
    ambiguousCommit: Bool
) -> CallTool.Result {
    if definiteCommit { return result.withCommittedEvidence() }
    if ambiguousCommit { return result.withUnknownCommitEvidence() }
    return result.withNotCommittedEvidence()
}

func applyingCompositeCommitEvidence(
    to result: CallTool.Result,
    definitePriorCommit: Bool,
    ambiguousCommit: Bool
) -> CallTool.Result {
    if definitePriorCommit { return result.withPartialCommitEvidence() }
    if ambiguousCommit { return result.withUnknownCommitEvidence() }
    return result
}

/// Composite handlers use the structured outcome when present. Legacy
/// non-error leaves without an outcome remain compatible.
func leafResultSucceeded(_ result: CallTool.Result, isMutating: Bool) -> Bool {
    guard result.isError != true else { return false }
    if case .object(let outcome)? = result._meta?[actionOutcomeMetaKey],
        let classification = outcome["classification"]?.stringValue
    {
        return classification == ActionClassification.success.rawValue
    }
    guard isMutating else { return true }
    guard case .object(let transaction)? = result._meta?[actionTransactionMetaKey],
        transaction["commit_status"]?.stringValue == ActionCommitStatus.committed.rawValue
    else { return false }
    return true
}

/// Terminal leaves have no dependent mutation to authorize. Preserve legacy
/// final-only tools, while still rejecting any explicit structured failure.
func finalLeafResultAccepted(_ result: CallTool.Result) -> Bool {
    guard result.isError != true else { return false }
    guard case .object(let outcome)? = result._meta?[actionOutcomeMetaKey],
        let classification = outcome["classification"]?.stringValue
    else { return true }
    return classification == ActionClassification.success.rawValue
}

/// Whether a completed leaf may have changed durable application state.
/// Unknown is deliberately sticky: a composite must not advertise safe retry
/// when delivery may already have happened.
enum LeafCommitEvidence: Equatable {
    case none
    case definite
    case unknown
}

func leafCommitEvidence(_ result: CallTool.Result) -> LeafCommitEvidence {
    guard case .object(let transaction)? = result._meta?[actionTransactionMetaKey],
        let rawStatus = transaction["commit_status"]?.stringValue,
        let status = ActionCommitStatus(rawValue: rawStatus)
    else { return .none }
    switch status {
    case .committed, .partiallyCommitted: return .definite
    case .unknown: return .unknown
    case .notCommitted: return .none
    }
}
