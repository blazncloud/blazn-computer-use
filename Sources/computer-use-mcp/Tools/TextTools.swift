// Text and value manipulation via the accessibility API: type_text,
// set_value, select_text, perform_secondary_action.

import ApplicationServices
import Foundation
import MCP

// MARK: - type_text

func typeTextImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    let text = try args.requireString("text")
    try ArgumentBounds.checkStringLength(text, argument: "text", maximum: ArgumentBounds.maxTypeTextCharacters)
    let confirmed = SafetyPolicy.confirmed(args)
    try SafetyPolicy.check(app: app, confirmed: confirmed)
    let focus = FocusChangeTracker.start()

    let element: AXUIElement
    let described: String
    if let elementID = args.string("element_id") {
        let target = try await resolveTarget(app: app, elementID: elementID)
        element = target.element
        described = describeTarget(target)
    } else {
        guard let focused = axElement(app.axApplication, kAXFocusedUIElementAttribute) else {
            throw ToolError.failed(
                "\(app.name) has no focused element. Pass element_id for the field to type into."
            )
        }
        element = focused
        described = "the focused element (\(axRole(focused)))"
    }

    try SafetyPolicy.checkTyping(into: element, app: app, confirmed: confirmed)
    try insertText(text, into: element, described: described)
    let warning = readBackWarning(typed: text, element: element)
    let snapshot = await SnapshotStore.shared.load(forPid: app.pid)
    return try await stateResult(
        app: app, windowTitle: snapshot?.windowTitle,
        note: "Typed \(text.count) characters into \(described). "
            + (warning ?? "Verify the new value below."),
        screenshot: screenshotDetail(args),
        focusTelemetry: focus.finish(deliveryTier: InputTier.accessibilityAttribute.rawValue)
    )
}

/// Read the element's value back after insertion and verify the typed text
/// actually landed — some apps report success for the AX write and then
/// ignore it. Skipped for secure fields (never echo), long texts, and huge
/// documents where the full-value read would be expensive.
private func readBackWarning(typed: String, element: AXUIElement) -> String? {
    guard axString(element, kAXSubroleAttribute) != "AXSecureTextField" else { return nil }
    if let count = (axAttribute(element, "AXNumberOfCharacters") as? NSNumber)?.intValue,
        count > 200_000
    {
        return nil
    }
    return typedTextWarning(typed: typed, currentValue: axString(element, kAXValueAttribute))
}

/// Pure part of the read-back check, separated for tests. nil when the typed
/// text is present or verification is not feasible.
func typedTextWarning(typed: String, currentValue: String?) -> String? {
    guard typed.count <= 500, !typed.isEmpty, let currentValue else { return nil }
    guard !currentValue.contains(typed) else { return nil }
    return
        "Warning: the element's value does not contain the typed text after insertion — "
        + "the app may have ignored or transformed the input. Inspect the state below "
        + "before proceeding."
}

/// Insert text at the element's current selection (collapsed selection =
/// caret). Prefers the canonical kAXSelectedText replacement; falls back to
/// splicing the full value.
private func insertText(_ text: String, into element: AXUIElement, described: String) throws {
    var settable = DarwinBoolean(false)

    // Preferred: replace the current selection.
    if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
        settable.boolValue,
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    {
        return
    }

    // Fallback: splice into the full value at the selected range.
    guard
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
        settable.boolValue
    else {
        throw ToolError.failed(
            "\(described) is not editable via accessibility. Target an editable field "
                + "(AXTextField/AXTextArea), or click it first and retry."
        )
    }

    let current = axString(element, kAXValueAttribute) ?? ""
    let nsCurrent = current as NSString
    var range = CFRange(location: nsCurrent.length, length: 0)
    if let rangeValue = axAttribute(element, kAXSelectedTextRangeAttribute),
        CFGetTypeID(rangeValue) == AXValueGetTypeID()
    {
        AXValueGetValue(rangeValue as! AXValue, .cfRange, &range)
    }
    let start = max(0, min(range.location, nsCurrent.length))
    let length = max(0, min(range.length, nsCurrent.length - start))
    let updated = nsCurrent.replacingCharacters(in: NSRange(location: start, length: length), with: text)

    guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, updated as CFString) == .success
    else {
        throw ToolError.failed("Could not set the value of \(described).")
    }

    // Place the caret after the inserted text.
    var caret = CFRange(location: start + (text as NSString).length, length: 0)
    if let caretValue = AXValueCreate(.cfRange, &caret) {
        AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, caretValue)
    }
}

// MARK: - set_value

func setValueImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    let confirmed = SafetyPolicy.confirmed(args)
    try SafetyPolicy.check(app: app, confirmed: confirmed)
    let focus = FocusChangeTracker.start()
    let target = try await resolveTarget(app: app, elementID: args.requireString("element_id"))
    try SafetyPolicy.checkTyping(into: target.element, app: app, confirmed: confirmed)
    // An empty value is valid (clearing a field), so accept "" rather than
    // treating it as a missing argument.
    guard let value = args.string("value") else {
        throw ToolError.invalidArguments("\"value\" (string) is required.")
    }
    try ArgumentBounds.checkStringLength(value, argument: "value", maximum: ArgumentBounds.maxSetValueCharacters)
    try SafetyPolicy.checkValueChange(
        currentValue: axString(target.element, kAXValueAttribute), newValue: value, app: app, confirmed: confirmed
    )

    // Checkboxes and radio buttons: treat as semantic toggle.
    if target.snapshotElement.role == "AXCheckBox" || target.snapshotElement.role == "AXRadioButton" {
        guard let desired = Bool(value.lowercased()) ?? (value == "1" ? true : value == "0" ? false : nil)
        else {
            throw ToolError.invalidArguments("For \(target.snapshotElement.role), value must be true or false.")
        }
        let current = axString(target.element, kAXValueAttribute) == "1"
        if current != desired {
            try performAXAction(kAXPressAction as String, on: target)
        }
        return try await stateResult(
            app: app, windowTitle: target.snapshot.windowTitle,
            note: "Set \(describeTarget(target)) to \(desired).",
            screenshot: screenshotDetail(args),
            focusTelemetry: focus.finish(deliveryTier: InputTier.accessibilityAction.rawValue)
        )
    }

    var settable = DarwinBoolean(false)
    guard
        AXUIElementIsAttributeSettable(target.element, kAXValueAttribute as CFString, &settable) == .success,
        settable.boolValue
    else {
        throw ToolError.failed(
            "\(describeTarget(target)) does not accept a direct value. Use click/type_text, "
                + "or check the element's actions in get_app_state."
        )
    }

    // Numeric elements (sliders, steppers) want numbers, not strings.
    let newValue: CFTypeRef
    let currentValue = axAttribute(target.element, kAXValueAttribute)
    if let currentValue, CFGetTypeID(currentValue) == CFNumberGetTypeID(), let number = Double(value) {
        newValue = NSNumber(value: number)
    } else {
        newValue = value as CFString
    }

    guard AXUIElementSetAttributeValue(target.element, kAXValueAttribute as CFString, newValue) == .success
    else {
        throw ToolError.failed("Setting the value of \(describeTarget(target)) failed.")
    }
    return try await stateResult(
        app: app, windowTitle: target.snapshot.windowTitle,
        note: "Set the value of \(describeTarget(target)). Verify it below.",
        screenshot: screenshotDetail(args),
        focusTelemetry: focus.finish(deliveryTier: InputTier.accessibilityAttribute.rawValue)
    )
}

// MARK: - select_text

func selectTextImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    let focus = FocusChangeTracker.start()
    let target = try await resolveTarget(app: app, elementID: args.requireString("element_id"))
    let text = try args.requireString("text")
    let occurrence = max(1, args.integer("occurrence") ?? 1)

    guard let value = axString(target.element, kAXValueAttribute) else {
        throw ToolError.failed("\(describeTarget(target)) has no text value to select within.")
    }

    let nsValue = value as NSString
    var searchStart = 0
    var found = NSRange(location: NSNotFound, length: 0)
    for _ in 0..<occurrence {
        found = nsValue.range(
            of: text, options: [], range: NSRange(location: searchStart, length: nsValue.length - searchStart)
        )
        guard found.location != NSNotFound else { break }
        searchStart = found.location + 1
    }
    guard found.location != NSNotFound else {
        throw ToolError.failed(
            "\"\(text)\" (occurrence \(occurrence)) was not found in \(describeTarget(target)). "
                + "Provide the text exactly as it appears in the element's value."
        )
    }

    // position: select the match (default), or collapse the caret to one end —
    // for inserting text before/after a landmark with type_text.
    let position = args.string("position") ?? "select"
    var range: CFRange
    let note: String
    switch position {
    case "select":
        range = CFRange(location: found.location, length: found.length)
        note = "Selected \"\(text)\" in \(describeTarget(target))."
    case "before":
        range = CFRange(location: found.location, length: 0)
        note = "Placed the cursor before \"\(text)\" in \(describeTarget(target))."
    case "after":
        range = CFRange(location: found.location + found.length, length: 0)
        note = "Placed the cursor after \"\(text)\" in \(describeTarget(target))."
    default:
        throw ToolError.invalidArguments("position must be select, before, or after.")
    }
    guard let rangeValue = AXValueCreate(.cfRange, &range),
        AXUIElementSetAttributeValue(target.element, kAXSelectedTextRangeAttribute as CFString, rangeValue)
            == .success
    else {
        throw ToolError.failed("\(describeTarget(target)) did not accept the text selection.")
    }
    return try await stateResult(
        app: app, windowTitle: target.snapshot.windowTitle,
        note: note,
        screenshot: screenshotDetail(args),
        focusTelemetry: focus.finish(deliveryTier: InputTier.accessibilityAttribute.rawValue)
    )
}

// MARK: - read_text

func readTextImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    let target = try await resolveTarget(app: app, elementID: args.requireString("element_id"))
    guard let value = axString(target.element, kAXValueAttribute) else {
        throw ToolError.failed("\(describeTarget(target)) has no readable text value.")
    }
    let offset = args.integer("offset") ?? 0
    let requested = args.integer("length") ?? 20_000
    try ArgumentBounds.checkReadText(offset: offset, length: requested)
    let characters = Array(value)
    guard offset < characters.count || characters.isEmpty else {
        throw ToolError.invalidArguments("offset \(offset) is past the end (\(characters.count) chars).")
    }
    let slice = String(characters[offset..<min(characters.count, offset + max(1, requested))])
    var header = "Text of \(describeTarget(target)) — \(characters.count) chars total"
    if offset > 0 || offset + slice.count < characters.count {
        header += ", showing \(offset)..<\(offset + slice.count) (use offset/length for more)"
    }
    return .text(header + ":\n" + slice)
}

// MARK: - perform_secondary_action

func performSecondaryActionImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    let confirmed = SafetyPolicy.confirmed(args)
    try SafetyPolicy.check(app: app, confirmed: confirmed)
    let focus = FocusChangeTracker.start()
    let target = try await resolveTarget(app: app, elementID: args.requireString("element_id"))
    let action = args.string("action") ?? "AXShowMenu"

    let available = axActionNames(target.element)
    guard available.contains(action) else {
        throw ToolError.failed(
            "\(describeTarget(target)) does not support \(action). "
                + "Available actions: \(available.joined(separator: ", "))."
        )
    }
    // Activating actions can be destructive (e.g. AXPress on a Delete button);
    // gate them like a click. Menu/stepper actions stay ungated.
    let activatingActions: Set<String> = [
        kAXPressAction as String, "AXConfirm", "AXPick", "AXOpen",
    ]
    if activatingActions.contains(action) {
        try SafetyPolicy.checkClick(label: clickableLabel(target.element), app: app, confirmed: confirmed)
    }
    try performAXAction(action, on: target)
    return try await stateResult(
        app: app, windowTitle: target.snapshot.windowTitle,
        note: "Performed \(action) on \(describeTarget(target)).",
        screenshot: screenshotDetail(args),
        focusTelemetry: focus.finish(deliveryTier: InputTier.accessibilityAction.rawValue)
    )
}
