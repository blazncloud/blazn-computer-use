// App-state snapshots and the locator engine.
//
// Element ids ("e12") are positions in the most recent snapshot of an app.
// AX element references go stale whenever an app relayouts, so a snapshot
// stores a *locator* per element — the path of (role, index-among-same-role-
// siblings) steps from the window root — and actions re-resolve the locator
// against the live tree, retrying briefly to let the UI settle. This mirrors
// the lazily-resolved-locator pattern used by mature UI automation tools.
//
// Snapshots are persisted to disk so ids work across processes (the `serve`
// server and the `call` harness, or a restarted server).

import ApplicationServices
import Foundation

struct LocatorStep: Codable {
    let role: String
    /// Index among siblings that share this role.
    let indexOfRole: Int
}

struct SnapshotElement: Codable {
    let id: String
    let role: String
    let label: String?
    let path: [LocatorStep]
    /// Bounding box in screenshot pixel coordinates.
    let frame: [Double]
}

struct AppSnapshot: Codable {
    let pid: Int32
    let bundleIdentifier: String
    let windowTitle: String?
    /// Window origin in global screen coordinates (top-left origin).
    let windowOrigin: [Double]
    /// Multiplier from window points to screenshot pixels.
    let pixelsPerPoint: Double
    /// Window size in screenshot pixels, for coordinate bounds checks (the
    /// element list may be scoped to a subtree). Optional for old snapshots.
    let windowSize: [Double]?
    let createdAt: Date
    /// Generation tag baked into element ids (e.g. "e11@s3"), so an id from
    /// an older state is rejected loudly instead of silently resolving to
    /// whatever occupies that index now.
    let generation: String
    let elements: [SnapshotElement]

    func element(withID id: String) -> SnapshotElement? {
        elements.first { $0.id == id }
    }

    /// Convert a screenshot pixel coordinate to global screen points.
    func screenPoint(fromScreenshotX x: Double, y: Double) -> CGPoint {
        CGPoint(
            x: windowOrigin[0] + x / pixelsPerPoint,
            y: windowOrigin[1] + y / pixelsPerPoint
        )
    }
}

/// Serializes snapshot capture and lookup so concurrent same-pid tool calls
/// cannot race on the generation counter. An in-memory cache is the source of
/// truth; disk is write-through so element ids survive across processes.
actor SnapshotStore {
    static let shared = SnapshotStore()

    private var cache: [pid_t: AppSnapshot] = [:]
    private var counters: [pid_t: Int] = [:]

    private static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("computer-use-mcp", isDirectory: true)
    }

    private static func url(forPid pid: pid_t) -> URL {
        directory.appendingPathComponent("snapshot-\(pid).json")
    }

    /// Allocate the next generation, build the tree with it, and persist —
    /// all atomically, so a second same-pid capture cannot collide.
    func capture(
        pid: pid_t, bundleIdentifier: String, windowTitle: String?,
        windowOrigin: CGPoint, pixelsPerPoint: Double, windowSize: [Double]?, createdAt: Date,
        buildTree: (String) -> BuiltTree
    ) -> (snapshot: AppSnapshot, tree: BuiltTree) {
        let next = (counters[pid] ?? loadFromDisk(pid).map(Self.parseGeneration) ?? 0) + 1
        counters[pid] = next
        let generation = "s\(next)"
        let tree = buildTree(generation)
        let snapshot = AppSnapshot(
            pid: pid, bundleIdentifier: bundleIdentifier, windowTitle: windowTitle,
            windowOrigin: [windowOrigin.x, windowOrigin.y], pixelsPerPoint: pixelsPerPoint,
            windowSize: windowSize, createdAt: createdAt, generation: generation, elements: tree.elements
        )
        cache[pid] = snapshot
        persist(snapshot)
        return (snapshot, tree)
    }

    func load(forPid pid: pid_t) -> AppSnapshot? {
        if let cached = cache[pid] { return cached }
        guard let disk = loadFromDisk(pid) else { return nil }
        cache[pid] = disk
        counters[pid] = max(counters[pid] ?? 0, Self.parseGeneration(disk))
        return disk
    }

    private func loadFromDisk(_ pid: pid_t) -> AppSnapshot? {
        guard let data = try? Data(contentsOf: Self.url(forPid: pid)) else { return nil }
        return try? JSONDecoder().decode(AppSnapshot.self, from: data)
    }

    private func persist(_ snapshot: AppSnapshot) {
        // The in-memory cache is the source of truth; disk only matters for
        // cross-process id resolution (serve vs call, restarts). Still, a
        // persist failure should leave a trace, not vanish.
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: Self.url(forPid: snapshot.pid), options: .atomic)
        } catch {
            FileHandle.standardError.write(
                Data("[computer-use-mcp] snapshot persist failed for pid \(snapshot.pid): \(error)\n".utf8)
            )
        }
        pruneStaleFiles()
    }

    /// Best-effort: drop snapshot files older than an hour so the temp dir
    /// doesn't accumulate files for exited apps / recycled pids.
    private func pruneStaleFiles() {
        let cutoff = Date(timeIntervalSinceNow: -3600)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: Self.directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for url in entries where url.lastPathComponent.hasPrefix("snapshot-") {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func parseGeneration(_ snapshot: AppSnapshot) -> Int {
        Int(snapshot.generation.dropFirst()) ?? 0
    }
}

/// Re-resolve a snapshot element against the live accessibility tree.
/// Retries briefly so a UI that is mid-update can settle, and verifies the
/// resolved element still matches the snapshot's identity (role + label) so a
/// relayout turns into a clear stale-id error instead of a silent mis-click.
func resolveElement(_ element: SnapshotElement, in window: AXUIElement) async throws -> AXUIElement {
    let deadline = Date().addingTimeInterval(1.0)
    var lastFailure = "locator path did not resolve"

    repeat {
        if let resolved = walkLocator(element.path, from: window) {
            if matchesIdentity(resolved, of: element) {
                return resolved
            }
            let liveLabel = elementLabel(resolved) ?? "no label"
            lastFailure =
                "the element at path \(describePath(element.path)) is now "
                + "\(axRole(resolved)) \"\(liveLabel)\", not what \(element.id) referred to"
        } else {
            lastFailure = "no element at path \(describePath(element.path))"
        }
        // Task.sleep, not Thread.sleep: this runs on the cooperative pool and
        // must suspend rather than block a shared executor thread.
        try? await Task.sleep(for: .milliseconds(150))
    } while Date() < deadline

    throw ToolError.failed(
        "Element \(element.id) (\(element.role)\(element.label.map { " \"\($0)\"" } ?? "")) "
            + "is stale: \(lastFailure). The UI has changed since that state was captured — "
            + "call get_app_state and use a fresh element id."
    )
}

/// Fail fast with a clear message when the target app has quit or crashed,
/// instead of surfacing a confusing stale-element or no-window error.
func requireAppAlive(_ app: ResolvedApp) throws {
    if appIsGone(pid: app.pid) {
        throw ToolError.failed(
            "\(app.name) (pid \(app.pid)) has quit or crashed since it was resolved. "
                + "Call list_apps to see what is running, then get_app_state on the new instance."
        )
    }
}

private func elementLabel(_ element: AXUIElement) -> String? {
    axString(element, kAXTitleAttribute)
        ?? axString(element, kAXDescriptionAttribute)
        ?? axString(element, "AXPlaceholderValue")
}

private func matchesIdentity(_ live: AXUIElement, of element: SnapshotElement) -> Bool {
    guard axRole(live) == element.role else { return false }
    // Only enforce label identity when the snapshot had one; unlabeled
    // containers are identified by structure alone.
    guard let expected = element.label, !expected.isEmpty else { return true }
    return elementLabel(live) == expected
}

private func walkLocator(_ path: [LocatorStep], from root: AXUIElement) -> AXUIElement? {
    var current = root
    for step in path {
        let children = axElements(current, kAXChildrenAttribute)
        let matching = children.filter { axRole($0) == step.role }
        guard step.indexOfRole < matching.count else { return nil }
        current = matching[step.indexOfRole]
    }
    return current
}

private func describePath(_ path: [LocatorStep]) -> String {
    path.map { "\($0.role)[\($0.indexOfRole)]" }.joined(separator: "/")
}
