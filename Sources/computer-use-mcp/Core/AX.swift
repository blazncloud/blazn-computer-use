// Thin helpers over the C Accessibility (AXUIElement) API.

import AppKit
import ApplicationServices
import Foundation

/// Process-wide AX messaging timeout (seconds). An unresponsive app then
/// fails each AX call after this bound instead of stalling tool calls for the
/// 6s system default. Tunable via COMPUTER_USE_MCP_AX_TIMEOUT.
func configureAXMessagingTimeout() {
    let seconds = Config.double("ax_timeout").map(Float.init) ?? 2.0
    AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
}

/// Human-readable AXError explanation with retry guidance for the agent.
func axErrorDescription(_ error: AXError) -> String {
    switch error {
    case .cannotComplete:
        return "AXError cannotComplete: the app did not respond (busy, hung, or just slow) — usually transient, retry once"
    case .invalidUIElement:
        return "AXError invalidUIElement: the element no longer exists — call get_app_state for fresh ids"
    case .actionUnsupported:
        return "AXError actionUnsupported: the element does not support this action"
    case .attributeUnsupported:
        return "AXError attributeUnsupported: the element does not expose this attribute"
    case .notImplemented:
        return "AXError notImplemented: the app does not implement this part of the accessibility API"
    case .apiDisabled:
        return "AXError apiDisabled: accessibility permission is missing or was revoked"
    case .noValue:
        return "AXError noValue: the attribute has no value"
    default:
        return "AXError \(error.rawValue)"
    }
}

/// True when the process behind a pid is gone (quit or crashed); used to turn
/// confusing stale-element errors into a clear "the app died" message.
func appIsGone(pid: pid_t) -> Bool {
    guard let app = NSRunningApplication(processIdentifier: pid) else { return true }
    return app.isTerminated
}

/// What came of asking an app to render its web-content accessibility tree.
enum WebAXEnableOutcome: Sendable, Equatable {
    /// A flag was newly set — the renderer may need a beat to populate.
    case applied
    /// The flags were already force-set this run; re-asserted cheaply, but a
    /// settle-and-rebuild will not discover anything new for a sparse tree.
    case alreadyApplied
    /// The app rejected the opt-in outright (e.g. a CEF build without
    /// accessibility wiring); its web UI cannot be exposed as elements.
    case unsupported
    /// Nothing to do: not a web-renderer app, or already enabled this run.
    case skipped
}

/// Chromium and Electron apps render their web-content accessibility tree
/// only while an assistive client is detected — otherwise the tree stops at
/// the browser chrome and an empty AXWebArea (and support can lapse again
/// between calls). Setting these app-element attributes is the documented
/// opt-in (VoiceOver does the same). Native apps don't expose the attributes
/// and are left untouched.
actor AssistiveAccess {
    static let shared = AssistiveAccess()
    private var attemptedPids: Set<pid_t> = []
    private var forcedPids: Set<pid_t> = []
    private var unsupportedPids: Set<pid_t> = []
    private var webRendererPids: [pid_t: Bool] = [:]

    /// Cheap once-per-pid enable for apps that advertise the attributes.
    /// `force` re-sets the flags regardless (used when a web area came back
    /// empty or a web-renderer app produced a sparse tree). Apps that reject
    /// a forced opt-in are remembered so we stop asking.
    @discardableResult
    func enable(pid: pid_t, force: Bool = false) -> WebAXEnableOutcome {
        if unsupportedPids.contains(pid) { return .unsupported }
        guard force || !attemptedPids.contains(pid) else { return .skipped }
        attemptedPids.insert(pid)
        let app = AXUIElementCreateApplication(pid)
        var names: CFArray?
        AXUIElementCopyAttributeNames(app, &names)
        let advertised = (names as? [String]) ?? []
        var attempted = false
        var succeeded = false
        for attribute in ["AXEnhancedUserInterface", "AXManualAccessibility"]
        where force || advertised.contains(attribute) {
            attempted = true
            if AXUIElementSetAttributeValue(app, attribute as CFString, kCFBooleanTrue) == .success {
                succeeded = true
            }
        }
        if succeeded {
            guard force else { return .applied }
            return forcedPids.insert(pid).inserted ? .applied : .alreadyApplied
        }
        guard attempted else { return .skipped }
        if force { unsupportedPids.insert(pid) }
        return .unsupported
    }

    /// Memoized appLooksLikeWebRenderer — the bundle's Frameworks directory
    /// does not change while the app runs.
    func looksLikeWebRenderer(pid: pid_t) -> Bool {
        if let known = webRendererPids[pid] { return known }
        let result = appLooksLikeWebRenderer(pid: pid)
        webRendererPids[pid] = result
        return result
    }
}

/// Framework names that mark an app as an embedded-web renderer whose UI
/// lives behind the Chromium accessibility opt-in. Used to decide whether a
/// sparse tree is worth a forced enable attempt — native apps are left alone
/// because AXEnhancedUserInterface is a real behavior switch for them.
func frameworksIndicateWebRenderer(_ frameworkNames: [String]) -> Bool {
    frameworkNames.contains { name in
        let lowered = name.lowercased()
        return lowered.contains("chromium embedded framework")
            || lowered.contains("electron framework")
    }
}

func appLooksLikeWebRenderer(pid: pid_t) -> Bool {
    guard let bundleURL = NSRunningApplication(processIdentifier: pid)?.bundleURL else {
        return false
    }
    let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks").path
    let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworks)) ?? []
    return frameworksIndicateWebRenderer(names)
}

/// True when the tree contains an AXWebArea with no emitted content below it
/// — the signature of a Chromium/Electron app whose web accessibility is off
/// (or still building). Elements are emitted in DFS order, so a web area's
/// content, if any survived filtering, immediately follows it.
func hasEmptyWebArea(_ elements: [SnapshotElement]) -> Bool {
    for (index, element) in elements.enumerated() where element.role == "AXWebArea" {
        let prefix = element.path
        let next = index + 1 < elements.count ? elements[index + 1] : nil
        let hasContent =
            next.map { $0.path.count > prefix.count && Array($0.path.prefix(prefix.count)) == prefix } ?? false
        if !hasContent { return true }
    }
    return false
}

func axAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value
}

func axString(_ element: AXUIElement, _ name: String) -> String? {
    guard let value = axAttribute(element, name) else { return nil }
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    if CFGetTypeID(value) == CFBooleanGetTypeID() {
        return (value as! CFBoolean) == kCFBooleanTrue ? "true" : "false"
    }
    if let attributed = value as? NSAttributedString { return attributed.string }
    if let url = value as? URL { return url.absoluteString }
    return nil
}

func axBool(_ element: AXUIElement, _ name: String) -> Bool? {
    guard let value = axAttribute(element, name), CFGetTypeID(value) == CFBooleanGetTypeID() else {
        return nil
    }
    return (value as! CFBoolean) == kCFBooleanTrue
}

func axElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    guard let value = axAttribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else {
        return nil
    }
    return (value as! AXUIElement)
}

func axElements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
    guard let value = axAttribute(element, name), let array = value as? [AnyObject] else {
        return []
    }
    return array.compactMap {
        CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
    }
}

/// Element frame in global screen coordinates (top-left origin).
func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let positionValue = axAttribute(element, kAXPositionAttribute),
        let sizeValue = axAttribute(element, kAXSizeAttribute),
        CFGetTypeID(positionValue) == AXValueGetTypeID(),
        CFGetTypeID(sizeValue) == AXValueGetTypeID()
    else { return nil }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    else { return nil }
    return CGRect(origin: position, size: size)
}

func axActionNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success,
        let array = names as? [String]
    else { return [] }
    return array
}

func axRole(_ element: AXUIElement) -> String {
    axString(element, kAXRoleAttribute) ?? "AXUnknown"
}

/// Roles whose accessibility label tracks the field's contents rather than a
/// fixed name: macOS drops AXDescription once a field is filled, and the
/// placeholder or value shows through the label fallbacks instead. Their
/// label is state, not identity — locators and identity checks anchor these
/// by role + structure.
func isTextEntryRole(_ role: String) -> Bool {
    switch role {
    case "AXTextField", "AXTextArea", "AXSecureTextField", "AXComboBox": return true
    default: return false
    }
}

/// Best human-readable label for an element, used by the safety policy and
/// result notes. Falls back through title, description, help, an associated
/// title element, then value.
func clickableLabel(_ element: AXUIElement) -> String? {
    for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
        if let value = axString(element, attribute), !value.isEmpty { return value }
    }
    if let titleElement = axElement(element, kAXTitleUIElementAttribute),
        let value = axString(titleElement, kAXValueAttribute) ?? axString(titleElement, kAXTitleAttribute),
        !value.isEmpty
    {
        return value
    }
    if let value = axString(element, kAXValueAttribute), !value.isEmpty { return value }
    return nil
}

func requireAccessibilityTrusted() throws {
    guard AXIsProcessTrusted() else {
        throw ToolError.failed(
            """
            Accessibility permission is not granted to this process. Run \
            `computer-use-mcp doctor --prompt` and enable the host app under \
            System Settings → Privacy & Security → Accessibility.
            """
        )
    }
}
