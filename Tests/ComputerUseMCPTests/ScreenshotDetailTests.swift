import MCP
import Testing

@testable import computer_use_mcp

@Suite struct ScreenshotDetailTests {
    @Test func appStateDefaultsToFullCapture() {
        #expect(appStateScreenshotDetail([:]) == .full)
        #expect(appStateScreenshotDetail(["include_screenshot": .bool(true)]) == .full)
    }

    @Test func appStateHonorsTreeOnlyOptOut() {
        #expect(appStateScreenshotDetail(["include_screenshot": .bool(false)]) == .none)
    }

    @Test func actionsDefaultToReducedCapture() {
        #expect(screenshotDetail([:]) == .reduced)
        #expect(screenshotDetail(["include_screenshot": .bool(true)]) == .reduced)
    }

    @Test func actionsHonorScreenshotOptOut() {
        #expect(screenshotDetail(["include_screenshot": .bool(false)]) == .none)
    }

    @Test func includeStateFalseDropsStateRegardlessOfScreenshotFlag() {
        #expect(screenshotDetail(["include_state": .bool(false)]) == .noState)
        #expect(
            screenshotDetail(["include_state": .bool(false), "include_screenshot": .bool(true)])
                == .noState)
    }
}
