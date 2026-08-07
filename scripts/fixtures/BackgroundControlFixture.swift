import AppKit

private struct BackgroundControlFixtureState: Codable, Equatable {
    static let initial = BackgroundControlFixtureState(
        schemaVersion: 1,
        fixture: "background-control",
        textField: "initial-background-value",
        buttonStatus: "idle",
        menuStatus: "idle"
    )

    let schemaVersion: Int
    let fixture: String
    var textField: String
    var buttonStatus: String
    var menuStatus: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case fixture
        case textField = "text_field"
        case buttonStatus = "button_status"
        case menuStatus = "menu_status"
    }
}

private struct BackgroundControlFixtureStateStore {
    static let pathEnvironmentKey = "COMPUTER_USE_FIXTURE_STATE_PATH"

    let path: URL?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        path: URL? = nil
    ) {
        if let path {
            self.path = path
        } else if let value = environment[Self.pathEnvironmentKey], !value.isEmpty {
            self.path = URL(fileURLWithPath: value)
        } else {
            self.path = nil
        }
    }

    func reset() throws {
        try write(.initial)
    }

    func write(_ state: BackgroundControlFixtureState) throws {
        guard let path else { return }

        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(state)
        data.append(0x0A)
        try data.write(to: path, options: .atomic)
    }
}

private final class StateReportingTextField: NSTextField {
    var onValueChange: ((String) -> Void)?

    override var stringValue: String {
        didSet {
            if oldValue != stringValue {
                onValueChange?(stringValue)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    private var window: NSWindow!
    private var textField: StateReportingTextField!
    private var statusLabel: NSTextField!
    private var shortcutLabel: NSTextField!
    private var fixtureState = BackgroundControlFixtureState.initial
    private let stateStore = BackgroundControlFixtureStateStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        persistResetState()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 300))

        let title = NSTextField(labelWithString: "Background Control Fixture")
        title.identifier = NSUserInterfaceItemIdentifier("fixtureTitle")
        title.frame = NSRect(x: 24, y: 246, width: 360, height: 24)
        content.addSubview(title)

        textField = StateReportingTextField(string: fixtureState.textField)
        textField.identifier = NSUserInterfaceItemIdentifier("backgroundSafeTextField")
        textField.frame = NSRect(x: 24, y: 192, width: 450, height: 28)
        textField.isEditable = true
        textField.isSelectable = true
        textField.delegate = self
        textField.onValueChange = { [weak self] value in
            self?.recordTextField(value)
        }
        content.addSubview(textField)

        let button = NSButton(title: "Mark Pressed", target: self, action: #selector(markPressed))
        button.identifier = NSUserInterfaceItemIdentifier("pressableButton")
        button.frame = NSRect(x: 24, y: 146, width: 140, height: 32)
        content.addSubview(button)

        statusLabel = NSTextField(labelWithString: "button-status: idle")
        statusLabel.identifier = NSUserInterfaceItemIdentifier("buttonStatusLabel")
        statusLabel.frame = NSRect(x: 184, y: 152, width: 260, height: 20)
        content.addSubview(statusLabel)

        let menuButton = NSButton(title: "Open Menu", target: self, action: nil)
        menuButton.identifier = NSUserInterfaceItemIdentifier("menuButton")
        menuButton.frame = NSRect(x: 24, y: 100, width: 140, height: 32)
        let menu = NSMenu()
        let menuItem = NSMenuItem(
            title: "Fixture Menu Item",
            action: #selector(markMenu),
            keyEquivalent: ""
        )
        menuItem.target = self
        menu.addItem(menuItem)
        menuButton.menu = menu
        content.addSubview(menuButton)

        shortcutLabel = NSTextField(labelWithString: "shortcut-status: idle")
        shortcutLabel.identifier = NSUserInterfaceItemIdentifier("shortcutStatusLabel")
        shortcutLabel.frame = NSRect(x: 184, y: 106, width: 260, height: 20)
        content.addSubview(shortcutLabel)

        window = NSWindow(
            contentRect: NSRect(x: 160, y: 160, width: 560, height: 300),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Background Control Fixture"
        window.identifier = NSUserInterfaceItemIdentifier("backgroundControlFixtureWindow")
        window.contentView = content
        window.isReleasedWhenClosed = false
        // Join every Space: with "Displays have separate Spaces" the eval
        // otherwise depends on which Space the user happens to be on —
        // windows on inactive Spaces are under-reported by accessibility.
        window.collectionBehavior = [.canJoinAllSpaces]
        window.orderFront(nil)
    }

    @objc private func markPressed() {
        statusLabel.stringValue = "button-status: pressed"
        fixtureState.buttonStatus = "pressed"
        persistState()
    }

    @objc private func markMenu() {
        shortcutLabel.stringValue = "shortcut-status: menu"
        fixtureState.menuStatus = "menu"
        persistState()
    }

    func controlTextDidChange(_ notification: Notification) {
        recordTextField(textField.stringValue)
    }

    private func recordTextField(_ value: String) {
        guard fixtureState.textField != value else { return }
        fixtureState.textField = value
        persistState()
    }

    private func persistResetState() {
        fixtureState = .initial
        do {
            try stateStore.reset()
        } catch {
            fputs("BackgroundControlFixture state reset failed: \(error)\n", stderr)
        }
    }

    private func persistState() {
        do {
            try stateStore.write(fixtureState)
        } catch {
            fputs("BackgroundControlFixture state write failed: \(error)\n", stderr)
        }
    }
}

private func runStateSelfTest() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("background-fixture-state-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let path = root.appendingPathComponent("nested/state.json")
    let store = BackgroundControlFixtureStateStore(environment: [:], path: path)
    try store.reset()

    let initialData = try Data(contentsOf: path)
    let expectedInitial = """
    {"button_status":"idle","fixture":"background-control","menu_status":"idle","schema_version":1,"text_field":"initial-background-value"}

    """
    precondition(String(decoding: initialData, as: UTF8.self) == expectedInitial)

    var changed = BackgroundControlFixtureState.initial
    changed.textField = "checker-safe-value"
    changed.buttonStatus = "pressed"
    changed.menuStatus = "menu"
    try store.write(changed)

    let independentlyRead = try JSONDecoder().decode(
        BackgroundControlFixtureState.self,
        from: Data(contentsOf: path)
    )
    precondition(independentlyRead == changed)
}

if CommandLine.arguments.dropFirst().contains("--state-self-test") {
    do {
        try runStateSelfTest()
        print("BackgroundControlFixture state self-test passed")
    } catch {
        fputs("BackgroundControlFixture state self-test failed: \(error)\n", stderr)
        exit(1)
    }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
