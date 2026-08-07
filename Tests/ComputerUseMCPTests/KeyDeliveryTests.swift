import CoreGraphics
import Testing

@testable import computer_use_mcp

@Suite struct KeyDeliveryTests {
    @Test func focusedPressKeyIgnoresUnrelatedLegacySnapshotIdentity() {
        #expect(!pressKeyRequiresSnapshotIdentity(storedSnapshotExists: false))
        #expect(!pressKeyRequiresSnapshotIdentity(storedSnapshotExists: true))
    }

    @Test func pressKeyRecapturesTheCurrentPostKeyWindow() async throws {
        var capturedTitle: String? = "not called"
        var capturedID: CGWindowID? = 42
        let value = try await recaptureAfterPressKey { title, id in
            capturedTitle = title
            capturedID = id
            return "fresh state"
        }
        #expect(value == "fresh state")
        #expect(capturedTitle == nil)
        #expect(capturedID == nil)
    }
    @Test func defaultKeyboardDeliveryStaysPerPid() throws {
        let context = DeliveryContext(pid: 1, windowNumber: nil, windowFrame: nil, allowGlobalCursor: false)
        #expect(try keyDeliveryMode(context: context, targetAppIsActive: false) == .perPid)
    }

    @Test func explicitGlobalKeyboardDeliveryWorksForForegroundWindowedApps() throws {
        let context = DeliveryContext(pid: 1, windowNumber: CGWindowID(42), windowFrame: nil, allowGlobalCursor: true)
        #expect(try keyDeliveryMode(context: context, targetAppIsActive: true) == .globalSessionTap)
    }

    @Test func explicitGlobalKeyboardDeliveryRequiresForegroundEvenWithWindowTarget() {
        let context = DeliveryContext(pid: 1, windowNumber: CGWindowID(42), windowFrame: nil, allowGlobalCursor: true)
        #expect(throws: ToolError.self) {
            try keyDeliveryMode(context: context, targetAppIsActive: false)
        }
    }

    @Test func globalKeyboardDeliveryRequiresForegroundTarget() {
        let context = DeliveryContext(pid: 1, windowNumber: nil, windowFrame: nil, allowGlobalCursor: true)
        #expect(throws: ToolError.self) {
            try keyDeliveryMode(context: context, targetAppIsActive: false)
        }
    }

    @Test func globalKeyboardDeliveryIsOnlyChosenForForegroundTarget() throws {
        let context = DeliveryContext(pid: 1, windowNumber: nil, windowFrame: nil, allowGlobalCursor: true)
        #expect(try keyDeliveryMode(context: context, targetAppIsActive: true) == .globalSessionTap)
    }
}
