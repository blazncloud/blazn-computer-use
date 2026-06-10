// Resolve a target app by name or bundle identifier, and enumerate
// controllable apps.

import AppKit
import Foundation

struct ResolvedApp {
    let pid: pid_t
    let name: String
    let bundleIdentifier: String

    var axApplication: AXUIElement {
        AXUIElementCreateApplication(pid)
    }
}

func resolveApp(_ identifier: String) throws -> ResolvedApp {
    let running = NSWorkspace.shared.runningApplications
    let query = identifier.lowercased()

    let match = running.first { $0.bundleIdentifier?.lowercased() == query }
        ?? running.first { $0.localizedName?.lowercased() == query }
        ?? running.first {
            $0.activationPolicy == .regular && ($0.localizedName?.lowercased().hasPrefix(query) ?? false)
        }

    guard let app = match else {
        let visible = running
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
            .sorted()
            .joined(separator: ", ")
        throw ToolError.failed(
            "No running app matches \"\(identifier)\". Running apps: \(visible). "
                + "Use list_apps to see what can be controlled or launched."
        )
    }
    return ResolvedApp(
        pid: app.processIdentifier,
        name: app.localizedName ?? identifier,
        bundleIdentifier: app.bundleIdentifier ?? "unknown"
    )
}

func runningAppsDescription() -> String {
    let running = NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular }
        .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

    var lines = ["Running apps (controllable now):"]
    for app in running {
        let name = app.localizedName ?? "?"
        let bundle = app.bundleIdentifier ?? "?"
        let state = app.isHidden ? " hidden" : ""
        lines.append("  \(name) (\(bundle), pid \(app.processIdentifier))\(state)")
    }

    let applications = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
    let installed =
        applications
        .filter { $0.hasSuffix(".app") }
        .map { String($0.dropLast(4)) }
        .sorted()
    if !installed.isEmpty {
        lines.append("")
        lines.append("Installed apps (launchable): \(installed.joined(separator: ", "))")
    }
    return lines.joined(separator: "\n")
}
