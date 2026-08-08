import Foundation
import ApplicationServices
import MCP
import Testing

@testable import computer_use_mcp

@Suite struct ActionTransactionTests {
    @Test func transactionAdvancesThroughEveryRequiredPhase() throws {
        var transaction = ActionTransaction()

        for phase in ActionTransactionPhase.allCases.dropFirst().filter({ $0 != .aborted }) {
            try transaction.advance(to: phase)
        }

        #expect(transaction.phase == .commit)
        #expect(!transaction.isCommitted)
        #expect(transaction.deliveryStatus == .notDelivered)
        #expect(transaction.effectStatus == .notChecked)
        #expect(transaction.commitStatus == .notCommitted)
    }

    @Test func transactionRejectsSkippedAndBackwardPhases() {
        var transaction = ActionTransaction()

        #expect(throws: ActionTransactionError.invalidTransition(from: .resolve, to: .before)) {
            try transaction.advance(to: .before)
        }
        #expect(transaction.phase == .resolve)
    }

    @Test func cancellationStopsAtEveryPreDeliveryBoundary() throws {
        for phase in [ActionTransactionPhase.resolve, .gate, .before] {
            var transaction = ActionTransaction()
            while transaction.phase != phase {
                try transaction.advance(to: transaction.phase.nextForTesting)
            }
            transaction.requestCancellation()

            #expect(transaction.cancellationDisposition() == .cancelBeforeDelivery)
            #expect(throws: ActionTransactionError.cancelledAtSafeBoundary(phase)) {
                try transaction.checkCancellationAtSafeBoundary()
            }
            #expect(transaction.deliveryStatus == .notDelivered)
        }
    }

    @Test func cancellationAfterDeliveryDefersUntilCommit() throws {
        var transaction = ActionTransaction()
        try advance(&transaction, through: .deliver)
        try transaction.recordDelivery(.posted)
        transaction.requestCancellation()

        #expect(transaction.cancellationDisposition() == .continueToCommit)
        try transaction.checkCancellationAtSafeBoundary()
        try transaction.advance(to: .after)
        try transaction.advance(to: .verify)
        try transaction.recordEffect(.unverified)
        try transaction.advance(to: .commit)
        try transaction.recordCommit(.committed)

        #expect(transaction.cancellationDisposition() == .alreadyCommitted)
        #expect(transaction.deliveryStatus == .posted)
        #expect(transaction.effectStatus == .unverified)
        #expect(transaction.commitStatus == .committed)
    }

    @Test func deliveryAndEffectStatusesRemainIndependent() throws {
        for delivery in [
            ActionDeliveryStatus.notDelivered, .delivered, .posted, .unknown,
        ] {
            for effect in [
                ActionEffectStatus.verified, .unverified, .notChecked,
            ] {
                var transaction = ActionTransaction()
                try advance(&transaction, through: .verify)
                try transaction.recordDelivery(delivery)
                try transaction.recordEffect(effect)

                #expect(transaction.deliveryStatus == delivery)
                #expect(transaction.effectStatus == effect)
            }
        }
    }

    @Test func statusRecordingRespectsEvidencePhases() {
        var transaction = ActionTransaction()

        #expect(throws: ActionTransactionError.deliveryStatusBeforeDelivery(.resolve)) {
            try transaction.recordDelivery(.delivered)
        }
        #expect(throws: ActionTransactionError.effectStatusBeforeVerification(.resolve)) {
            try transaction.recordEffect(.verified)
        }
        #expect(throws: ActionTransactionError.commitStatusBeforeCommit(.resolve)) {
            try transaction.recordCommit(.committed)
        }
    }

    @Test func preDeliveryAbortIsTerminalAndUncommitted() throws {
        var transaction = ActionTransaction(rootOperationID: UUID())
        try transaction.advance(to: .gate)
        transaction.requestCancellation()
        try transaction.abortBeforeDelivery()

        #expect(transaction.phase == .aborted)
        #expect(transaction.deliveryStatus == .notDelivered)
        #expect(transaction.effectStatus == .notChecked)
        #expect(transaction.commitStatus == .notCommitted)
        #expect(transaction.cancellationDisposition() == .alreadyAborted)
        #expect(throws: ActionTransactionError.invalidTransition(from: .aborted, to: .before)) {
            try transaction.advance(to: .before)
        }
    }

    @Test func partialCommitDoesNotImplyRollback() throws {
        var transaction = ActionTransaction()
        try advance(&transaction, through: .commit)
        try transaction.recordCommit(.partiallyCommitted)

        #expect(transaction.commitStatus == .partiallyCommitted)
        #expect(transaction.isCommitted)
    }

    @Test func taskLocalLineageIsGeneratedAndInheritedByChildren() async throws {
        let parent = ActionTransaction()
        let child = await ActionTransactionContext.withCurrentOperation(parent) {
            ActionTransaction()
        }
        let unrelated = ActionTransaction()

        #expect(child.parentOperationID == parent.operationID)
        #expect(child.operationID != parent.operationID)
        #expect(unrelated.parentOperationID == nil)
    }

    @Test func canonicalRootIDIsPreservedAndSerialized() {
        let canonical = UUID()
        let transaction = ActionTransaction(rootOperationID: canonical)
        #expect(transaction.operationID == canonical)
        #expect(transaction.parentOperationID == nil)

        let result = CallTool.Result.text("ok").withActionTransaction(transaction)
        guard case .object(let fields)? = result._meta?[actionTransactionMetaKey] else {
            Issue.record("missing transaction metadata")
            return
        }
        #expect(fields["operation_id"]?.stringValue == canonical.uuidString)
        #expect(fields["parent_operation_id"] == nil)
    }

    @Test func nestedDispatchDepthCreatesChildrenUnderCanonicalRoot() async {
        let canonical = UUID()
        let root = ActionTransaction(rootOperationID: canonical)
        let child = await ActionTransactionContext.withCurrentOperation(root) {
            #expect(ActionTransactionContext.depth == 1)
            return ActionTransaction()
        }

        #expect(child.parentOperationID == canonical)
        #expect(child.operationID != canonical)
        #expect(ActionTransactionContext.depth == 0)
    }

    private func advance(
        _ transaction: inout ActionTransaction, through target: ActionTransactionPhase
    ) throws {
        while transaction.phase != target {
            try transaction.advance(to: transaction.phase.nextForTesting)
        }
    }
}

@Suite struct DispatchTransactionContractTests {
    @Test func refusalAndCancellationMetadataStayUncommitted() {
        let root = ActionTransaction(rootOperationID: UUID())
        let (refused, refusalResult) = abortedTransaction(
            transaction: root, result: .text("refused", isError: true),
            cancellationRequested: false)
        let (cancelled, cancellationResult) = abortedTransaction(
            transaction: root, result: .text("cancelled", isError: true),
            cancellationRequested: true)

        for (transaction, result) in [
            (refused, refusalResult), (cancelled, cancellationResult),
        ] {
            #expect(transaction.phase == .aborted)
            #expect(transaction.deliveryStatus == .notDelivered)
            #expect(transaction.effectStatus == .notChecked)
            #expect(transaction.commitStatus == .notCommitted)
            guard case .object(let fields)? = result._meta?[actionTransactionMetaKey] else {
                Issue.record("missing transaction metadata")
                continue
            }
            #expect(fields["delivery_status"]?.stringValue == "not_delivered")
            #expect(fields["effect_status"]?.stringValue == "not_checked")
            #expect(fields["commit_status"]?.stringValue == "not_committed")
        }
    }

    @Test func dispatchUsesDaemonCanonicalRootAndNestedChildLineage() async {
        let canonical = UUID()
        let root = DaemonSessionContext.$operationID.withValue(canonical) {
            makeActionTransactionForDispatch(generatedOperationID: UUID())
        }
        let child = await DaemonSessionContext.$operationID.withValue(canonical) {
            await ActionTransactionContext.withCurrentOperation(root) {
                makeActionTransactionForDispatch(generatedOperationID: UUID())
            }
        }

        #expect(root.operationID == canonical)
        #expect(root.parentOperationID == nil)
        #expect(child.operationID != canonical)
        #expect(child.parentOperationID == canonical)
    }

    @Test func internalDispatchRootUsesGeneratedOperationID() {
        let local = UUID()
        let transaction = makeActionTransactionForDispatch(generatedOperationID: local)
        #expect(transaction.operationID == local)
        #expect(transaction.parentOperationID == nil)
    }

    @Test func deliveryStatusDistinguishesPostedFromAcknowledged() {
        let posted = CallTool.Result.text("ok").mergingMetaField(
            "computer-use-mcp/delivery",
            .object(["delivery_tier": .string(InputTier.perPid.rawValue)]))
        let delivered = CallTool.Result.text("ok").mergingMetaField(
            "computer-use-mcp/delivery",
            .object(["delivery_tier": .string(InputTier.accessibilityAction.rawValue)]))

        #expect(deliveryStatus(for: posted) == .posted)
        #expect(deliveryStatus(for: delivered) == .delivered)
        #expect(deliveryStatus(for: .text("error", isError: true)) == .unknown)
    }

    @Test func effectStatusUsesStructuredOutcomeOnly() {
        let verified = CallTool.Result.text("ok").withActionOutcome(.success("landed"))
        let unverified = CallTool.Result.text("ok").withActionOutcome(
            .effectNotVerified(.verification, "not observed"))

        #expect(effectStatus(for: verified) == .verified)
        #expect(effectStatus(for: unverified) == .unverified)
        #expect(effectStatus(for: .text("generic activation")) == .notChecked)
    }

    @Test func handlerErrorWithoutStructuredEvidenceStaysUnknown() {
        let error = CallTool.Result.text("handler failed", isError: true)
        #expect(deliveryStatus(for: error) == .unknown)
        #expect(commitStatus(for: error, tool: "click") == .unknown)
        #expect(commitStatus(for: error, tool: "batch") == .unknown)
        #expect(commitStatus(for: error, tool: "run_skill") == .unknown)
    }

    @Test func errorPreservesExplicitDeliveryAndPartialCommitEvidence() throws {
        let result = CallTool.Result.text("later verification failed", isError: true)
            .mergingMetaField(
                "computer-use-mcp/delivery",
                .object(["delivery_tier": .string(InputTier.accessibilityAction.rawValue)]))
            .withPartialCommitEvidence()

        #expect(deliveryStatus(for: result) == .delivered)
        #expect(commitStatus(for: result, tool: "batch") == .partiallyCommitted)
    }

    @Test func daemonPrelaunchEvidenceSurvivesLaterCompositeFailures() {
        for message in [
            "target app did not become controllable in time",
            "missing required params",
            "first replay step failed",
        ] {
            let result = applyingCompositeCommitEvidence(
                to: .text(message, isError: true),
                priorMutationCommitted: true)
            #expect(commitStatus(for: result, tool: "run_skill") == .partiallyCommitted)
        }
    }

    @Test func failedPrelaunchDoesNotClaimPartialCommit() {
        let result = applyingCompositeCommitEvidence(
            to: .text("launch failed", isError: true),
            priorMutationCommitted: false)
        #expect(commitStatus(for: result, tool: "run_skill") == .unknown)
    }

    @Test func unsupportedNonErrorDoesNotClaimDeliveryOrCommit() {
        let result = CallTool.Result.text("disabled")
            .mergingMetaField(
                "computer-use-mcp/delivery",
                .object(["delivery_tier": .string(InputTier.accessibilityAction.rawValue)]))
            .withActionOutcome(
                ActionOutcome.unsupported(.unsupported, "disabled")
                    .withDispatchSucceeded(false))

        #expect(deliveryStatus(for: result) == .notDelivered)
        #expect(commitStatus(for: result, tool: "click") == .notCommitted)
    }

    @Test func deliveryTierDoesNotOverrideExplicitDispatchFailure() {
        let result = CallTool.Result.text("not dispatched")
            .mergingMetaField(
                "computer-use-mcp/delivery",
                .object([
                    "delivery_tier": .string(InputTier.accessibilityAction.rawValue),
                    "dispatch_succeeded": .bool(false),
                ]))
        #expect(deliveryStatus(for: result) == .notDelivered)
        #expect(commitStatus(for: result, tool: "click") == .notCommitted)
    }

    @Test func verifiedDispatchedSuccessIsCommitted() {
        let result = CallTool.Result.text("done")
            .withActionOutcome(
                ActionOutcome.success("verified")
                    .withDispatchSucceeded(true))
        #expect(effectStatus(for: result) == .verified)
        #expect(commitStatus(for: result, tool: "click") == .committed)
    }

    @Test func postDeliveryErrorPreservesTransportButCommitStaysUnknown() {
        for (tier, expected): (InputTier, ActionDeliveryStatus) in [
            (.accessibilityAction, .delivered),
            (.perPid, .posted),
        ] {
            let result = CallTool.Result.text("recapture failed", isError: true)
                .mergingMetaField(
                    "computer-use-mcp/delivery",
                    .object(["delivery_tier": .string(tier.rawValue)]))
            #expect(deliveryStatus(for: result) == expected)
            #expect(commitStatus(for: result, tool: "click") == .unknown)
        }
    }

    @Test func compositeUnknownEvidenceIsNotPromotedToPartialCommit() {
        let unknown = applyingCompositeCommitEvidence(
            to: .text("leaf outcome unknown", isError: true),
            definitePriorCommit: false,
            ambiguousCommit: true)
        let definite = applyingCompositeCommitEvidence(
            to: .text("later leaf failed", isError: true),
            definitePriorCommit: true,
            ambiguousCommit: true)

        #expect(commitStatus(for: unknown, tool: "run_skill") == .unknown)
        #expect(commitStatus(for: definite, tool: "run_skill") == .partiallyCommitted)
        #expect(leafCommitEvidence(unknown) == .unknown)
        #expect(leafCommitEvidence(definite) == .definite)
    }

    @Test func cancellationCheckRefusesPrimitiveBoundary() async {
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            do {
                try checkCancellationBeforeDelivery()
                return false
            } catch {
                return error is PreDeliveryCancellationError
            }
        }
        task.cancel()
        #expect(await task.value)
    }

    @Test func cancelledAXActionBoundaryDoesNotInvokePrimitive() async {
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            var invoked = false
            do {
                _ = try performAXActionPrimitive {
                    invoked = true
                    return .success
                }
                return false
            } catch {
                return !invoked && error is PreDeliveryCancellationError
            }
        }
        task.cancel()
        #expect(await task.value)
    }

    @Test func verifiedWindowMutationCarriesCommitEvidence() {
        let result = CallTool.Result.text("moved")
            .withActionOutcome(
                ActionOutcome.success("window moved")
                    .withDispatchSucceeded(true))
        #expect(commitStatus(for: result, tool: "manage_window") == .committed)
    }

    @Test func preDeliveryHandlerSignalAbortsButGenericCancellationDoesNot() {
        let classified = handlerErrorResult(PreDeliveryCancellationError())
        #expect(classified.preDeliveryCancellation)
        let root = ActionTransaction(rootOperationID: UUID())
        let (aborted, result) = abortedTransaction(
            transaction: root,
            result: classified.result,
            cancellationRequested: true)
        #expect(aborted.phase == .aborted)
        #expect(aborted.deliveryStatus == .notDelivered)
        #expect(aborted.commitStatus == .notCommitted)
        guard case .object(let fields)? = result._meta?[actionTransactionMetaKey] else {
            Issue.record("missing transaction metadata")
            return
        }
        #expect(fields["phase"]?.stringValue == "aborted")
        #expect(fields["delivery_status"]?.stringValue == "not_delivered")
        #expect(fields["commit_status"]?.stringValue == "not_committed")

        let generic = handlerErrorResult(CancellationError())
        #expect(!generic.preDeliveryCancellation)
        #expect(deliveryStatus(for: generic.result) == .unknown)
        #expect(commitStatus(for: generic.result, tool: "click") == .unknown)
    }

    @Test func cancellationAfterFirstAXPressIsPostDeliveryUnknown() async {
        let result = await Task {
            var pressCount = 0
            do {
                try await performRepeatedAXPress(
                    count: 2,
                    primitive: {
                        pressCount += 1
                        return .success
                    },
                    betweenPresses: {
                        withUnsafeCurrentTask { $0?.cancel() }
                    },
                    failureMessage: "test")
                return (pressCount, false, false)
            } catch {
                let classified = handlerErrorResult(error)
                return (
                    pressCount,
                    classified.preDeliveryCancellation,
                    commitStatus(for: classified.result, tool: "click") == .unknown)
            }
        }.value

        #expect(result.0 == 1)
        #expect(!result.1)
        #expect(result.2)
    }

    @Test func menuCommandWithoutWindowReturnsHonestOutcome() {
        let dispatched = ActionVerifier(
            family: .menu, intent: .openMenu,
            deliveryTier: InputTier.accessibilityAction.rawValue,
            dispatchSucceeded: true, hasTargetElement: false,
            snapshotElement: nil)
        let result = menuItemNoWindowResult(
            note: "Selected File > New Window.",
            focusTelemetry: nil,
            verifier: dispatched)
        #expect(result.isError != true)
        #expect(effectStatus(for: result) == .unverified)
        #expect(commitStatus(for: result, tool: "click_menu_item") == .unknown)

        let disabled = ActionVerifier(
            family: .menu, intent: .openMenu,
            deliveryTier: InputTier.accessibilityAction.rawValue,
            dispatchSucceeded: false, hasTargetElement: false,
            snapshotElement: nil,
            resolved: .unsupported(.unsupported, "disabled"))
        let disabledResult = menuItemNoWindowResult(
            note: "Disabled.", focusTelemetry: nil, verifier: disabled)
        #expect(deliveryStatus(for: disabledResult) == .notDelivered)
        #expect(commitStatus(for: disabledResult, tool: "click_menu_item") == .notCommitted)
    }

    @Test func handlerErrorUsesDeliveryBoundaryEvidence() throws {
        let before = DeliveryBoundaryTracker()
        let missingTarget = codedErrorResult("missing element", code: nil)
        #expect(shouldAbortBeforeDelivery(result: missingTarget, tracker: before))

        let after = DeliveryBoundaryTracker()
        try DeliveryBoundaryContext.$tracker.withValue(after) {
            try checkCancellationBeforeDelivery()
        }
        let recaptureFailure = codedErrorResult("recapture failed", code: nil)
        #expect(!shouldAbortBeforeDelivery(result: recaptureFailure, tracker: after))
        #expect(deliveryStatus(for: recaptureFailure) == .unknown)
        #expect(commitStatus(for: recaptureFailure, tool: "click") == .unknown)

        let explicit = missingTarget.mergingMetaField(
            "computer-use-mcp/delivery",
            .object(["dispatch_succeeded": .bool(false)]))
        #expect(!shouldAbortBeforeDelivery(result: explicit, tracker: before))
    }

    @Test func preDeliverySignalAfterPriorBoundaryIsNotSafeAbort() throws {
        let tracker = DeliveryBoundaryTracker()
        try DeliveryBoundaryContext.$tracker.withValue(tracker) {
            try checkCancellationBeforeDelivery()
        }
        let classified = handlerErrorResult(PreDeliveryCancellationError())
        #expect(classified.preDeliveryCancellation)
        #expect(!shouldAbortForPreDeliverySignal(
            signalled: classified.preDeliveryCancellation,
            tracker: tracker))
        #expect(!shouldAbortBeforeDelivery(result: classified.result, tracker: tracker))
        #expect(deliveryStatus(for: classified.result) == .unknown)
        #expect(commitStatus(for: classified.result, tool: "click") == .unknown)
    }

    @Test func cancelledPageInsertAfterProbeDoesNotInvokeExecutor() async {
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            var invoked = false
            do {
                try await executePageInsertAfterProbe { invoked = true }
                return false
            } catch {
                return !invoked && error is PreDeliveryCancellationError
            }
        }
        task.cancel()
        #expect(await task.value)
    }

    @Test func cancelledSystemAndChainPrimitivesAreNotInvoked() async {
        let system = Task {
            while !Task.isCancelled { await Task.yield() }
            var invoked = false
            do {
                _ = try performSystemMutation { invoked = true }
                return false
            } catch {
                return !invoked && error is PreDeliveryCancellationError
            }
        }
        system.cancel()
        #expect(await system.value)

        let chain = Task {
            while !Task.isCancelled { await Task.yield() }
            var invoked = false
            do {
                _ = try performChainPrimitive {
                    invoked = true
                    return true
                }
                return false
            } catch {
                return !invoked && error is PreDeliveryCancellationError
            }
        }
        chain.cancel()
        #expect(await chain.value)
    }

    @Test func confirmedSystemMutationOutcomeIsCommitted() {
        let result = CallTool.Result.text("opened")
            .withActionOutcome(
                ActionOutcome.success("opened")
                    .withDispatchSucceeded(true))
        #expect(commitStatus(for: result, tool: "open_url") == .committed)
    }

    @Test func compositeCommitTaskLocalIsScoped() {
        #expect(!CompositeCommitContext.priorMutationCommitted)
        CompositeCommitContext.$priorMutationCommitted.withValue(true) {
            #expect(CompositeCommitContext.priorMutationCommitted)
        }
        #expect(!CompositeCommitContext.priorMutationCommitted)
    }
}

private extension ActionTransactionPhase {
    var nextForTesting: ActionTransactionPhase {
        let index = Self.allCases.firstIndex(of: self)!
        return Self.allCases[Self.allCases.index(after: index)]
    }
}

@Suite struct ActionPredicateTests {
    @Test func valuePredicatesAreTypedAndNilSafe() {
        #expect(ActionPredicates.value("hello", equals: "hello"))
        #expect(!ActionPredicates.value(nil, equals: "hello"))
        #expect(ActionPredicates.value("say hello", contains: "hello"))
        #expect(!ActionPredicates.value(nil, contains: "hello"))
    }

    @Test func selectionAndFocusPredicatesRequireObservedEvidence() {
        #expect(ActionPredicates.selection(true, equals: true))
        #expect(!ActionPredicates.selection(nil, equals: false))
        #expect(ActionPredicates.number("4.5", equals: 4.5))
        #expect(!ActionPredicates.number(nil, equals: 4.5))
        #expect(ActionPredicates.focused(true))
        #expect(!ActionPredicates.focused(true, rereadFailed: true))
        #expect(!ActionPredicates.focused(nil))
    }

    @Test func framePredicateUsesExplicitTolerance() {
        #expect(!ActionPredicates.frameChanged(from: (10, 20), to: (11, 21), tolerance: 2))
        #expect(ActionPredicates.frameChanged(from: (10, 20), to: (13, 20), tolerance: 2))
    }

    @Test func windowPredicateMatchesExistingSignals() {
        var verification = ActionVerification()
        #expect(!ActionPredicates.windowChanged(verification))
        verification.windowTitleChanged = true
        #expect(ActionPredicates.windowChanged(verification))
    }

    @Test func scrollPredicateExcludesUnrelatedWindowChurn() {
        var verification = ActionVerification()
        verification.renderedTextChanged = true
        #expect(!ActionPredicates.scrollMoved(verification))
        verification.scrollContentChanged = true
        #expect(ActionPredicates.scrollMoved(verification))
    }
}
