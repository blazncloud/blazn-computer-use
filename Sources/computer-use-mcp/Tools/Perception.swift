// Perception: list_apps and get_app_state, plus the shared fresh-state
// result that every interaction tool returns after acting.

import ApplicationServices
import Foundation
import MCP

func listAppsImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    .text(runningAppsDescription())
}

func getAppStateImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))

    // Scoped query: rebuild the tree from one element down, with full budget —
    // the recourse when the whole-window tree is truncated.
    var scope: TreeScope?
    if let scopeID = args.string("scope_element_id") {
        let target = try await resolveTarget(app: app, elementID: scopeID)
        scope = TreeScope(root: target.element, pathPrefix: target.snapshotElement.path)
    }
    return try await stateResult(
        app: app, windowTitle: args.string("window_title"),
        screenshot: args.bool("include_screenshot") == false ? .none : .full,
        scope: scope, maxElements: args.integer("max_elements") ?? defaultMaxTreeElements,
        ocr: args.bool("ocr") == true
    )
}

/// Below this element count a window tree is considered sparse: likely a
/// custom-drawn UI or an embedded web view whose accessibility is off.
let sparseTreeThreshold = 10

/// Guidance appended to a sparse get_app_state tree. When the app provably
/// rejected the web-accessibility opt-in, say so — the agent should go
/// straight to OCR + coordinate clicks instead of re-fetching the tree.
func sparseTreeHint(webAXUnsupported: Bool) -> String {
    if webAXUnsupported {
        return
            "The accessibility tree is sparse and this app's embedded web view rejects the "
            + "accessibility opt-in, so its UI cannot be exposed as elements. Call get_app_state "
            + "with ocr:true to read on-screen text, then act by screenshot coordinates — both "
            + "work in the background."
    }
    return
        "The accessibility tree is sparse — this app may draw its own UI. "
        + "Call get_app_state with ocr:true to read on-screen text with clickable coordinates."
}

/// A subtree root to build the element tree from, with its locator path from
/// the window root so resolved paths stay anchored at the window.
/// @unchecked: AXUIElement is an immutable thread-safe CF handle.
struct TreeScope: @unchecked Sendable {
    let root: AXUIElement
    let pathPrefix: [LocatorStep]
}

/// Result detail for an action: reduced screenshot by default,
/// include_screenshot=false drops the image, include_state=false drops
/// everything but the confirmation note (fastest chained-action mode).
func screenshotDetail(_ args: [String: Value]) -> ScreenshotDetail {
    if args.bool("include_state") == false { return .noState }
    return args.bool("include_screenshot") == false ? .none : .reduced
}

/// Build the canonical app-state result: accessibility tree (with element ids
/// and screenshot-pixel bounding boxes) plus a screenshot of the target
/// window. Persists the snapshot so element ids resolve in later calls.
func stateResult(
    app: ResolvedApp,
    windowTitle: String?,
    note: String? = nil,
    screenshot detail: ScreenshotDetail = .reduced,
    scope: TreeScope? = nil,
    maxElements: Int = defaultMaxTreeElements,
    ocr: Bool = false,
    focusTelemetry: FocusTelemetry? = nil
) async throws -> CallTool.Result {
    try requireAccessibilityTrusted()

    // Every tool call lands here; let the cursor overlay know the agent is
    // still mid-task so it stays visible across the whole operation.
    await AgentCursor.shared.keepAlive()

    if detail == .noState {
        let confirmation = note ?? "Action completed."
        return CallTool.Result.text(confirmation + " Call get_app_state when you need the updated UI state.")
            .withFocusTelemetry(focusTelemetry)
    }

    // Give the UI a brief beat to settle after whatever just happened.
    try? await Task.sleep(for: .milliseconds(40))

    // Actions can close or replace the window they acted in (dialogs,
    // sheets); fall back to the front window rather than failing.
    let window: TargetWindow
    var windowNote: String?
    do {
        window = try targetWindow(for: app, title: windowTitle)
    } catch where windowTitle != nil {
        window = try targetWindow(for: app, title: nil)
        windowNote = "Window \"\(windowTitle!)\" is gone; showing the front window instead."
    }

    var capture: WindowCapture?
    var captureNote: String?
    if detail != .none {
        do {
            capture = try await captureWindow(pid: app.pid, title: window.title, frame: window.frame, detail: detail)
        } catch {
            captureNote = "Screenshot unavailable: \(error)"
        }
    }

    // Guard both terms: a degenerate capture or zero-width window must not
    // produce a 0 (or infinite) scale that breaks pixel→point conversion.
    let pixelsPerPoint: Double
    if let capture, capture.pixelWidth > 0, window.frame.width > 0 {
        pixelsPerPoint = Double(capture.pixelWidth) / window.frame.width
    } else if let prior = await SnapshotStore.shared.load(forPid: app.pid), prior.pixelsPerPoint > 0 {
        // No new screenshot: keep coordinates in the pixel space of the last
        // one the agent saw, so its ids and coordinates stay comparable.
        pixelsPerPoint = prior.pixelsPerPoint
    } else {
        pixelsPerPoint = 1
    }

    // Chromium/Electron apps need an assistive client on record before they
    // render web content into the accessibility tree.
    await AssistiveAccess.shared.enable(pid: app.pid)

    func captureSnapshot() async -> (snapshot: AppSnapshot, tree: BuiltTree, unchanged: Bool, diff: TreeDiff?) {
        await SnapshotStore.shared.capture(
            pid: app.pid,
            bundleIdentifier: app.bundleIdentifier,
            windowTitle: window.title,
            windowOrigin: window.frame.origin,
            pixelsPerPoint: pixelsPerPoint,
            windowSize: [window.frame.width * pixelsPerPoint, window.frame.height * pixelsPerPoint],
            createdAt: Date(),
            scoped: scope != nil
        ) { generation in
            buildTree(
                window: scope?.root ?? window.element,
                windowOrigin: window.frame.origin,
                pixelsPerPoint: pixelsPerPoint,
                generation: generation,
                pathPrefix: scope?.pathPrefix ?? [],
                maxElements: maxElements
            )
        }
    }

    var (snapshot, tree, unchanged, diff) = await captureSnapshot()
    var webAXUnsupported = false
    let emptyWebArea = hasEmptyWebArea(tree.elements)
    var needsWebAX = emptyWebArea
    if !needsWebAX && tree.elements.count < sparseTreeThreshold {
        needsWebAX = await AssistiveAccess.shared.looksLikeWebRenderer(pid: app.pid)
    }
    if needsWebAX {
        // Web accessibility was off or mid-build: force the flags on, give
        // the renderer a beat to populate the tree, and rebuild once. Some
        // embedded-web apps (CEF builds without accessibility wiring) reject
        // the opt-in — skip the settle-and-rebuild and say so in the hint.
        // A sparse tree that stayed sparse after an earlier forced enable is
        // just a small window: don't re-pay the settle on every call.
        let outcome = await AssistiveAccess.shared.enable(pid: app.pid, force: true)
        if outcome == .applied || (outcome == .alreadyApplied && emptyWebArea) {
            try? await Task.sleep(for: .milliseconds(500))
            (snapshot, tree, unchanged, diff) = await captureSnapshot()
        } else if outcome == .unsupported {
            webAXUnsupported = true
        }
    }

    var text = ""
    if let note {
        text += note + "\n\n"
    }
    if let windowNote {
        text += windowNote + "\n\n"
    }
    text += "App: \(app.name) (\(app.bundleIdentifier), pid \(app.pid))\n"
    text += "Window: \"\(window.title ?? "untitled")\""
    if let capture {
        text += " — screenshot \(capture.pixelWidth)x\(capture.pixelHeight) px"
        text += " (element boxes and x/y coordinates are in these pixels)"
    } else if detail == .none {
        text += " — screenshot omitted (element boxes stay in the previous screenshot's pixel scale)"
    }
    text += "\n"
    if let captureNote {
        text += captureNote + "\n"
    }
    // Action results skip resending a tree the agent already has; explicit
    // perception (get_app_state, .full) always returns it. A changed tree
    // whose diff is compact is sent as the diff — surviving elements carried
    // their ids over, so everything the agent holds stays valid.
    if unchanged && detail != .full {
        text +=
            "UI tree unchanged by this action: element ids from generation "
            + "\(snapshot.generation) remain valid, reuse them."
    } else if detail != .full, let diff, diff.isCompact {
        text +=
            "Changed since the last state (~ changed, + added, - removed; "
            + "all other element ids remain valid):\n"
        text += diff.text
    } else {
        text += "Elements: id role \"label\" (x,y,w,h) …\n"
        text += tree.text
    }

    if ocr {
        if let capture {
            let lines = (try? await recognizeText(
                inPNG: capture.pngData, pixelWidth: capture.pixelWidth, pixelHeight: capture.pixelHeight
            )) ?? []
            text += "\n\nOCR text (x,y,w,h in screenshot pixels; click by coordinates):\n"
            text += lines.isEmpty
                ? "(no text recognized)"
                : lines.map { "\"\($0.text)\" (\($0.box[0]),\($0.box[1]),\($0.box[2]),\($0.box[3]))" }
                    .joined(separator: "\n")
        } else {
            text += "\n\nOCR unavailable: no screenshot was captured."
        }
    } else if detail == .full && tree.elements.count < sparseTreeThreshold {
        text += "\n\n" + sparseTreeHint(webAXUnsupported: webAXUnsupported)
    }

    var enrichedTelemetry = focusTelemetry
    enrichedTelemetry?.uiChanged = !unchanged
    if unchanged, let hint = droppedEventHint(deliveryTier: focusTelemetry?.deliveryTier) {
        text += "\n\n" + hint
    }

    var content: [Tool.Content] = [.text(text: text, annotations: nil, _meta: nil)]
    if let capture {
        content.append(
            .image(
                data: capture.pngData.base64EncodedString(),
                mimeType: "image/png",
                annotations: nil,
                _meta: nil
            )
        )
    }
    return .init(content: content, isError: false).withFocusTelemetry(enrichedTelemetry)
}

/// Guidance when a synthetic background-event delivery produced no visible
/// UI change — the one observable hint that the app may have dropped the
/// event. AX-tier actions either succeed or throw, so they get no hint.
func droppedEventHint(deliveryTier: String?) -> String? {
    guard let deliveryTier, isDroppableBackgroundDeliveryTier(deliveryTier) else { return nil }
    return
        "No visible UI change followed this action. It was delivered via background events, "
        + "which some apps drop. If the intended effect did not happen, retry with "
        + "allow_global_cursor:true and allow_focus_change:true."
}
