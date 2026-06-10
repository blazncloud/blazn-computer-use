// Window screenshots via ScreenCaptureKit. Captures a single app window
// without bringing it to the foreground.

import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct WindowCapture {
    let pngData: Data
    let pixelWidth: Int
    let pixelHeight: Int
}

/// Longest screenshot side sent to the model, in pixels. Keeps payloads and
/// token costs sane while remaining readable.
private let maxScreenshotDimension = 1600.0

func captureWindow(pid: pid_t, title: String?, frame: CGRect) async throws -> WindowCapture {
    guard CGPreflightScreenCaptureAccess() else {
        throw ToolError.failed(
            """
            Screen Recording permission is not granted, so screenshots are unavailable. \
            Run `computer-use-mcp doctor --prompt` and enable the host app under \
            System Settings → Privacy & Security → Screen Recording.
            """
        )
    }

    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    let appWindows = content.windows.filter {
        $0.owningApplication?.processID == pid && $0.windowLayer == 0
    }
    guard !appWindows.isEmpty else {
        throw ToolError.failed("No capturable window found for pid \(pid).")
    }

    let window: SCWindow
    if let title, let match = appWindows.first(where: { $0.title == title }) {
        window = match
    } else {
        // Fall back to the window whose frame best matches the AX window frame.
        window = appWindows.min { lhs, rhs in
            distance(lhs.frame, frame) < distance(rhs.frame, frame)
        }!
    }

    let filter = SCContentFilter(desktopIndependentWindow: window)

    // Capture at 2x for crisp text (pointPixelScale can misreport 1 in
    // headless CLI contexts), downscaled to the payload cap if needed.
    let scale = max(CGFloat(filter.pointPixelScale), 2)
    let nativeWidth = filter.contentRect.width * scale
    let nativeHeight = filter.contentRect.height * scale
    let downscale = min(1.0, maxScreenshotDimension / max(nativeWidth, nativeHeight))

    let configuration = SCStreamConfiguration()
    configuration.width = Int(nativeWidth * downscale)
    configuration.height = Int(nativeHeight * downscale)
    configuration.scalesToFit = true
    configuration.showsCursor = false
    configuration.captureResolution = .best
    let image = try await SCScreenshotManager.captureImage(
        contentFilter: filter, configuration: configuration
    )

    guard let pngData = encodePNG(image) else {
        throw ToolError.failed("Failed to encode the window screenshot.")
    }
    return WindowCapture(pngData: pngData, pixelWidth: image.width, pixelHeight: image.height)
}

private func distance(_ a: CGRect, _ b: CGRect) -> Double {
    abs(a.midX - b.midX) + abs(a.midY - b.midY) + abs(a.width - b.width) + abs(a.height - b.height)
}

private func encodePNG(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard
        let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        )
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}
