import Testing

@testable import computer_use_mcp

@Suite struct ScrollRoutingTests {
    @Test func semanticOwnerCandidatesSkipPinnedInnerContainer() {
        #expect(scrollOwnerCandidateIndices(atExtents: [true, false]) == [1])
        #expect(scrollOwnerCandidateIndices(atExtents: [nil, false]) == [0, 1])
        #expect(scrollOwnerCandidateIndices(atExtents: [true, true]) == [0])
        #expect(scrollOwnerCandidateIndices(atExtents: []) == [])
    }

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

    @Test func scrollToVisibleAloneDoesNotQualifyAsAContainer() {
        // A bare scroll-to-visible action is a weak hint, below the routing
        // threshold — an element that can be scrolled into view is not a scroller.
        let group = features("AXGroup", scrollToVisible: true)
        #expect(scrollContainerScore(group) > 0)
        #expect(!qualifiesAsScrollContainer(group))
        #expect(qualifiesAsScrollContainer(features("AXScrollArea")))
    }

    @Test func scrollBarStaysDisqualifiedEvenWithScrollToVisible() {
        #expect(scrollContainerScore(features("AXScrollBar", scrollToVisible: true)) < 0)
    }

    // MARK: Ranking policy — innermost qualifying container wins

    @Test func rankingKeepsOnlyQualifiersOrderedInnermostFirst() {
        let ranked = rankScrollCandidates([
            (item: "leaf", score: 0, depth: 0),
            (item: "innerList", score: 30, depth: 2),
            (item: "outerScrollArea", score: 140, depth: 5),
            (item: "bar", score: -100, depth: 1),
        ])
        // The inner list (weaker score but nearer the hit) drives, not the
        // higher-scored outer scroll area whose centre sits over other content.
        #expect(ranked == ["innerList", "outerScrollArea"])
    }

    @Test func rankingDropsBelowThresholdCandidates() {
        let ranked = rankScrollCandidates([
            (item: "scrollToVisibleOnly", score: 5, depth: 0),
            (item: "list", score: 30, depth: 1),
        ])
        #expect(ranked == ["list"])
    }

    @Test func rankingOfEmptyOrAllWeakIsEmpty() {
        #expect(rankScrollCandidates([(item: "x", score: 5, depth: 0)]).isEmpty)
        #expect(rankScrollCandidates([] as [(item: String, score: Int, depth: Int)]).isEmpty)
    }

    // MARK: Tier-1 AX page-scroll action mapping

    @Test func everyDirectionMapsToItsPageScrollAction() {
        #expect(scrollPageAction(for: "down") == "AXScrollDownByPage")
        #expect(scrollPageAction(for: "up") == "AXScrollUpByPage")
        #expect(scrollPageAction(for: "left") == "AXScrollLeftByPage")
        #expect(scrollPageAction(for: "right") == "AXScrollRightByPage")
    }

    @Test func unknownDirectionHasNoPageScrollAction() {
        #expect(scrollPageAction(for: "sideways") == nil)
        #expect(scrollPageAction(for: "") == nil)
    }

    // MARK: Reveal-descendant selection (AXScrollToVisible equivalent)

    @Test func nearestOffsetPicksTheCandidateClosestToTheTargetDistance() {
        // Offsets past the viewport edge; target ~ one viewport (400).
        #expect(nearestOffsetIndex([120, 380, 900], target: 400) == 1)
    }

    @Test func nearestOffsetIgnoresOnOrBehindTheEdge() {
        // Zero/negative offsets are on-screen or behind the scroll direction.
        #expect(nearestOffsetIndex([-50, 0, 700], target: 400) == 2)
    }

    @Test func nearestOffsetIsNilWhenNothingIsPastTheEdge() {
        #expect(nearestOffsetIndex([-10, 0], target: 400) == nil)
        #expect(nearestOffsetIndex([], target: 400) == nil)
    }

    // MARK: Scroll-bar value mapping (AXScrollBar set)

    @Test func scrolledBarValueMovesByPageProportionInEachDirection() {
        // One page ≈ 0.1 of the content; scrolling down 2 pages from 0.3 → 0.5.
        #expect(scrolledBarValue(current: 0.3, pageProportion: 0.1, pages: 2, forward: true) == 0.5)
        // Up 2 pages goes the other way.
        #expect(abs(scrolledBarValue(current: 0.3, pageProportion: 0.1, pages: 2, forward: false) - 0.1) < 1e-9)
    }

    @Test func scrolledBarValueClampsToTheTrack() {
        #expect(scrolledBarValue(current: 0.9, pageProportion: 0.5, pages: 3, forward: true) == 1.0)
        #expect(scrolledBarValue(current: 0.1, pageProportion: 0.5, pages: 3, forward: false) == 0.0)
    }
}
