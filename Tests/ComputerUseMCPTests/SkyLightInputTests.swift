import CoreGraphics
import Darwin
import Testing

@testable import computer_use_mcp

@Suite struct SkyLightInputTests {
    @Test func environmentGateDefaultsOff() {
        #expect(!skyLightEnabled(environment: [:]))
        #expect(!skyLightEnabled(environment: ["COMPUTER_USE_MCP_SKYLIGHT": "0"]))
        #expect(skyLightEnabled(environment: ["COMPUTER_USE_MCP_SKYLIGHT": "1"]))
    }

    @Test func gateOffDoesNotConsultAvailability() {
        let posting = ProbeSkyLightPosting(enabled: false, availableValue: true)
        #expect(skyLightStatus(posting) == .disabled)
        #expect(!posting.availableWasRead)
    }

    @Test func enabledMissingSymbolReportsUnavailable() {
        let posting = ProbeSkyLightPosting(enabled: true, availableValue: false)
        #expect(skyLightStatus(posting) == .unavailable)
        #expect(posting.availableWasRead)
    }

    @Test func symbolMissingPathFallsBackCleanly() {
        let context = DeliveryContext(
            pid: 1,
            windowNumber: nil,
            windowFrame: nil,
            allowGlobalCursor: false)
        let reasons = syntheticFallbackReasons(
            context: context,
            bridgeSucceeded: false,
            skyLightStatus: .unavailable)
        #expect(reasons == [.windowNumberUnresolved, .windowFrameUnresolved, .skyLightUnavailable])
    }

    @Test func skylightDisabledDoesNotChangeExistingFallbackReasons() {
        let context = DeliveryContext(
            pid: 1,
            windowNumber: nil,
            windowFrame: nil,
            allowGlobalCursor: false)
        let reasons = syntheticFallbackReasons(
            context: context,
            bridgeSucceeded: false,
            skyLightStatus: .disabled)
        #expect(reasons == [.windowNumberUnresolved, .windowFrameUnresolved])
    }

    @Test func skylightTierIsDroppableBackgroundDelivery() {
        #expect(isDroppableBackgroundDeliveryTier(InputTier.skyLight.rawValue))
        #expect(isDroppableBackgroundDeliveryTier(KeyDeliveryMode.skyLight.rawValue))
    }

    @Test func mouseRecipeStampsChromiumWindowFieldsAndPrimerWithoutAuth() {
        let specs = skyLightMouseRecipe(
            pid: 123,
            point: CGPoint(x: 25, y: 30),
            button: .left,
            clickCount: 1,
            windowNumber: 42,
            windowFrame: CGRect(x: 10, y: 10, width: 100, height: 50),
            clickGroupID: 777)

        #expect(specs.map(\.kind) == [.mouseMoved, .mouseDown, .mouseUp])
        #expect(specs.allSatisfy { !$0.attachAuthMessage })
        #expect(specs[0].windowLocation == CGPoint(x: 15, y: 30))
        #expect(specs[0].delayAfterMilliseconds == 12)
        #expect(specs[1].delayAfterMilliseconds == 28)

        let downFields = fieldsByNumber(specs[1].integerFields)
        #expect(downFields[1] == 1)
        #expect(downFields[3] == 0)
        #expect(downFields[7] == 3)
        #expect(downFields[40] == 123)
        #expect(downFields[51] == 42)
        #expect(downFields[58] == 777)
        #expect(downFields[91] == 42)
        #expect(downFields[92] == 42)
    }

    @Test func keyboardRecipesAttachAuthenticationMessage() {
        let unicode = skyLightUnicodeKeyboardRecipe([65])
        #expect(unicode.map(\.kind) == [.keyDown, .keyUp])
        #expect(unicode.allSatisfy { $0.attachAuthMessage })
        #expect(unicode.allSatisfy { $0.unicode == [65] })

        let chord = KeyChord(keyCode: 36, flags: .maskCommand)
        let key = skyLightKeyRecipe(chord: chord)
        #expect(key.map(\.kind) == [.keyDown, .keyUp])
        #expect(key.allSatisfy { $0.attachAuthMessage })
        #expect(key.allSatisfy { $0.keyCode == 36 })
        #expect(key.allSatisfy { $0.flags == .maskCommand })
    }

    private func fieldsByNumber(_ fields: [SkyLightIntegerField]) -> [Int: Int64] {
        Dictionary(uniqueKeysWithValues: fields.map { ($0.field, $0.value) })
    }
}

private final class ProbeSkyLightPosting: SkyLightEventPosting {
    let enabled: Bool
    let availableValue: Bool
    var availableWasRead = false

    init(enabled: Bool, availableValue: Bool) {
        self.enabled = enabled
        self.availableValue = availableValue
    }

    var available: Bool {
        availableWasRead = true
        return availableValue
    }

    func post(_ event: CGEvent, to pid: pid_t, attachAuthMessage: Bool) -> Bool {
        Issue.record("post should not be called by these tests")
        return false
    }

    func setWindowLocation(_ event: CGEvent, _ point: CGPoint) -> Bool {
        Issue.record("setWindowLocation should not be called by these tests")
        return false
    }

    func setIntegerField(_ event: CGEvent, field: Int, value: Int64) -> Bool {
        Issue.record("setIntegerField should not be called by these tests")
        return false
    }
}
