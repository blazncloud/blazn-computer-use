import Testing

@testable import computer_use_mcp

@Suite struct OverlaySessionTests {
    @Test func sessionColorIndexIsStableAndWithinPalette() {
        let first = overlaySessionColorIndex(for: "42")
        let second = overlaySessionColorIndex(for: "42")
        #expect(first == second)
        #expect(first >= 0)
        #expect(first < overlaySessionPalette.count)

        let other = overlaySessionColorIndex(for: "99")
        // Distinct session ids usually land on distinct palette slots; if they
        // collide that is still valid, but the assignment must stay in range.
        #expect(other >= 0)
        #expect(other < overlaySessionPalette.count)
    }

    @Test func distinctSessionsPreferDistinctColors() {
        let indexes = (0..<16).map { overlaySessionColorIndex(for: String($0)) }
        #expect(Set(indexes).count > 1)
    }

    @Test func sessionLabelUsesShortSuffix() {
        #expect(overlaySessionLabel(for: "7") == "7")
        #expect(overlaySessionLabel(for: "42") == "42")
        #expect(overlaySessionLabel(for: "1234") == "234")
    }

    @Test func parsesLegacyMoveAndPulseWithoutSession() {
        #expect(
            OverlayCommand.parse("move 10 20")
                == .move(x: 10, y: 20, window: nil, session: overlayDefaultSessionID))
        #expect(
            OverlayCommand.parse("pulse 1 2 0")
                == .pulse(x: 1, y: 2, window: nil, session: overlayDefaultSessionID))
        #expect(
            OverlayCommand.parse("move 3 4 99")
                == .move(x: 3, y: 4, window: 99, session: overlayDefaultSessionID))
    }

    @Test func parsesMovePulseWithSessionId() {
        #expect(
            OverlayCommand.parse("move 10 20 0 42")
                == .move(x: 10, y: 20, window: nil, session: "42"))
        #expect(
            OverlayCommand.parse("pulse 5 6 123 7")
                == .pulse(x: 5, y: 6, window: 123, session: "7"))
    }

    @Test func parsesDropPingAndRecord() {
        #expect(OverlayCommand.parse("drop 42") == .drop(session: "42"))
        #expect(OverlayCommand.parse("ping") == .ping)
        #expect(OverlayCommand.parse("record on") == .record(true))
        #expect(OverlayCommand.parse("record off") == .record(false))
    }

    @Test func rejectsMalformedOverlayCommands() {
        #expect(OverlayCommand.parse("") == nil)
        #expect(OverlayCommand.parse("move 10") == nil)
        #expect(OverlayCommand.parse("drop") == nil)
        #expect(OverlayCommand.parse("unknown 1 2") == nil)
    }
}
