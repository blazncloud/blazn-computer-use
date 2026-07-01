import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var textField: NSTextField!
    private var statusLabel: NSTextField!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))

        let title = NSTextField(labelWithString: "Background Control Fixture")
        title.identifier = NSUserInterfaceItemIdentifier("fixtureTitle")
        title.frame = NSRect(x: 24, y: 166, width: 360, height: 24)
        content.addSubview(title)

        textField = NSTextField(string: "initial-background-value")
        textField.identifier = NSUserInterfaceItemIdentifier("backgroundSafeTextField")
        textField.frame = NSRect(x: 24, y: 112, width: 420, height: 28)
        textField.isEditable = true
        textField.isSelectable = true
        content.addSubview(textField)

        let button = NSButton(title: "Mark Pressed", target: self, action: #selector(markPressed))
        button.identifier = NSUserInterfaceItemIdentifier("pressableButton")
        button.frame = NSRect(x: 24, y: 66, width: 140, height: 32)
        content.addSubview(button)

        statusLabel = NSTextField(labelWithString: "button-status: idle")
        statusLabel.identifier = NSUserInterfaceItemIdentifier("buttonStatusLabel")
        statusLabel.frame = NSRect(x: 184, y: 72, width: 260, height: 20)
        content.addSubview(statusLabel)

        window = NSWindow(
            contentRect: NSRect(x: 160, y: 160, width: 520, height: 220),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Background Control Fixture"
        window.identifier = NSUserInterfaceItemIdentifier("backgroundControlFixtureWindow")
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
    }

    @objc private func markPressed() {
        statusLabel.stringValue = "button-status: pressed"
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
