// `overlay` subcommand — the agent-cursor overlay helper process.
//
// The MCP server is a headless async stdio process with no AppKit run loop, so
// the cosmetic cursor lives here, in its own process. This helper runs an
// .accessory NSApplication (no Dock icon, never frontmost) and glides a cursor
// glyph toward target points it reads from a shared FIFO ("move <globalX>
// <globalY>\n", top-left screen coordinates; "ping\n" keep-alives). It is a
// singleton — one cursor serves every concurrently running server process —
// and it never moves the real system cursor.
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
    // Singleton: the flock is held for the helper's lifetime (the kernel
    // releases it on exit or crash). A second helper — another server
    // spawning concurrently — exits and leaves the FIFO to the incumbent.
    let lockFD = open(overlayLockPath(), O_CREAT | O_WRONLY, 0o644)
    if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
        overlayDebug("another overlay helper is already serving; exiting")
        exit(0)
    }
    prepareOverlayFifo()

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = OverlayController()
    app.delegate = controller
    controller.start()
    app.run()
    exit(0)
}

private func prepareOverlayFifo() {
    let path = overlayFifoPath()
    var status = stat()
    if stat(path, &status) == 0, (status.st_mode & S_IFMT) != S_IFIFO {
        unlink(path)  // a stale regular file would silently swallow commands
    }
    mkfifo(path, 0o600)  // EEXIST is fine: the FIFO persists across helpers
}

@MainActor
private final class OverlayController: NSObject, NSApplicationDelegate {
    private var panels: [NSPanel] = []
    private var cursorLayers: [CALayer] = []
    private var displayLink: CADisplayLink?

    /// "Agent working" pill on the primary display, shown while commands are
    /// flowing. Disable with status_chip / COMPUTER_USE_MCP_STATUS_CHIP=0.
    private var chipLayer: CALayer?
    private var chipVisible = false
    private var chipFadeWork: DispatchWorkItem?
    private let chipEnabled = Config.bool("status_chip") != false

    private var visible = false
    private var animating = false
    /// Pending idle fade-out, postponed by any glide or keep-alive ping. The
    /// server pings on every tool call, so the cursor stays up for a whole
    /// multi-step task (clicks, key presses, perception, model thinking in
    /// between) and fades only once the agent has actually gone quiet.
    private var fadeWork: DispatchWorkItem?
    private let idleFadeDelay: TimeInterval = Config.double("cursor_idle_fade") ?? 12
    /// Last command of any kind, for the idle self-exit.
    private var lastCommand = Date()
    /// Cursor position in AppKit global coordinates (bottom-left origin at the
    /// primary screen) — the one space all screen frames share.
    private var currentPoint = CGPoint.zero
    private var startPoint = CGPoint.zero
    private var targetPoint = CGPoint.zero
    private var startTime: CFTimeInterval = 0
    /// Per-glide, scaled with distance: short hops stay snappy, long crossings
    /// stay smooth instead of teleporting.
    private var duration: CFTimeInterval = 0.22

    func start() {
        guard let primary = NSScreen.screens.first else { exit(0) }
        currentPoint = CGPoint(x: primary.frame.midX, y: primary.frame.midY)
        buildPanels()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        readFifo()
        scheduleIdleExitCheck()
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
            layer.bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
            layer.anchorPoint = CGPoint(x: 0.0625, y: 0.9375)  // arrow tip at (2,30)
            layer.opacity = visible ? 1 : 0
            host.layer?.addSublayer(layer)

            if chipEnabled, screen.frame.origin == .zero {
                let chip = makeChipLayer(screenSize: screen.frame.size, scale: screen.backingScaleFactor)
                chip.opacity = chipVisible ? 1 : 0
                host.layer?.addSublayer(chip)
                chipLayer = chip
            }

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
        chipLayer = nil
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

    // MARK: FIFO command loop

    /// Read commands from the shared FIFO on a background thread, marshaling
    /// them to the main actor. The blocking open waits for the first writer;
    /// an empty read means every writer closed (servers exited), so the FIFO
    /// is reopened and the helper waits for the next one.
    private nonisolated func readFifo() {
        DispatchQueue.global(qos: .userInteractive).async {
            let path = overlayFifoPath()
            while true {
                let fd = open(path, O_RDONLY)
                if fd < 0 {
                    Thread.sleep(forTimeInterval: 0.25)
                    continue
                }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                var pending = ""
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    pending += String(data: data, encoding: .utf8) ?? ""
                    while let newline = pending.firstIndex(of: "\n") {
                        let line = String(pending[..<newline])
                        pending = String(pending[pending.index(after: newline)...])
                        Self.handle(command: line)
                    }
                }
            }
        }
    }

    private nonisolated static func handle(command line: String) {
        let parts = line.split(separator: " ")
        if parts.first == "ping" {
            DispatchQueue.main.async {
                (NSApp.delegate as? OverlayController)?.noteActivity()
            }
            return
        }
        guard parts.count == 3, let x = Double(parts[1]), let y = Double(parts[2]) else { return }
        let point = CGPoint(x: x, y: y)
        switch parts.first {
        case "move":
            DispatchQueue.main.async {
                (NSApp.delegate as? OverlayController)?.beginGlide(toGlobalTopLeft: point)
            }
        case "pulse":
            DispatchQueue.main.async {
                (NSApp.delegate as? OverlayController)?.showPulse(atGlobalTopLeft: point)
            }
        default:
            break
        }
    }

    // MARK: lifetime

    /// Without a spawning parent to die with (the FIFO outlives any single
    /// server), the helper reaps itself after a long quiet period instead.
    private func scheduleIdleExitCheck() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastCommand) > overlayIdleExitDelay {
                overlayDebug("idle exit")
                exit(0)
            }
            self.scheduleIdleExitCheck()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    // MARK: animation

    fileprivate func beginGlide(toGlobalTopLeft point: CGPoint) {
        lastCommand = Date()
        showChip()
        targetPoint = appKitPoint(fromGlobalTopLeft: point)
        startPoint = currentPoint
        startTime = CACurrentMediaTime()
        let distance = hypot(targetPoint.x - startPoint.x, targetPoint.y - startPoint.y)
        duration = min(0.32, max(0.12, distance / 2400))
        animating = true
        overlayDebug("beginGlide cg=\(point) appkit=\(targetPoint) from=\(startPoint)")
        fadeWork?.cancel()
        fadeWork = nil
        visible = true
        setOpacity(1, of: cursorLayers, animationDuration: nil)

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
            scheduleIdleFade()
        }
    }

    /// Keep-alive ping from any server: postpone the idle fade (if a fade is
    /// pending) and the idle self-exit. Perception-only work never summons the
    /// cursor, but it does show the status chip — the agent IS working.
    fileprivate func noteActivity() {
        lastCommand = Date()
        showChip()
        guard visible, fadeWork != nil else { return }
        fadeWork?.cancel()
        scheduleIdleFade()
    }

    /// Fade the cursor away after a quiet period so it does not sit on the
    /// last target forever; the next glide restores it instantly.
    private func scheduleIdleFade() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.animating else { return }
            self.visible = false
            self.setOpacity(0, of: self.cursorLayers, animationDuration: 0.4)
            overlayDebug("idle fade")
        }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleFadeDelay, execute: work)
    }

    /// Set opacity on layers, animated over `animationDuration` seconds or
    /// instantly when nil. The single fade helper for cursor and chip.
    private func setOpacity(_ value: Float, of layers: [CALayer], animationDuration: TimeInterval?) {
        CATransaction.begin()
        if let animationDuration {
            CATransaction.setAnimationDuration(animationDuration)
        } else {
            CATransaction.setDisableActions(true)
        }
        for layer in layers { layer.opacity = value }
        CATransaction.commit()
    }

    /// Quartz global top-left → AppKit bottom-left, using the PRIMARY screen
    /// height so it's correct on any display in the unified coordinate plane.
    private func appKitPoint(fromGlobalTopLeft point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    // MARK: click pulse

    /// Expanding ring at the point an action just landed — the visual "the
    /// click happened", distinct from the cursor arriving.
    fileprivate func showPulse(atGlobalTopLeft point: CGPoint) {
        lastCommand = Date()
        showChip()
        let global = appKitPoint(fromGlobalTopLeft: point)
        for panel in panels {
            let local = CGPoint(x: global.x - panel.frame.origin.x, y: global.y - panel.frame.origin.y)
            guard panel.contentView?.bounds.contains(local) == true,
                let host = panel.contentView?.layer
            else { continue }

            let radius: CGFloat = 13
            let ring = CAShapeLayer()
            ring.path = CGPath(
                ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2),
                transform: nil
            )
            ring.fillColor = nil
            ring.strokeColor = NSColor.systemBlue.cgColor
            ring.lineWidth = 3
            ring.contentsScale = panel.backingScaleFactor
            ring.position = local
            host.addSublayer(ring)

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.35
            scale.toValue = 1.8
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.95
            fade.toValue = 0.0
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = 0.45
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            ring.add(group, forKey: "pulse")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                ring.removeFromSuperlayer()
            }
        }
    }

    // MARK: status chip

    /// Show the "Agent working" pill; it fades after the same quiet period as
    /// the cursor. Every command (glide, pulse, keep-alive ping) refreshes it.
    private func showChip() {
        guard chipEnabled, let chipLayer else { return }
        if !chipVisible {
            chipVisible = true
            setOpacity(1, of: [chipLayer], animationDuration: 0.3)
        }
        chipFadeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let chip = self.chipLayer else { return }
            self.chipVisible = false
            self.setOpacity(0, of: [chip], animationDuration: 0.3)
        }
        chipFadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleFadeDelay, execute: work)
    }

    /// Pill with a blue dot and "Agent working", top-right of the primary
    /// display just below the menu bar. Click-through like everything else.
    private func makeChipLayer(screenSize: CGSize, scale: CGFloat) -> CALayer {
        let size = CGSize(width: 138, height: 28)
        let chip = CALayer()
        chip.frame = CGRect(
            x: screenSize.width - size.width - 16,
            y: screenSize.height - size.height - 40,
            width: size.width, height: size.height
        )
        chip.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        chip.cornerRadius = size.height / 2
        chip.borderWidth = 1
        chip.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        let dot = CALayer()
        dot.frame = CGRect(x: 12, y: (size.height - 8) / 2, width: 8, height: 8)
        dot.cornerRadius = 4
        dot.backgroundColor = NSColor.systemBlue.cgColor
        chip.addSublayer(dot)

        let text = CATextLayer()
        text.string = "Agent working"
        text.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        text.fontSize = 12
        text.foregroundColor = NSColor.white.cgColor
        text.alignmentMode = .left
        text.contentsScale = scale
        text.frame = CGRect(x: 28, y: 6.5, width: size.width - 36, height: 16)
        chip.addSublayer(text)
        return chip
    }

    private func easeOutCubic(_ t: Double) -> Double {
        let p = max(0, min(1, t))
        return 1 - pow(1 - p, 3)
    }

    // MARK: glyph

    private func cursorGlyph() -> CGImage? {
        // Rendered at 2x so it stays crisp on Retina displays (each layer's
        // contentsScale maps it back to 32pt).
        let scale: CGFloat = 2
        let image = NSImage(size: NSSize(width: 32 * scale, height: 32 * scale))
        image.lockFocus()
        NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
        // The classic macOS arrow-with-tail silhouette, in blue with a white
        // outline: reads as a real mouse but is clearly the agent's. Tip at (2,30).
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 2.0, y: 30.0))    // tip
        arrow.line(to: NSPoint(x: 2.0, y: 4.5))     // left edge straight down
        arrow.line(to: NSPoint(x: 7.9, y: 9.8))     // notch toward the tail
        arrow.line(to: NSPoint(x: 12.0, y: 0.6))    // tail outer
        arrow.line(to: NSPoint(x: 16.3, y: 2.4))    // tail tip
        arrow.line(to: NSPoint(x: 12.1, y: 11.1))   // tail inner
        arrow.line(to: NSPoint(x: 19.6, y: 11.1))   // right wing
        arrow.close()
        NSColor.systemBlue.setFill()
        arrow.fill()
        NSColor.white.setStroke()
        arrow.lineWidth = 1.7
        arrow.lineJoinStyle = .round
        arrow.stroke()
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
