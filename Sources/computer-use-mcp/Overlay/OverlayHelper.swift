// `overlay` subcommand — the agent-cursor overlay helper process.
//
// The MCP server is a headless async stdio process with no AppKit run loop, so
// the cosmetic cursor lives here, in its own process. This helper runs an
// .accessory NSApplication (no Dock icon, never frontmost) and glides a cursor
// glyph toward target points it reads from stdin ("move <globalX> <globalY>\n",
// top-left screen coordinates). It never moves the real system cursor.
//
// One click-through borderless panel per display: with "Displays have separate
// Spaces" (the macOS default) a window is clipped to a single screen, so one
// panel — even sized to the union of all displays — can never draw on the
// others. The cursor position is modeled once in AppKit global coordinates and
// mirrored into every panel; each panel clips to its own screen, so the glyph
// appears on whichever display contains it (including straddling a boundary
// mid-glide).

import AppKit
import QuartzCore

/// Stderr diagnostics, enabled with COMPUTER_USE_MCP_OVERLAY_DEBUG=1. The
/// helper inherits the server's stderr, so these reach the MCP host's logs.
func overlayDebug(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["COMPUTER_USE_MCP_OVERLAY_DEBUG"] == "1" else { return }
    FileHandle.standardError.write(Data("[overlay] \(message())\n".utf8))
}

@MainActor
func runOverlay() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = OverlayController()
    app.delegate = controller
    controller.start()
    app.run()
    exit(0)
}

@MainActor
private final class OverlayController: NSObject, NSApplicationDelegate {
    private var panels: [NSPanel] = []
    private var cursorLayers: [CALayer] = []
    private var displayLink: CADisplayLink?

    private var visible = false
    private var animating = false
    /// Cursor position in AppKit global coordinates (bottom-left origin at the
    /// primary screen) — the one space all screen frames share.
    private var currentPoint = CGPoint.zero
    private var startPoint = CGPoint.zero
    private var targetPoint = CGPoint.zero
    private var startTime: CFTimeInterval = 0
    private let duration: CFTimeInterval = 0.22

    func start() {
        guard let primary = NSScreen.screens.first else { exit(0) }
        currentPoint = CGPoint(x: primary.frame.midX, y: primary.frame.midY)
        buildPanels()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        readStdin()
    }

    // MARK: panels

    private func buildPanels() {
        for screen in NSScreen.screens {
            let panel = NSPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true  // click-through: real input passes through
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

            let host = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            host.wantsLayer = true

            let layer = CALayer()
            layer.contents = cursorGlyph()
            layer.contentsScale = screen.backingScaleFactor
            layer.bounds = CGRect(x: 0, y: 0, width: 40, height: 40)
            layer.anchorPoint = CGPoint(x: 0.18, y: 0.82)  // arrow hotspot ~ tip
            layer.opacity = visible ? 1 : 0
            host.layer?.addSublayer(layer)

            panel.contentView = host
            panel.orderFrontRegardless()
            panels.append(panel)
            cursorLayers.append(layer)
        }
        syncLayers()
    }

    @objc private func screensChanged() {
        displayLink?.invalidate()
        displayLink = nil
        animating = false
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
        cursorLayers.removeAll()
        buildPanels()
    }

    /// Mirror the global cursor position into every panel's local space; each
    /// panel clips to its own screen, so the glyph shows where it belongs.
    private func syncLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, panel) in panels.enumerated() {
            cursorLayers[index].position = CGPoint(
                x: currentPoint.x - panel.frame.origin.x,
                y: currentPoint.y - panel.frame.origin.y
            )
        }
        CATransaction.commit()
    }

    /// Height of the primary display (origin at 0,0), used to flip Quartz
    /// global top-left coordinates into AppKit bottom-left coordinates. This is
    /// NOT NSScreen.main (that follows the key window).
    private var primaryHeight: CGFloat {
        (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first)?.frame.height ?? 0
    }

    // MARK: stdin command loop

    private func readStdin() {
        // The readability handler runs on a background queue and must not touch
        // main-actor state directly; it parses lines and marshals points to main.
        FileHandle.standardInput.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: " ")
                guard parts.first == "move", parts.count == 3,
                    let x = Double(parts[1]), let y = Double(parts[2])
                else { continue }
                let point = CGPoint(x: x, y: y)
                DispatchQueue.main.async {
                    (NSApp.delegate as? OverlayController)?.beginGlide(toGlobalTopLeft: point)
                }
            }
        }
    }

    // MARK: animation

    fileprivate func beginGlide(toGlobalTopLeft point: CGPoint) {
        // Quartz global top-left → AppKit bottom-left, using the PRIMARY screen
        // height so it's correct on any display in the unified coordinate plane.
        targetPoint = CGPoint(x: point.x, y: primaryHeight - point.y)
        startPoint = currentPoint
        startTime = CACurrentMediaTime()
        animating = true
        overlayDebug("beginGlide cg=\(point) appkit=\(targetPoint) from=\(startPoint)")
        if !visible {
            visible = true
            for layer in cursorLayers { layer.opacity = 1 }
        }

        if displayLink == nil, let view = panels.first?.contentView {
            let link = view.displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        displayLink?.isPaused = false
    }

    @objc private func tick() {
        guard animating else { return }
        let elapsed = CACurrentMediaTime() - startTime
        let progress = min(1, elapsed / duration)
        let eased = easeOutCubic(progress)
        currentPoint = CGPoint(
            x: startPoint.x + (targetPoint.x - startPoint.x) * eased,
            y: startPoint.y + (targetPoint.y - startPoint.y) * eased
        )
        syncLayers()

        if progress >= 1 {
            animating = false
            displayLink?.isPaused = true  // stop per-frame wakeups while idle
            overlayDebug("glide done at \(currentPoint)")
        }
    }

    private func easeOutCubic(_ t: Double) -> Double {
        let p = max(0, min(1, t))
        return 1 - pow(1 - p, 3)
    }

    // MARK: glyph

    private func cursorGlyph() -> CGImage? {
        // Rendered at 2x so it stays crisp on Retina displays (each layer's
        // contentsScale maps it back to 40pt).
        let scale: CGFloat = 2
        let image = NSImage(size: NSSize(width: 40 * scale, height: 40 * scale))
        image.lockFocus()
        NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
        // A translucent halo behind a bold arrow, so the agent cursor is
        // unmistakable against any background.
        let halo = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 36, height: 36))
        NSColor.systemBlue.withAlphaComponent(0.22).setFill()
        halo.fill()
        NSColor.systemBlue.withAlphaComponent(0.6).setStroke()
        halo.lineWidth = 1.5
        halo.stroke()

        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 8, y: 34))
        arrow.line(to: NSPoint(x: 8, y: 9))
        arrow.line(to: NSPoint(x: 17, y: 18))
        arrow.line(to: NSPoint(x: 23, y: 18))
        arrow.line(to: NSPoint(x: 8, y: 34))
        arrow.close()
        NSColor.systemBlue.setFill()
        arrow.fill()
        NSColor.white.setStroke()
        arrow.lineWidth = 2
        arrow.stroke()
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
