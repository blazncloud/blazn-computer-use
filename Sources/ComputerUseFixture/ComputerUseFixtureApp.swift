import AppKit
import SwiftUI

// ComputerUseFixture — a deterministic GUI fixture for the computer-use-mcp
// "truth suite". Every interactive control writes its outcome into an
// independently AX-readable readout, so a verifier can observe the *real*
// effect instead of trusting a command's ok:true. Some controls are
// deliberate KNOWN LIARS (they report AX success while mutating nothing) so
// the verifier-first outcome contract can be tested against ground truth
// rather than whatever a real app happens to render. See docs/fixture-app.md
// for the control -> truth-suite scenario map.

@main
struct ComputerUseFixtureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("ComputerUse Fixture") {
            ContentView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Window size clamp, documented in docs/fixture-app.md. manage_window
    // frame writes are expected to be clamped to these bounds:
    //   width  in [WindowClamp.minWidth,  WindowClamp.maxWidth]
    //   height in [WindowClamp.minHeight, WindowClamp.maxHeight]
    enum WindowClamp {
        static let minWidth: CGFloat = 720
        static let minHeight: CGFloat = 540
        static let maxWidth: CGFloat = 1200
        static let maxHeight: CGFloat = 900
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Bring the fixture window up without forcibly stealing focus: the
        // truth suite drives focus explicitly, and an unconditional steal
        // could mask a headless-policy focus violation.
        NSApp.activate(ignoringOtherApps: false)
        applyWindowConstraints()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func applyWindowConstraints() {
        guard let window = NSApp.windows.first else { return }
        window.title = "ComputerUse Fixture"
        window.contentMinSize = NSSize(width: WindowClamp.minWidth, height: WindowClamp.minHeight)
        window.contentMaxSize = NSSize(width: WindowClamp.maxWidth, height: WindowClamp.maxHeight)
        window.setContentSize(NSSize(width: 960, height: 720))
        window.styleMask.insert(.resizable)
    }
}
