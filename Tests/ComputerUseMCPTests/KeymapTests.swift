import Carbon.HIToolbox
import Testing

@testable import computer_use_mcp

@Suite struct KeymapTests {
    @Test func namedKey() throws {
        let chord = try Keymap.parse("Return")
        #expect(chord.keyCode == CGKeyCode(kVK_Return))
        #expect(chord.flags.isEmpty)
    }

    @Test func modifierChord() throws {
        let chord = try Keymap.parse("cmd+shift+s")
        #expect(chord.flags.contains(.maskCommand))
        #expect(chord.flags.contains(.maskShift))
    }

    @Test func modifierAliases() throws {
        for alias in ["cmd+a", "command+a", "super+a", "meta+a"] {
            let chord = try Keymap.parse(alias)
            #expect(chord.flags.contains(.maskCommand), "\(alias) should map to command")
        }
    }

    @Test func shiftedCharacterGetsShiftFlag() throws {
        // "?" requires shift on a US layout; the flag must be added implicitly.
        let chord = try Keymap.parse("?")
        #expect(chord.flags.contains(.maskShift))
    }

    @Test func unknownModifierThrows() {
        #expect(throws: (any Error).self) { try Keymap.parse("hyper+a") }
    }

    @Test func unknownKeyThrows() {
        #expect(throws: (any Error).self) { try Keymap.parse("cmd+NotAKey") }
    }

    @Test func emptyThrows() {
        #expect(throws: (any Error).self) { try Keymap.parse("") }
    }
}
