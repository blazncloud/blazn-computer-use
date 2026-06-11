// `doctor` — check (and optionally prompt for) the TCC permissions this tool
// needs: Accessibility (read UI + deliver actions) and Screen Recording
// (screenshots). Input Monitoring is intentionally not required.
//
// Note: TCC attributes a CLI's permissions to its responsible process — when
// spawned from a terminal or an MCP client, the grant may attach to that host
// app. `doctor` reports what the current process actually has at runtime.

import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

func runDoctor(prompt: Bool) async {
    let accessibility: Bool
    if prompt {
        // Literal key for kAXTrustedCheckOptionPrompt; the C global is not
        // concurrency-safe to reference under Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibility = AXIsProcessTrustedWithOptions(options)
    } else {
        accessibility = AXIsProcessTrusted()
    }

    var screenRecording = CGPreflightScreenCaptureAccess()
    if prompt && !screenRecording {
        screenRecording = CGRequestScreenCaptureAccess()
    }

    print("computer-use-mcp doctor")
    print("  Accessibility:    \(accessibility ? "granted" : "NOT GRANTED")")
    print("  Screen Recording: \(screenRecording ? "granted" : "NOT GRANTED")")

    // The screen-capture daemon (replayd) serves every screenshot and can
    // wedge — especially under concurrent captures from multiple server
    // processes. Probe it so a wedged daemon shows up here, not as every
    // screenshot timing out.
    var captureServiceHealthy = true
    if screenRecording {
        do {
            _ = try await withTimeout(seconds: 5, label: "Capture service probe") {
                try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                    .windows.count
            }
            print("  Capture service:  responsive")
        } catch {
            captureServiceHealthy = false
            print("  Capture service:  NOT RESPONDING")
            print(
                """

                The macOS screen-capture service (replayd) is not answering. Run \
                `killall -9 replayd` — launchd restarts it clean — then re-run doctor.
                """
            )
        }
    }

    if accessibility && screenRecording && captureServiceHealthy {
        print("All permissions granted. Ready to use.")
        return
    }
    if accessibility && screenRecording {
        exit(1)
    }

    print(
        """

        To grant, open System Settings → Privacy & Security and enable this binary's \
        host app (your terminal or MCP client) under:
        """
    )
    if !accessibility {
        print("  - Accessibility (required to read app UI and deliver actions)")
    }
    if !screenRecording {
        print("  - Screen Recording (required for screenshots)")
    }
    print("\nRe-run `computer-use-mcp doctor --prompt` to trigger the system permission dialogs.")
    exit(1)
}
