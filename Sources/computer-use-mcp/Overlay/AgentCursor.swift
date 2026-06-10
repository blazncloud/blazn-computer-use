// Server-side client for the agent-cursor overlay helper process.
//
// On by default; opt out for headless/CI use with COMPUTER_USE_MCP_CURSOR=0.
// When enabled, the server spawns the `overlay` helper once and, before each
// spatial action, tells it to glide to the target and waits the animation
// duration — the animate-then-act choreography. The overlay is purely
// cosmetic; it never moves the real cursor, and a dead/failed helper never
// blocks or fails the action.

import Foundation

actor AgentCursor {
    static let shared = AgentCursor()

    private var process: Process?
    private var stdinPipe: Pipe?
    private let enabled = Config.bool("cursor") != false
    // Awaited before the action fires. Slightly less than the overlay's own
    // animation so the cursor is still arriving as the action lands (natural)
    // while keeping per-action latency low.
    private let glideDuration = Duration.milliseconds(160)

    /// Glide the overlay cursor to a global top-left point, then return so the
    /// caller can deliver the actual action. No-op when disabled.
    func glide(to point: CGPoint) async {
        guard enabled else { return }
        guard ensureRunning() else { return }
        let command = "move \(Int(point.x)) \(Int(point.y))\n"
        // Throwing write: a dead helper surfaces as a Swift error (SIGPIPE is
        // ignored at startup), never an uncatchable ObjC exception. On failure
        // tear down the dead helper so the next glide respawns it cleanly.
        do {
            try stdinPipe?.fileHandleForWriting.write(contentsOf: Data(command.utf8))
        } catch {
            process = nil
            stdinPipe = nil
            return
        }
        try? await Task.sleep(for: glideDuration)
    }

    /// Tell a running helper the agent is still mid-task so the cursor's idle
    /// fade is postponed. Never spawns the helper — activity without movement
    /// (key presses, perception) should not summon a cursor that isn't there.
    func keepAlive() {
        guard enabled, let process, process.isRunning else { return }
        do {
            try stdinPipe?.fileHandleForWriting.write(contentsOf: Data("ping\n".utf8))
        } catch {
            self.process = nil
            stdinPipe = nil
        }
    }

    private func ensureRunning() -> Bool {
        if let process, process.isRunning { return true }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        task.arguments = ["overlay"]
        let input = Pipe()
        task.standardInput = input
        // Let the helper inherit stderr for diagnostics; ignore its stdout.
        task.standardOutput = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return false
        }
        process = task
        stdinPipe = input
        return true
    }
}
