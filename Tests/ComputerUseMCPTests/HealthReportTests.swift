import Testing

@testable import computer_use_mcp

@Suite struct HealthReportTests {
    @Test func recommendationStartsWithAccessibility() {
        let action = recommendedNextAction(
            accessibility: false,
            screenRecording: false,
            captureServiceStatus: .skipped
        )

        #expect(action.contains("Grant Accessibility"))
    }

    @Test func recommendationThenChecksScreenRecording() {
        let action = recommendedNextAction(
            accessibility: true,
            screenRecording: false,
            captureServiceStatus: .skipped
        )

        #expect(action.contains("Grant Screen Recording"))
    }

    @Test func recommendationCallsOutWedgedCaptureService() {
        let action = recommendedNextAction(
            accessibility: true,
            screenRecording: true,
            captureServiceStatus: .notResponding
        )

        #expect(action.contains("replayd"))
    }

    @Test func recommendationCallsOutStableBundleIdentityWhenHealthy() {
        let action = recommendedNextAction(
            accessibility: true,
            screenRecording: true,
            captureServiceStatus: .responsive
        )

        #expect(action.contains("signed, notarized app bundle"))
    }

    @Test func recommendationExplainsSkippedCaptureProbe() {
        let action = recommendedNextAction(
            accessibility: true,
            screenRecording: true,
            captureServiceStatus: .skipped
        )

        #expect(action.contains("--probe-capture"))
    }
}
