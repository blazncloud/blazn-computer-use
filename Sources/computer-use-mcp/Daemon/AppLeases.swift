// Per-app session leases — daemon-side arbitration so two agent sessions
// don't interleave actions inside the same app (A clicks, B types, both
// tasks scramble). Perception is never blocked; only action tools take a
// lease, the lease expires a few seconds after the holder's last action, and
// it drops immediately when the holder disconnects. Disable with
// no_app_lease / COMPUTER_USE_MCP_NO_APP_LEASE=1.

import Foundation
import MCP

/// Tools that mutate app state and therefore take the app lease.
private let leasedTools: Set<String> = [
    "click", "type_text", "press_key", "scroll", "drag", "set_value",
    "select_text", "perform_secondary_action", "click_menu_item", "manage_window",
]

private let leaseDuration: TimeInterval = Config.double("app_lease_seconds") ?? 10

actor AppLeases {
    static let shared = AppLeases()

    private struct Lease {
        var session: Int32
        var expiry: Date
        var appName: String
    }

    private var leases: [pid_t: Lease] = [:]
    private let enabled = Config.bool("no_app_lease") != true

    /// Returns a denial message when another live session holds the app, and
    /// otherwise records/extends this session's lease. Lease keys are pids,
    /// resolved with the same lookup the tools use; an unresolvable app is
    /// not gated (the tool will produce its own, better error).
    func check(tool: String, arguments: [String: Value], session: Int32) -> String? {
        guard enabled, leasedTools.contains(tool) else { return nil }
        guard case .string(let appName)? = arguments["app"],
            let app = try? resolveApp(appName)
        else { return nil }

        let now = Date()
        if let lease = leases[app.pid], lease.session != session, lease.expiry > now {
            return
                "Another agent session is mid-task in \(app.name) (lease expires in "
                + "\(Int(lease.expiry.timeIntervalSince(now).rounded(.up)))s). Retry shortly, "
                + "or work in a different app to avoid interleaving with it."
        }
        leases[app.pid] = Lease(session: session, expiry: now.addingTimeInterval(leaseDuration), appName: app.name)
        return nil
    }

    func dropLeases(session: Int32) {
        leases = leases.filter { $0.value.session != session }
    }
}
