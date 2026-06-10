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
    return try await stateResult(app: app, windowTitle: args.string("window_title"))
}

/// Build the canonical app-state result: accessibility tree (with element ids
/// and screenshot-pixel bounding boxes) plus a screenshot of the target
/// window. Persists the snapshot so element ids resolve in later calls.
func stateResult(
    app: ResolvedApp,
    windowTitle: String?,
    note: String? = nil
) async throws -> CallTool.Result {
    try requireAccessibilityTrusted()

    // Give the UI a beat to settle after whatever just happened.
    try? await Task.sleep(for: .milliseconds(80))

    let window = try targetWindow(for: app, title: windowTitle)

    var capture: WindowCapture?
    var captureNote: String?
    do {
        capture = try await captureWindow(pid: app.pid, title: window.title, frame: window.frame)
    } catch {
        captureNote = "Screenshot unavailable: \(error)"
    }

    let pixelsPerPoint: Double
    if let capture, window.frame.width > 0 {
        pixelsPerPoint = Double(capture.pixelWidth) / window.frame.width
    } else {
        pixelsPerPoint = 1
    }

    let tree = buildTree(
        window: window.element,
        windowOrigin: window.frame.origin,
        pixelsPerPoint: pixelsPerPoint
    )

    SnapshotStore.save(
        AppSnapshot(
            pid: app.pid,
            bundleIdentifier: app.bundleIdentifier,
            windowTitle: window.title,
            windowOrigin: [window.frame.origin.x, window.frame.origin.y],
            pixelsPerPoint: pixelsPerPoint,
            createdAt: Date(),
            elements: tree.elements
        )
    )

    var text = ""
    if let note {
        text += note + "\n\n"
    }
    text += "App: \(app.name) (\(app.bundleIdentifier), pid \(app.pid))\n"
    text += "Window: \"\(window.title ?? "untitled")\""
    if let capture {
        text += " — screenshot \(capture.pixelWidth)x\(capture.pixelHeight) px"
        text += " (element boxes and x/y coordinates are in these pixels)"
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
