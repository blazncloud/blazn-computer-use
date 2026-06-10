// Thin helpers over the C Accessibility (AXUIElement) API.

import ApplicationServices
import Foundation

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
