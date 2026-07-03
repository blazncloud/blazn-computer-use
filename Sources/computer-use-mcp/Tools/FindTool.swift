// find — server-side element search, so the agent can locate a control by
// text without pulling (and paying for) a whole window tree. Searches a much
// deeper tree than get_app_state returns (5000 elements vs 500) and persists
// the snapshot, so returned element ids are immediately usable.

import Foundation
import MCP

func findImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    let query = try args.requireString("query")
    let lowered = query.lowercased()
    let roleFilter = args.string("role")
    let maxResults = max(1, min(args.integer("max_results") ?? 20, 100))

    try requireAccessibilityTrusted()
    try requireAppAlive(app)
    await AgentCursor.shared.keepAlive()
    await AssistiveAccess.shared.enable(pid: app.pid)

    let window = try targetWindow(for: app, title: args.string("window_title"))
    // No screenshot here: keep coordinates in the scale of the last one the
    // agent saw (mirrors stateResult's no-capture path).
    let pixelsPerPoint = await SnapshotStore.shared.load(forPid: app.pid)
        .map(\.pixelsPerPoint).flatMap { $0 > 0 ? $0 : nil } ?? 1

    func capture() async -> (snapshot: AppSnapshot, tree: BuiltTree, unchanged: Bool, diff: TreeDiff?) {
        await SnapshotStore.shared.capture(
            pid: app.pid,
            bundleIdentifier: app.bundleIdentifier,
            windowTitle: window.title,
            windowOrigin: window.frame.origin,
            pixelsPerPoint: pixelsPerPoint,
            windowSize: [window.frame.width * pixelsPerPoint, window.frame.height * pixelsPerPoint],
            createdAt: Date()
        ) { generation in
            buildTree(
                window: window.element,
                windowOrigin: window.frame.origin,
                pixelsPerPoint: pixelsPerPoint,
                generation: generation,
                maxElements: 5000,
                // Search must see off-screen collection rows, so it never windows.
                windowCollections: false
            )
        }
    }

    var (snapshot, tree, unchanged, _) = await capture()
    if hasEmptyWebArea(tree.elements) {
        await AssistiveAccess.shared.enable(pid: app.pid, force: true)
        try? await Task.sleep(for: .milliseconds(500))
        (snapshot, tree, unchanged, _) = await capture()
    }

    // Tree text lines map 1:1 onto elements (truncation notices trail them),
    // and each line carries the label and value the agent would see — match
    // against the line so values count, not just labels. When the store kept
    // the previous (identical) snapshot, the fresh build's ids were never
    // committed — substitute the committed id, same position, same element.
    let lines = tree.text.split(separator: "\n", omittingEmptySubsequences: false)
    var matches: [String] = []
    var total = 0
    for (index, line) in lines.enumerated() where index < tree.elements.count {
        let element = tree.elements[index]
        if let roleFilter, element.role != roleFilter { continue }
        guard line.lowercased().contains(lowered) else { continue }
        total += 1
        if matches.count < maxResults {
            var display = line.trimmingCharacters(in: .whitespaces)
            if unchanged, index < snapshot.elements.count {
                display = display.replacingOccurrences(of: element.id, with: snapshot.elements[index].id)
            }
            matches.append(display)
        }
    }

    var text = "App: \(app.name) (\(app.bundleIdentifier), pid \(app.pid))\n"
    text += "Window: \"\(window.title ?? "untitled")\"\n"
    if matches.isEmpty {
        text += "No elements match \"\(query)\""
        if let roleFilter { text += " with role \(roleFilter)" }
        text += ". The search covered up to 5000 elements of this window; try a shorter "
        text += "query, drop the role filter, or call get_app_state to see the tree."
    } else {
        text += "\(total) element(s) match \"\(query)\""
        if let roleFilter { text += " (role \(roleFilter))" }
        if total > matches.count { text += "; showing the first \(matches.count)" }
        text += ". Ids are fresh and usable directly (boxes in the last screenshot's pixels):\n"
        text += matches.joined(separator: "\n")
    }
    return .text(text)
}
