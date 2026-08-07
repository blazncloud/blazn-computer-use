import Foundation

struct BasicControlsFixtureState: Codable, Equatable {
    static let initial = BasicControlsFixtureState(
        schemaVersion: 1,
        fixture: "basic-controls",
        honestCounter: 0,
        toggleOn: false,
        keystrokeEcho: ""
    )

    let schemaVersion: Int
    let fixture: String
    var honestCounter: Int
    var toggleOn: Bool
    var keystrokeEcho: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case fixture
        case honestCounter = "honest_counter"
        case toggleOn = "toggle_on"
        case keystrokeEcho = "keystroke_echo"
    }
}

struct BasicControlsFixtureStateStore {
    static let pathEnvironmentKey = "COMPUTER_USE_FIXTURE_STATE_PATH"

    let path: URL?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let value = environment[Self.pathEnvironmentKey], !value.isEmpty {
            path = URL(fileURLWithPath: value)
        } else {
            path = nil
        }
    }

    func reset() throws {
        try write(.initial)
    }

    func write(_ state: BasicControlsFixtureState) throws {
        guard let path else { return }

        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(state)
        data.append(0x0A)
        try data.write(to: path, options: .atomic)
    }
}
