import ApplicationServices
import Foundation

/// Stable evidence captured for validating a retained AX handle. Mutable
/// values, geometry, and sibling position are deliberately not identity.
struct ElementFingerprint: Codable, Equatable, Sendable {
    let role: String
    let subrole: String?
    let identifier: String?
    let stableLabel: String?

    var hasIdentifierEvidence: Bool {
        identifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var hasIdentityEvidence: Bool {
        hasIdentifierEvidence
            || stableLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

enum ElementFingerprintValidation: Equatable {
    case match
    case insufficientEvidence
    case mismatch(String)
}

/// Exact comparison of every stable field that was captured. New optional
/// evidence exposed only by the live element is ignored; captured evidence
/// disappearing or changing is a stale-target failure.
func validateElementFingerprint(
    expected: ElementFingerprint,
    live: ElementFingerprint,
    requireIdentityEvidence: Bool,
    comparePresentationEvidence: Bool = true
) -> ElementFingerprintValidation {
    if requireIdentityEvidence, !expected.hasIdentityEvidence {
        return .insufficientEvidence
    }
    guard live.role == expected.role else {
        return .mismatch("role changed from \(expected.role) to \(live.role)")
    }
    if let subrole = expected.subrole, live.subrole != subrole {
        return .mismatch("subrole changed from \(subrole) to \(live.subrole ?? "none")")
    }
    if let identifier = expected.identifier, live.identifier != identifier {
        return .mismatch(
            "AXIdentifier changed from \(identifier) to \(live.identifier ?? "none")")
    }
    // Pre-delivery checks compare the captured presentation label. After a
    // delivery, the retained handle itself is the identity, so an intentional
    // Play→Pause-style label change is allowed.
    if comparePresentationEvidence, let label = expected.stableLabel,
        live.stableLabel != label
    {
        return .mismatch(
            "stable label changed from \(label) to \(live.stableLabel ?? "none")")
    }
    return .match
}

/// Conservative identity/comparison evidence. Generic containers and mutable
/// text contents are excluded; repeated identical labels remain ambiguous.
func stableIdentityLabel(
    role: String, title: String?, description: String?, associatedTitle: String? = nil
) -> String? {
    if isTextEntryRole(role) {
        guard let associatedTitle,
            !associatedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return associatedTitle
    }
    let supportedRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXMenuItem",
        "AXMenuButton", "AXPopUpButton", "AXLink", "AXTab",
        "AXDisclosureTriangle", "AXSlider", "AXIncrementor", "AXScrollBar",
    ]
    guard supportedRoles.contains(role) else { return nil }
    for candidate in [title, description] {
        if let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return candidate
        }
    }
    return nil
}

func liveElementFingerprint(_ element: AXUIElement) -> ElementFingerprint {
    let role = axRole(element)
    let title = axString(element, kAXTitleAttribute)
    let description = title == nil ? axString(element, kAXDescriptionAttribute) : nil
    let associatedTitle = axElement(element, kAXTitleUIElementAttribute).flatMap { titleElement in
        axString(titleElement, kAXTitleAttribute)
            ?? axString(titleElement, kAXDescriptionAttribute)
            ?? axString(titleElement, kAXValueAttribute)
    }
    return ElementFingerprint(
        role: role,
        subrole: axString(element, kAXSubroleAttribute),
        identifier: axString(element, "AXIdentifier"),
        stableLabel: stableIdentityLabel(
            role: role, title: title, description: description,
            associatedTitle: associatedTitle))
}
