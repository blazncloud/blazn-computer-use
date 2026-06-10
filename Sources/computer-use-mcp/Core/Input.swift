// Background-safe synthetic input delivery.
//
// The ladder, in order of preference, for delivering a mouse/scroll/key event
// without moving the user's real cursor or stealing focus:
//
//   Tier 1  AX action (AXPress etc.)        — handled by callers, no event posted
//   Tier 2  per-window NSEvent → CGEventPostToPid  — routed to a specific window
//   Tier 3  CGEventPostToPid (no window affinity)  — delivered to the pid
//   Tier 4  global cursor (CGWarp + session tap)   — GUARDED, opt-in, restores cursor
//
// Tiers 2–3 use CGEventPostToPid, which delivers to a process without
// foreground activation and never touches the system cursor. It is documented
// as app-dependent (some apps that require real key focus may drop events);
// there is no reliable success signal, so escalation to Tier 4 is never
// automatic — it requires the caller's explicit opt-in.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Private SPI mapping an AX window element to its CGWindowID, used as the
// NSEvent windowNumber. Undocumented but stable; always guard the result.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

func windowID(for axWindow: AXUIElement) -> CGWindowID? {
    var id = CGWindowID(0)
    guard _AXUIElementGetWindow(axWindow, &id) == .success, id != 0 else { return nil }
    return id
}

enum InputTier: String {
    case perWindow = "tier2-per-window-nsevent"
    case perPid = "tier3-cgeventpostto-pid"
    case globalCursor = "tier4-global-cursor"
}

struct DeliveryContext {
    let pid: pid_t
    /// CGWindowID of the target window, when resolvable (enables Tier 2).
    let windowNumber: CGWindowID?
    /// Target window's global frame (top-left origin), for coordinate conversion.
    let windowFrame: CGRect?
    let allowGlobalCursor: Bool
}

enum MouseButtonKind {
    case left, right, middle

    var cgButton: CGMouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }
    var downType: CGEventType {
        switch self {
        case .left: return .leftMouseDown
        case .right: return .rightMouseDown
        case .middle: return .otherMouseDown
        }
    }
    var upType: CGEventType {
        switch self {
        case .left: return .leftMouseUp
        case .right: return .rightMouseUp
        case .middle: return .otherMouseUp
        }
    }
}

/// Deliver a click at a global point. Returns the tier actually used.
///
/// Background-safe by default (Tier 2/3). When the caller explicitly opts in
/// with allow_global_cursor — the escape hatch for stubborn apps that drop
/// per-pid events — it uses the Tier 4 real-cursor path instead.
@discardableResult
func deliverClick(
    at point: CGPoint, button: MouseButtonKind, clickCount: Int, context: DeliveryContext
) throws -> InputTier {
    if context.allowGlobalCursor {
        return deliverClickGlobal(at: point, button: button, clickCount: clickCount, context: context)
    }

    let source = CGEventSource(stateID: .privateState)
    func makeEvent(_ type: CGEventType, clickState: Int) -> CGEvent? {
        let event = CGEvent(
            mouseEventSource: source, mouseType: type,
            mouseCursorPosition: point, mouseButton: button.cgButton
        )
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        return event
    }

    var tier: InputTier = context.windowNumber != nil ? .perWindow : .perPid
    for clickState in 1...clickCount {
        guard let down = makeEvent(button.downType, clickState: clickState),
            let up = makeEvent(button.upType, clickState: clickState)
        else {
            throw ToolError.failed("Could not synthesize a click event.")
        }
        tier = postToTarget(down: down, up: up, at: point, context: context)
    }
    return tier
}

/// Post a down/up pair to the target, preferring window-affined delivery.
private func postToTarget(down: CGEvent, up: CGEvent, at point: CGPoint, context: DeliveryContext) -> InputTier {
    if let windowNumber = context.windowNumber, let frame = context.windowFrame,
        let localDown = bridgedWindowEvent(from: down, point: point, windowNumber: windowNumber, windowFrame: frame),
        let localUp = bridgedWindowEvent(from: up, point: point, windowNumber: windowNumber, windowFrame: frame)
    {
        localDown.postToPid(context.pid)
        localUp.postToPid(context.pid)
        return .perWindow
    }
    down.postToPid(context.pid)
    up.postToPid(context.pid)
    return .perPid
}

/// Build a window-routed CGEvent by bridging an NSEvent carrying a windowNumber.
/// NSEvent locations are window-local, bottom-left origin.
private func bridgedWindowEvent(
    from cgEvent: CGEvent, point: CGPoint, windowNumber: CGWindowID, windowFrame: CGRect
) -> CGEvent? {
    guard let screenHeight = NSScreen.screens.first?.frame.height else { return nil }
    let localX = point.x - windowFrame.origin.x
    // Convert global top-left Y to window-local bottom-left Y.
    let globalBottomLeftY = screenHeight - point.y
    let windowBottomLeftY = screenHeight - (windowFrame.origin.y + windowFrame.height)
    let localY = globalBottomLeftY - windowBottomLeftY

    let nsType: NSEvent.EventType
    switch cgEvent.type {
    case .leftMouseDown: nsType = .leftMouseDown
    case .leftMouseUp: nsType = .leftMouseUp
    case .rightMouseDown: nsType = .rightMouseDown
    case .rightMouseUp: nsType = .rightMouseUp
    case .otherMouseDown: nsType = .otherMouseDown
    case .otherMouseUp: nsType = .otherMouseUp
    case .leftMouseDragged: nsType = .leftMouseDragged
    default: return nil
    }
    let clickState = Int(cgEvent.getIntegerValueField(.mouseEventClickState))
    let event = NSEvent.mouseEvent(
        with: nsType, location: NSPoint(x: localX, y: localY), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: Int(windowNumber),
        context: nil, eventNumber: 0, clickCount: max(1, clickState), pressure: nsType.isDown ? 1 : 0
    )
    return event?.cgEvent
}

private extension NSEvent.EventType {
    // Button-held events carry full pressure (down and drag); releases carry 0.
    var isDown: Bool {
        self == .leftMouseDown || self == .rightMouseDown || self == .otherMouseDown
            || self == .leftMouseDragged
    }
}

/// Tier 4: guarded global cursor. Moves the real cursor, posts to the session
/// tap, then restores the cursor. Only reached on explicit opt-in.
private func deliverClickGlobal(
    at point: CGPoint, button: MouseButtonKind, clickCount: Int, context: DeliveryContext
) -> InputTier {
    let saved = CGEvent(source: nil)?.location
    CGWarpMouseCursorPosition(point)
    let source = CGEventSource(stateID: .combinedSessionState)
    for clickState in 1...clickCount {
        let down = CGEvent(mouseEventSource: source, mouseType: button.downType, mouseCursorPosition: point, mouseButton: button.cgButton)
        down?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        down?.post(tap: .cgSessionEventTap)
        let up = CGEvent(mouseEventSource: source, mouseType: button.upType, mouseCursorPosition: point, mouseButton: button.cgButton)
        up?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        up?.post(tap: .cgSessionEventTap)
    }
    if let saved { CGWarpMouseCursorPosition(saved) }
    return .globalCursor
}

/// Deliver scroll wheel events at a global point. Distributes the delta across
/// steps with error diffusion so the posted amounts sum exactly to the request
/// and a small axis is never truncated to zero.
func deliverScroll(at point: CGPoint, deltaX: Int, deltaY: Int, context: DeliveryContext) {
    let source = CGEventSource(stateID: .privateState)
    let stepCount = max(1, max(abs(deltaX), abs(deltaY)) / 40)
    var emittedX = 0
    var emittedY = 0
    for step in 1...stepCount {
        let targetX = Int((Double(deltaX) * Double(step) / Double(stepCount)).rounded())
        let targetY = Int((Double(deltaY) * Double(step) / Double(stepCount)).rounded())
        let stepX = targetX - emittedX
        let stepY = targetY - emittedY
        emittedX = targetX
        emittedY = targetY
        // Positive delta_y scrolls content up; wheel1 up is positive, so negate.
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                wheel1: Int32(-stepY), wheel2: Int32(stepX), wheel3: 0
            )
        else { continue }
        event.location = point
        event.postToPid(context.pid)
    }
}

/// Deliver a drag gesture from one global point to another.
func deliverDrag(from: CGPoint, to: CGPoint, context: DeliveryContext) async {
    let source = CGEventSource(stateID: .privateState)
    func post(_ type: CGEventType, _ p: CGPoint) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
        else { return }
        // Prefer window-affined delivery (Tier 2) when resolvable, like clicks.
        if let windowNumber = context.windowNumber, let frame = context.windowFrame,
            let bridged = bridgedWindowEvent(from: event, point: p, windowNumber: windowNumber, windowFrame: frame)
        {
            bridged.postToPid(context.pid)
        } else {
            event.postToPid(context.pid)
        }
    }
    post(.leftMouseDown, from)
    let steps = 24
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        post(.leftMouseDragged, p)
        try? await Task.sleep(for: .milliseconds(16))
    }
    post(.leftMouseUp, to)
}

/// Deliver a key chord to the target process.
func deliverKey(_ chord: KeyChord, context: DeliveryContext) throws {
    let source = CGEventSource(stateID: .privateState)
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: chord.keyCode, keyDown: true),
        let up = CGEvent(keyboardEventSource: source, virtualKey: chord.keyCode, keyDown: false)
    else {
        throw ToolError.failed("Could not synthesize a key event.")
    }
    down.flags = chord.flags
    up.flags = chord.flags
    if context.allowGlobalCursor && context.windowNumber == nil {
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    } else {
        down.postToPid(context.pid)
        up.postToPid(context.pid)
    }
}
