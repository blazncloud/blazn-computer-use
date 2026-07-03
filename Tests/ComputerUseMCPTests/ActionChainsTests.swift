import Testing

@testable import computer_use_mcp

/// Deterministic tests for the pure chain fall-through state machine and the
/// per-rung effect predicate. The live AX perform/verify is proven on the
/// fixture; these lock the branching logic.
@Suite struct ActionChainsTests {
    // A three-rung synthetic chain, addressed by id in the attempt closures.
    private let rungs: [ChainRung] = [
        ChainRung(id: "a", scope: .selfElement, action: .axAction("A"), unverifiedReason: .chainAXPressUnverified),
        ChainRung(id: "b", scope: .selfElement, action: .axAction("B"), unverifiedReason: .chainAXConfirmUnverified),
        ChainRung(id: "c", scope: .selfElement, action: .axAction("C"), unverifiedReason: .chainAXOpenUnverified),
    ]

    private func run(_ outcomes: [String: RungAttempt]) async -> ChainResult {
        await runActionChain(rungs) { rung in outcomes[rung.id] ?? .skipped }
    }

    @Test func firstRungLandsWins() async {
        let result = await run(["a": .landed, "b": .landed])
        #expect(result.landedRungID == "a")
        #expect(result.firedUnverifiedRungIDs.isEmpty)
    }

    @Test func skippedRungsAreSkippedNotCounted() async {
        // a does not apply, b lands.
        let result = await run(["a": .skipped, "b": .landed])
        #expect(result.landedRungID == "b")
        #expect(result.firedUnverifiedRungIDs.isEmpty)
    }

    @Test func firedUnverifiedCascadesToNext() async {
        // a fires but no effect; b lands.
        let result = await run(["a": .firedUnverified, "b": .landed])
        #expect(result.landedRungID == "b")
        #expect(result.firedUnverifiedRungIDs == ["a"])
    }

    @Test func nothingApplicableLandsNil() async {
        let result = await run([:])
        #expect(result.landedRungID == nil)
        #expect(result.landed == false)
        #expect(result.firedUnverifiedRungIDs.isEmpty)
    }

    @Test func liarLikeAllFireUnverifiedNoLanding() async {
        // Every applicable rung fires but nothing lands — the liar case.
        let result = await run(["a": .firedUnverified, "b": .firedUnverified, "c": .firedUnverified])
        #expect(result.landedRungID == nil)
        #expect(result.firedUnverifiedRungIDs == ["a", "b", "c"])
    }

    @Test func firedUnverifiedReasonsMapIdsToVocabulary() {
        let result = ChainResult(landedRungID: nil, firedUnverifiedRungIDs: ["a", "b"])
        let reasons = firedUnverifiedReasons(result, in: rungs)
        #expect(reasons == [.chainAXPressUnverified, .chainAXConfirmUnverified])
    }

    // MARK: effect predicate (mirrors the outcome reducer's click-success rule)

    @Test func focusIntentLandsWhenTargetFocused() {
        var after = ActionVerification()
        after.afterFocused = true
        #expect(clickEffectObserved(before: ActionVerification(), after: after, windowChanged: false, intent: .focusTarget))
    }

    @Test func targetStateChangeLands() {
        var after = ActionVerification()
        after.targetStateChanged = true
        #expect(clickEffectObserved(before: ActionVerification(), after: after, windowChanged: false, intent: .activate))
    }

    @Test func windowChangeLandsWhenTargetInert() {
        // Button case: target has no observable field, but the window changed.
        #expect(clickEffectObserved(before: ActionVerification(), after: ActionVerification(), windowChanged: true, intent: .activate))
    }

    @Test func noSignalDoesNotLand() {
        // Liar case: dispatch ok, nothing changed.
        #expect(!clickEffectObserved(before: ActionVerification(), after: ActionVerification(), windowChanged: false, intent: .activate))
    }

    @Test func clickChainTableCoversSpecOrder() {
        // The declarative table matches the documented priority order.
        #expect(clickChain.map(\.id) == [
            "ax-press", "ax-confirm", "ax-open", "ax-pick", "selection-relay", "child-press", "ancestor-press",
        ])
    }
}
