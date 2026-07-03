import Testing

@testable import computer_use_mcp

@Suite struct ScrollRoutingTests {
    private func features(
        _ role: String, vBar: Bool = false, hBar: Bool = false, scrollToVisible: Bool = false
    ) -> ScrollCandidateFeatures {
        ScrollCandidateFeatures(
            role: role, hasVerticalScrollBar: vBar, hasHorizontalScrollBar: hBar,
            supportsScrollToVisible: scrollToVisible)
    }

    // MARK: Scoring

    @Test func scrollAreaWithBarsOutranksEverything() {
        let scrollArea = scrollContainerScore(features("AXScrollArea", vBar: true))
        let list = scrollContainerScore(features("AXList"))
        let leaf = scrollContainerScore(features("AXStaticText"))
        #expect(scrollArea > list)
        #expect(list > leaf)
    }

    @Test func plainLeafIsNotAContainer() {
        #expect(scrollContainerScore(features("AXStaticText")) == 0)
        #expect(scrollContainerScore(features("AXButton")) == 0)
    }

    @Test func scrollBarAndSteppersAreDisqualified() {
        #expect(scrollContainerScore(features("AXScrollBar")) < 0)
        #expect(scrollContainerScore(features("AXValueIndicator")) < 0)
        #expect(scrollContainerScore(features("AXIncrementor")) < 0)
    }

    @Test func webAreaScoresAsScrollable() {
        #expect(scrollContainerScore(features("AXWebArea")) > 0)
    }

    @Test func collectionRolesScoreAsScrollable() {
        for role in ["AXTable", "AXOutline", "AXList", "AXGrid", "AXCollection", "AXBrowser"] {
            #expect(scrollContainerScore(features(role)) > 0, "\(role) should rank as scrollable")
        }
    }

    @Test func scrollToVisibleAloneIsAWeakPositive() {
        let weak = scrollContainerScore(features("AXGroup", scrollToVisible: true))
        #expect(weak > 0)
        #expect(weak < scrollContainerScore(features("AXScrollArea")))
    }

    @Test func scrollBarStaysDisqualifiedEvenWithScrollToVisible() {
        #expect(scrollContainerScore(features("AXScrollBar", scrollToVisible: true)) < 0)
    }

    // MARK: Ranking policy

    @Test func rankingDropsNonContainersAndOrdersByScore() {
        let ranked = rankScrollCandidates([
            (item: "leaf", score: 0, depth: 0),
            (item: "list", score: 30, depth: 2),
            (item: "scrollArea", score: 140, depth: 3),
            (item: "bar", score: -100, depth: 1),
        ])
        #expect(ranked == ["scrollArea", "list"])
    }

    @Test func rankingTieBreaksToTheInnermost() {
        let ranked = rankScrollCandidates([
            (item: "outer", score: 40, depth: 5),
            (item: "inner", score: 40, depth: 1),
        ])
        #expect(ranked == ["inner", "outer"])
    }

    @Test func rankingOfEmptyOrAllZeroIsEmpty() {
        #expect(rankScrollCandidates([(item: "x", score: 0, depth: 0)]).isEmpty)
        #expect(rankScrollCandidates([] as [(item: String, score: Int, depth: Int)]).isEmpty)
    }
}
