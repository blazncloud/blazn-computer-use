import Testing

@testable import computer_use_mcp

@Suite struct DeliveryPlanningTests {
    @Test func clickSelectsExactlyOneRouteFromPreflight() {
        #expect(clickDeliveryRoute(hasPressableElement: true) == .axPress)
        #expect(clickDeliveryRoute(hasPressableElement: false) == .synthetic)
    }

    @Test func textRouteIsChosenOnlyFromSettableCapabilities() {
        #expect(textDeliveryRoute(selectedTextSettable: true, valueSettable: true) == .selectedText)
        #expect(textDeliveryRoute(selectedTextSettable: false, valueSettable: true) == .valueSplice)
        #expect(textDeliveryRoute(selectedTextSettable: false, valueSettable: false) == .synthetic)
    }

    @Test func emptyTypeTextIsRejectedInsteadOfFalseVerified() {
        #expect(throws: (any Error).self) {
            try validateTypeTextArgument("")
        }
        #expect(throws: Never.self) {
            try validateTypeTextArgument("hello")
        }
    }

    @Test func verificationReadsImmediatelyAndAtDeadlineWithoutObserver() async {
        var reads = 0
        let immediate = await waitForDeliveryVerification(
            observer: nil, baselineRevision: nil, timeout: .zero,
            predicate: {
                reads += 1
                return true
            })
        #expect(immediate)
        #expect(reads == 1)

        reads = 0
        let final = await waitForDeliveryVerification(
            observer: nil, baselineRevision: nil, timeout: .zero,
            predicate: {
                reads += 1
                return reads == 2
            })
        #expect(final)
        #expect(reads == 2)
    }
}
