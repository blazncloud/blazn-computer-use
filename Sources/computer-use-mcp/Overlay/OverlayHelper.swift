// `overlay` subcommand — the agent-cursor overlay helper process.
//
// The MCP server is a headless async stdio process with no AppKit run loop, so
// the cosmetic cursor lives here, in its own process. This helper runs an
// .accessory NSApplication (no Dock icon, never frontmost), shows a
// click-through borderless panel above all apps, and glides a cursor glyph
// toward target points it reads from stdin ("move <globalX> <globalY>\n",
// top-left screen coordinates). It never moves the real system cursor.

import AppKit
import QuartzCore

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
    private var panel: NSPanel!
    private let cursorLayer = CALayer()
    private var displayLink: CADisplayLink?

    private var animating = false
    private var startPoint = CGPoint.zero
    private var targetPoint = CGPoint.zero
    private var startTime: CFTimeInterval = 0
    private let duration: CFTimeInterval = 0.28

    func start() {
        guard let screen = NSScreen.main else { exit(0) }
        panel = NSPanel(
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

        let host = NSView(frame: screen.frame)
        host.wantsLayer = true
        host.layer?.addSublayer(cursorLayer)
        panel.contentView = host

        let glyph = cursorGlyph()
        cursorLayer.contents = glyph
        cursorLayer.bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
        cursorLayer.anchorPoint = CGPoint(x: 0.15, y: 0.85)  // arrow hotspot ~ tip
        cursorLayer.opacity = 0
        cursorLayer.position = CGPoint(x: screen.frame.midX, y: screen.frame.midY)

        panel.orderFrontRegardless()
        readStdin()
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
        guard let screen = NSScreen.main else { return }
        // Global top-left → AppKit bottom-left screen coordinates.
        let target = CGPoint(x: point.x, y: screen.frame.height - point.y)
        startPoint = cursorLayer.presentation()?.position ?? cursorLayer.position
        targetPoint = target
        startTime = CACurrentMediaTime()
        animating = true
        cursorLayer.opacity = 1

        if displayLink == nil {
            let link = panel.contentView!.displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    @objc private func tick() {
        guard animating else { return }
        let elapsed = CACurrentMediaTime() - startTime
        let progress = min(1, elapsed / duration)
        let eased = easeOutCubic(progress)
        let position = CGPoint(
            x: startPoint.x + (targetPoint.x - startPoint.x) * eased,
            y: startPoint.y + (targetPoint.y - startPoint.y) * eased
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.position = position
        CATransaction.commit()

        if progress >= 1 { animating = false }
    }

    private func easeOutCubic(_ t: Double) -> Double {
        let p = max(0, min(1, t))
        return 1 - pow(1 - p, 3)
    }

    // MARK: glyph

    private func cursorGlyph() -> CGImage? {
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size)
        image.lockFocus()
        let context = NSGraphicsContext.current?.cgContext
        // A filled arrow with a subtle ring, in a distinct agent color.
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 3, y: 21))
        arrow.line(to: NSPoint(x: 3, y: 4))
        arrow.line(to: NSPoint(x: 9, y: 10))
        arrow.line(to: NSPoint(x: 13, y: 10))
        arrow.line(to: NSPoint(x: 3, y: 21))
        arrow.close()
        NSColor.systemBlue.setFill()
        arrow.fill()
        NSColor.white.setStroke()
        arrow.lineWidth = 1.5
        arrow.stroke()
        context?.flush()
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
