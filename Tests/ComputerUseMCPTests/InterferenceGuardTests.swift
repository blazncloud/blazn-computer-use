import Testing

@testable import computer_use_mcp

@Suite struct InterferenceGuardTests {
    @Test func idleUserNeverYields() {
        #expect(
            !interferenceShouldYield(
                targetPid: 100, frontmostPid: 100, usesGlobalPath: false,
                secondsSinceUserInput: 5.0, idleThreshold: 1.0
            ))
    }

    @Test func activeUserInTargetAppYields() {
        #expect(
            interferenceShouldYield(
                targetPid: 100, frontmostPid: 100, usesGlobalPath: false,
                secondsSinceUserInput: 0.2, idleThreshold: 1.0
            ))
    }

    @Test func backgroundTargetIsNeverBlocked() {
        #expect(
            !interferenceShouldYield(
                targetPid: 100, frontmostPid: 200, usesGlobalPath: false,
                secondsSinceUserInput: 0.2, idleThreshold: 1.0
            ))
    }

    @Test func globalPathYieldsRegardlessOfFrontmost() {
        #expect(
            interferenceShouldYield(
                targetPid: 100, frontmostPid: 200, usesGlobalPath: true,
                secondsSinceUserInput: 0.2, idleThreshold: 1.0
            ))
    }

    @Test func zeroThresholdDisablesTheGuard() {
        #expect(
            !interferenceShouldYield(
                targetPid: 100, frontmostPid: 100, usesGlobalPath: false,
                secondsSinceUserInput: 0.0, idleThreshold: 0.0
            ))
    }

    @Test func unresolvedPidsDoNotBlock() {
        #expect(
            !interferenceShouldYield(
                targetPid: nil, frontmostPid: 100, usesGlobalPath: false,
                secondsSinceUserInput: 0.2, idleThreshold: 1.0
            ))
        #expect(
            !interferenceShouldYield(
                targetPid: 100, frontmostPid: nil, usesGlobalPath: false,
                secondsSinceUserInput: 0.2, idleThreshold: 1.0
            ))
    }
}
