import Testing

@testable import computer_use_mcp

private func fingerprint(
    role: String = "AXButton", subrole: String? = nil,
    identifier: String? = nil, label: String? = "Save"
) -> ElementFingerprint {
    ElementFingerprint(
        role: role, subrole: subrole, identifier: identifier,
        stableLabel: label)
}

@Suite struct ElementFingerprintTests {
    @Test func exactCapturedFactsMatch() {
        let expected = fingerprint(
            subrole: "AXDefaultButton", identifier: "save-button", label: "Save")
        #expect(validateElementFingerprint(
            expected: expected, live: expected,
            requireIdentityEvidence: false) == .match)
    }

    @Test func roleSubroleIdentifierAndLabelChangesFailBeforeDelivery() {
        let expected = fingerprint(
            subrole: "AXDefaultButton", identifier: "save-button", label: "Save")
        #expect(validateElementFingerprint(
            expected: expected, live: fingerprint(
                role: "AXCheckBox", subrole: "AXDefaultButton",
                identifier: "save-button", label: "Save"),
            requireIdentityEvidence: false) != .match)
        #expect(validateElementFingerprint(
            expected: expected, live: fingerprint(
                subrole: "AXCancelButton", identifier: "save-button", label: "Save"),
            requireIdentityEvidence: false) != .match)
        #expect(validateElementFingerprint(
            expected: expected, live: fingerprint(
                subrole: "AXDefaultButton", identifier: "other", label: "Save"),
            requireIdentityEvidence: false) != .match)
        #expect(validateElementFingerprint(
            expected: expected, live: fingerprint(
                subrole: "AXDefaultButton", identifier: "save-button", label: "Archive"),
            requireIdentityEvidence: false) != .match)
    }

    @Test func missingIdentifierAndLabelAreAllowedForRetainedHandle() {
        let unlabeled = fingerprint(identifier: nil, label: nil)
        #expect(validateElementFingerprint(
            expected: unlabeled, live: unlabeled,
            requireIdentityEvidence: false) == .match)
        #expect(validateElementFingerprint(
            expected: unlabeled, live: unlabeled,
            requireIdentityEvidence: true) == .insufficientEvidence)
    }

    @Test func postDeliveryCanIgnorePresentationLabel() {
        let before = fingerprint(identifier: nil, label: "Play")
        let after = fingerprint(identifier: nil, label: "Pause")
        #expect(validateElementFingerprint(
            expected: before, live: after,
            requireIdentityEvidence: false,
            comparePresentationEvidence: false) == .match)
    }

    @Test func stableIdentityLabelIsConservative() {
        #expect(stableIdentityLabel(
            role: "AXButton", title: "Save", description: nil) == "Save")
        #expect(stableIdentityLabel(
            role: "AXGroup", title: "Sidebar", description: nil) == nil)
        #expect(stableIdentityLabel(
            role: "AXTextField", title: "Alice", description: nil,
            associatedTitle: "Name") == "Name")
    }
}
