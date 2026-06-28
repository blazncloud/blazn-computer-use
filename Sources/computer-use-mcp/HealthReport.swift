import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import ScreenCaptureKit

func makeHealthReport(prompt: Bool, probeCaptureService: Bool) async -> HealthReport {
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

    let permissions = PermissionDiagnostics(
        accessibility: PermissionStatus(
            granted: accessibility,
            status: accessibility ? "granted" : "not_granted",
            requiredFor: "reading app UI and delivering Accessibility actions"
        ),
        screenRecording: PermissionStatus(
            granted: screenRecording,
            status: screenRecording ? "granted" : "not_granted",
            requiredFor: "screenshots and ScreenCaptureKit window capture"
        )
    )

    let captureService = await captureServiceDiagnostic(
        screenRecordingGranted: screenRecording,
        probe: probeCaptureService
    )
    let process = ProcessDiagnostics.current()
    let daemon = daemonDiagnostics()
    let action = recommendedNextAction(
        accessibility: accessibility,
        screenRecording: screenRecording,
        captureServiceStatus: captureService.status
    )

    return HealthReport(
        reportVersion: 1,
        version: version,
        executablePath: executablePath(),
        bundleIdentifier: Bundle.main.bundleIdentifier,
        process: process,
        permissions: permissions,
        captureService: captureService,
        daemon: daemon,
        tccAttribution: tccAttributionNote(parent: process.parent),
        recommendedNextAction: action
    )
}

private func captureServiceDiagnostic(screenRecordingGranted: Bool, probe: Bool) async -> CaptureServiceDiagnostic {
    guard screenRecordingGranted else {
        return CaptureServiceDiagnostic(
            status: .skipped,
            detail: "Screen Recording is not granted, so the capture service probe was not run."
        )
    }
    guard probe else {
        return CaptureServiceDiagnostic(status: .skipped, detail: "Capture service probe was disabled.")
    }

    // The screen-capture daemon (replayd) serves every screenshot and can
    // wedge. Probe it so a wedged daemon shows up here, not as every screenshot
    // timing out. This enumerates shareable content but does not capture pixels.
    do {
        _ = try await withCrossProcessLock(named: "screencapture") {
            try await withTimeout(seconds: 5, label: "Capture service probe") {
                try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                    .windows.count
            }
        }
        return CaptureServiceDiagnostic(status: .responsive, detail: "ScreenCaptureKit shareable content responded.")
    } catch {
        return CaptureServiceDiagnostic(
            status: .notResponding,
            detail: "ScreenCaptureKit did not respond: \(error)"
        )
    }
}

func recommendedNextAction(
    accessibility: Bool,
    screenRecording: Bool,
    captureServiceStatus: CaptureServiceStatus
) -> String {
    if !accessibility {
        return "Grant Accessibility to the responsible host app, then rerun `computer-use-mcp health_report`."
    }
    if !screenRecording {
        return "Grant Screen Recording to the responsible host app, then rerun `computer-use-mcp health_report`."
    }
    if captureServiceStatus == .notResponding {
        return "Restart the macOS screen-capture service with `killall -9 replayd`, then rerun `computer-use-mcp health_report`."
    }
    if captureServiceStatus == .skipped {
        return "Permissions are available. Run `computer-use-mcp health_report --probe-capture` when you need to check capture-service responsiveness."
    }
    return "Permissions and capture probe are healthy. For production distribution, launch from a signed, notarized app bundle so TCC grants attach to a stable identity."
}

private func daemonDiagnostics() -> DaemonDiagnostics {
    let paths = daemonRuntimePaths(createRuntimeDirectory: false)
    let manager = FileManager.default
    return DaemonDiagnostics(
        runtimeDirectory: paths.directory,
        runtimeDirectoryExists: manager.fileExists(atPath: paths.directory),
        socketPath: paths.socket,
        socketExists: manager.fileExists(atPath: paths.socket),
        lockPath: paths.lock,
        lockExists: manager.fileExists(atPath: paths.lock),
        logPath: paths.log,
        logExists: manager.fileExists(atPath: paths.log),
        secretPath: paths.secret,
        secretExists: manager.fileExists(atPath: paths.secret),
        secretContentsReported: false
    )
}

private func executablePath() -> String {
    if let executableURL = Bundle.main.executableURL {
        return executableURL.standardizedFileURL.path
    }
    return URL(fileURLWithPath: CommandLine.arguments.first ?? "computer-use-mcp").standardizedFileURL.path
}

private func tccAttributionNote(parent: ProcessIdentity?) -> String {
    let parentName = parent?.name ?? "the process that launched this binary"
    return "macOS may attribute CLI TCC grants to \(parentName) or another responsible host app; a signed app bundle gives production installs a stable identity."
}

struct HealthReport: Codable {
    let reportVersion: Int
    let version: String
    let executablePath: String
    let bundleIdentifier: String?
    let process: ProcessDiagnostics
    let permissions: PermissionDiagnostics
    let captureService: CaptureServiceDiagnostic
    let daemon: DaemonDiagnostics
    let tccAttribution: String
    let recommendedNextAction: String

    var ready: Bool {
        permissions.accessibility.granted
            && permissions.screenRecording.granted
            && captureService.status != .notResponding
    }
}

struct ProcessDiagnostics: Codable {
    let current: ProcessIdentity
    let parent: ProcessIdentity?

    static func current() -> ProcessDiagnostics {
        let pid = ProcessInfo.processInfo.processIdentifier
        let currentApp = NSRunningApplication.current
        let currentExecutablePath = executablePath()
        let current = ProcessIdentity(
            pid: pid,
            name: ProcessInfo.processInfo.processName,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? currentApp.bundleIdentifier,
            bundlePath: Bundle.main.bundleURL.standardizedFileURL.path,
            executablePath: currentExecutablePath
        )
        let parent = ProcessIdentity(pid: getppid())
        return ProcessDiagnostics(current: current, parent: parent)
    }
}

struct ProcessIdentity: Codable {
    let pid: Int32
    let name: String?
    let bundleIdentifier: String?
    let bundlePath: String?
    let executablePath: String?

    init(pid: Int32, name: String?, bundleIdentifier: String?, bundlePath: String?, executablePath: String?) {
        self.pid = pid
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.executablePath = executablePath
    }

    init?(pid: Int32) {
        guard pid > 0 else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        let path = app?.executableURL?.standardizedFileURL.path ?? processExecutablePath(pid: pid)
        self.pid = pid
        self.name = app?.localizedName ?? path.map { URL(fileURLWithPath: $0).lastPathComponent }
        self.bundleIdentifier = app?.bundleIdentifier
        self.bundlePath = app?.bundleURL?.standardizedFileURL.path
        self.executablePath = path
    }

    var summary: String {
        var parts = ["pid \(pid)"]
        if let name {
            parts.append(name)
        }
        if let bundleIdentifier {
            parts.append(bundleIdentifier)
        } else {
            parts.append("no bundle id")
        }
        return parts.joined(separator: ", ")
    }
}

private func processExecutablePath(pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: 4096)
    let result = buffer.withUnsafeMutableBufferPointer { pointer in
        proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
    }
    guard result > 0 else { return nil }
    let bytes = buffer.prefix(Int(result)).map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

struct PermissionDiagnostics: Codable {
    let accessibility: PermissionStatus
    let screenRecording: PermissionStatus
}

struct PermissionStatus: Codable {
    let granted: Bool
    let status: String
    let requiredFor: String

    var displayStatus: String {
        granted ? "granted" : "NOT GRANTED"
    }
}

enum CaptureServiceStatus: String, Codable {
    case responsive
    case notResponding = "not_responding"
    case skipped
}

struct CaptureServiceDiagnostic: Codable {
    let status: CaptureServiceStatus
    let detail: String

    var displayStatus: String {
        switch status {
        case .responsive:
            return "responsive"
        case .notResponding:
            return "NOT RESPONDING"
        case .skipped:
            return "skipped"
        }
    }
}

struct DaemonDiagnostics: Codable {
    let runtimeDirectory: String
    let runtimeDirectoryExists: Bool
    let socketPath: String
    let socketExists: Bool
    let lockPath: String
    let lockExists: Bool
    let logPath: String
    let logExists: Bool
    let secretPath: String
    let secretExists: Bool
    let secretContentsReported: Bool
}
