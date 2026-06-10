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
    let createdAt: Date
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

enum SnapshotStore {
    private static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("computer-use-mcp", isDirectory: true)
    }

    private static func url(forPid pid: pid_t) -> URL {
        directory.appendingPathComponent("snapshot-\(pid).json")
    }

    static func save(_ snapshot: AppSnapshot) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url(forPid: snapshot.pid), options: .atomic)
        }
    }

    static func load(forPid pid: pid_t) -> AppSnapshot? {
        guard let data = try? Data(contentsOf: url(forPid: pid)) else { return nil }
        return try? JSONDecoder().decode(AppSnapshot.self, from: data)
    }
}

/// Re-resolve a snapshot element against the live accessibility tree.
/// Retries briefly so a UI that is mid-update can settle.
func resolveElement(_ element: SnapshotElement, in window: AXUIElement) throws -> AXUIElement {
    let deadline = Date().addingTimeInterval(1.0)
    var lastFailure = "locator path did not resolve"

    repeat {
        if let resolved = walkLocator(element.path, from: window) {
            return resolved
        }
        lastFailure = "no element at path \(describePath(element.path))"
        Thread.sleep(forTimeInterval: 0.15)
    } while Date() < deadline

    throw ToolError.failed(
        "Element \(element.id) (\(element.role)\(element.label.map { " \"\($0)\"" } ?? "")) "
            + "no longer resolves: \(lastFailure). The UI has changed — call get_app_state "
            + "and use a fresh element id."
    )
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
