// `doctor` and `health_report` — check the TCC permissions this tool needs:
// Accessibility (read UI + deliver actions) and Screen Recording
// (screenshots). Input Monitoring is intentionally not required.
//
// Note: TCC attributes a CLI's permissions to its responsible process. These
// diagnostics report what the current process actually has at runtime, plus
// caller/app-bundle context to make that attribution visible.

import Foundation

func runDoctor(prompt: Bool) async {
    let report = await makeHealthReport(prompt: prompt, probeCaptureService: true)
    printDoctorText(report)

    if report.ready {
        print("All permissions granted. Ready to use.")
        return
    }
    if report.permissions.accessibility.granted && report.permissions.screenRecording.granted {
        print("\n\(report.recommendedNextAction)")
        exit(1)
    }

    print(
        """

        To grant, open System Settings -> Privacy & Security and enable this binary's \
        host app (your terminal or MCP client) under:
        """
    )
    if !report.permissions.accessibility.granted {
        print("  - Accessibility (required to read app UI and deliver actions)")
    }
    if !report.permissions.screenRecording.granted {
        print("  - Screen Recording (required for screenshots)")
    }
    print("\nRe-run `computer-use-mcp doctor --prompt` to trigger the system permission dialogs.")
    exit(1)
}

func runHealthReport(json: Bool, probeCaptureService: Bool) async {
    let report = await makeHealthReport(prompt: false, probeCaptureService: probeCaptureService)
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report), let text = String(data: data, encoding: .utf8) {
            print(text)
        } else {
            FileHandle.standardError.write(Data("Could not encode health report.\n".utf8))
            exit(1)
        }
        return
    }

    printHealthReportText(report)
}

private func printDoctorText(_ report: HealthReport) {
    print("computer-use-mcp doctor")
    print("  Accessibility:    \(report.permissions.accessibility.displayStatus)")
    print("  Screen Recording: \(report.permissions.screenRecording.displayStatus)")
    print("  Capture service:  \(report.captureService.displayStatus)")
}

private func printHealthReportText(_ report: HealthReport) {
    print("computer-use-mcp health_report")
    print("  Version:           \(report.version)")
    print("  Executable:        \(report.executablePath)")
    print("  Bundle ID:         \(report.bundleIdentifier ?? "none")")
    print("  Current process:   \(report.process.current.summary)")
    print("  Parent process:    \(report.process.parent?.summary ?? "unknown")")
    print("  Accessibility:     \(report.permissions.accessibility.displayStatus)")
    print("  Screen Recording:  \(report.permissions.screenRecording.displayStatus)")
    print("  Capture service:   \(report.captureService.displayStatus)")
    print("  Daemon runtime:    \(report.daemon.runtimeDirectory)")
    print("  Daemon socket:     \(report.daemon.socketPath) (\(report.daemon.socketExists ? "present" : "absent"))")
    print("  Daemon secret:     \(report.daemon.secretPath) (\(report.daemon.secretExists ? "present" : "absent"))")
    print("  TCC attribution:   \(report.tccAttribution)")
    print("  Next action:       \(report.recommendedNextAction)")
}
