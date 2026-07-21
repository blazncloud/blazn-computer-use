import Foundation
import Testing

@testable import computer_use_mcp

@Suite struct URLPolicyTests {
    private let deny = ["internal.corp"]
    private let confirm = ["checkout", "paypal.com", "banking"]

    @Test func plainPageIsAllowed() {
        #expect(
            urlPolicyDecision(
                url: "https://example.com/docs", denyPatterns: deny,
                confirmPatterns: confirm, hasExplicitPolicy: true
            ) == .allow)
    }

    @Test func denyPatternBlocks() {
        let decision = urlPolicyDecision(
            url: "https://internal.corp/admin", denyPatterns: deny,
            confirmPatterns: confirm, hasExplicitPolicy: true
        )
        guard case .deny = decision else {
            Issue.record("expected deny, got \(decision)")
            return
        }
    }

    @Test func confirmPatternRequiresConfirmationCaseInsensitively() {
        let decision = urlPolicyDecision(
            url: "https://shop.example.com/CHECKOUT/step-2", denyPatterns: deny,
            confirmPatterns: confirm, hasExplicitPolicy: true
        )
        guard case .requireConfirm = decision else {
            Issue.record("expected requireConfirm, got \(decision)")
            return
        }
    }

    @Test func denyWinsOverConfirm() {
        let decision = urlPolicyDecision(
            url: "https://internal.corp/checkout", denyPatterns: deny,
            confirmPatterns: confirm, hasExplicitPolicy: true
        )
        guard case .deny = decision else {
            Issue.record("expected deny, got \(decision)")
            return
        }
    }

    @Test func unreadableURLFailsClosedWithBuiltInConfirmPatterns() {
        let withUserPatterns = urlPolicyDecision(
            url: nil, denyPatterns: deny, confirmPatterns: confirm, hasExplicitPolicy: true
        )
        guard case .requireConfirm = withUserPatterns else {
            Issue.record("expected requireConfirm, got \(withUserPatterns)")
            return
        }
        // Built-in payment-page patterns alone must fail closed — callers that
        // still pass hasExplicitPolicy:false must not silently allow.
        let withBuiltInsOnly = urlPolicyDecision(
            url: nil, denyPatterns: [], confirmPatterns: URLPolicy.defaultConfirmPatterns,
            hasExplicitPolicy: false
        )
        guard case .requireConfirm = withBuiltInsOnly else {
            Issue.record("expected requireConfirm for built-ins, got \(withBuiltInsOnly)")
            return
        }
    }

    @Test func unreadableURLAllowsWhenNoPatternsExist() {
        #expect(
            urlPolicyDecision(
                url: nil, denyPatterns: [], confirmPatterns: [], hasExplicitPolicy: false
            ) == .allow)
    }

    @Test func browserDetectionMatchesKnownBundleIds() {
        #expect(isBrowserApp(bundleIdentifier: "com.google.Chrome"))
        #expect(isBrowserApp(bundleIdentifier: "com.apple.Safari"))
        #expect(isBrowserApp(bundleIdentifier: "company.thebrowser.Browser"))
        #expect(!isBrowserApp(bundleIdentifier: "com.apple.TextEdit"))
        #expect(!isBrowserApp(bundleIdentifier: "com.spotify.client"))
    }

    @Test func openURLDenyBlocksEvenWhenConfirmed() {
        let url = URL(string: "https://internal.corp/admin")!
        #expect(throws: (any Error).self) {
            try SafetyPolicy.checkOpenURL(
                url, confirmed: true, denyPatterns: ["internal.corp"], confirmPatterns: []
            )
        }
    }

    @Test func openURLConfirmPatternIsRecoverable() {
        let url = URL(string: "https://www.paypal.com/send")!
        #expect(throws: SafetyError.self) {
            try SafetyPolicy.checkOpenURL(
                url, confirmed: false, denyPatterns: [], confirmPatterns: ["paypal.com"]
            )
        }
        // confirm:true proceeds.
        try? SafetyPolicy.checkOpenURL(
            url, confirmed: true, denyPatterns: [], confirmPatterns: ["paypal.com"]
        )
    }

    @Test func openURLPlainHTTPSStillAllowed() throws {
        try SafetyPolicy.checkOpenURL(
            URL(string: "https://example.com")!, confirmed: false,
            denyPatterns: ["internal.corp"], confirmPatterns: ["checkout"]
        )
    }
}
