import Foundation

@main
struct BasicControlsFixtureStateTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("basic-fixture-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let path = root.appendingPathComponent("nested/state.json")
        let store = BasicControlsFixtureStateStore(
            environment: [BasicControlsFixtureStateStore.pathEnvironmentKey: path.path]
        )
        try store.reset()

        let initialData = try Data(contentsOf: path)
        let expectedInitial = """
        {"fixture":"basic-controls","honest_counter":0,"keystroke_echo":"","schema_version":1,"toggle_on":false}

        """
        precondition(String(decoding: initialData, as: UTF8.self) == expectedInitial)

        var changed = BasicControlsFixtureState.initial
        changed.honestCounter = 2
        changed.toggleOn = true
        changed.keystrokeEcho = "checker-safe-value"
        try store.write(changed)

        let independentlyRead = try JSONDecoder().decode(
            BasicControlsFixtureState.self,
            from: Data(contentsOf: path)
        )
        precondition(independentlyRead == changed)

        try store.reset()
        let reset = try JSONDecoder().decode(
            BasicControlsFixtureState.self,
            from: Data(contentsOf: path)
        )
        precondition(reset == .initial)

        print("BasicControlsFixture state tests passed")
    }
}
