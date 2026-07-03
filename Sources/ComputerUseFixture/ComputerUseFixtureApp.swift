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

// Window content-size clamp, documented in docs/fixture-app.md. manage_window
// resize writes are clamped to these bounds. Expressed as a SwiftUI root-view
// frame (below) so SwiftUI itself maintains the window's contentMin/MaxSize —
// a delegate-set constraint gets overridden by SwiftUI's layout pass.
enum WindowClamp {
    static let minWidth: CGFloat = 720
    static let minHeight: CGFloat = 540
    static let maxWidth: CGFloat = 1200
    static let maxHeight: CGFloat = 900
    static let idealWidth: CGFloat = 960
    static let idealHeight: CGFloat = 720
}

@main
struct ComputerUseFixtureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("ComputerUse Fixture") {
            ContentView()
                .frame(
                    minWidth: WindowClamp.minWidth, idealWidth: WindowClamp.idealWidth,
                    maxWidth: WindowClamp.maxWidth,
                    minHeight: WindowClamp.minHeight, idealHeight: WindowClamp.idealHeight,
                    maxHeight: WindowClamp.maxHeight)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Bring the fixture window up without forcibly stealing focus: the
        // truth suite drives focus explicitly, and an unconditional steal
        // could mask a headless-policy focus violation.
        NSApp.activate(ignoringOtherApps: false)
        NSApp.windows.first?.title = "ComputerUse Fixture"
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
