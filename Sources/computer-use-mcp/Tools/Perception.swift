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
        app: app, windowTitle: args.string("window_title"), screenshot: .full,
        scope: scope, maxElements: args.integer("max_elements") ?? defaultMaxTreeElements
    )
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
    maxElements: Int = defaultMaxTreeElements
) async throws -> CallTool.Result {
    try requireAccessibilityTrusted()

    // Every tool call lands here; let the cursor overlay know the agent is
    // still mid-task so it stays visible across the whole operation.
    await AgentCursor.shared.keepAlive()

    if detail == .noState {
        let confirmation = note ?? "Action completed."
        return .text(confirmation + " Call get_app_state when you need the updated UI state.")
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

    let (_, tree) = await SnapshotStore.shared.capture(
        pid: app.pid,
        bundleIdentifier: app.bundleIdentifier,
        windowTitle: window.title,
        windowOrigin: window.frame.origin,
        pixelsPerPoint: pixelsPerPoint,
        windowSize: [window.frame.width * pixelsPerPoint, window.frame.height * pixelsPerPoint],
        createdAt: Date()
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
    text += "Elements: id role \"label\" (x,y,w,h) …\n"
    text += tree.text

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
    return .init(content: content, isError: false)
}
