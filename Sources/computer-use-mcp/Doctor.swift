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

func runDoctor(prompt: Bool) {
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

    if accessibility && screenRecording {
        print("All permissions granted. Ready to use.")
        return
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
