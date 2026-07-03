import Testing

@testable import computer_use_mcp

@Suite struct UnicodeTypingTests {
    @Test func asciiSplitsToOneUnitPerCharacter() {
        let chunks = unicodeTypingChunks("abc")
        #expect(chunks == [[0x61], [0x62], [0x63]])
    }

    @Test func chunkCountMatchesGraphemeCount() {
        #expect(unicodeTypingChunks("hello world").count == 11)
    }

    @Test func emptyStringYieldsNoChunks() {
        #expect(unicodeTypingChunks("").isEmpty)
    }

    @Test func astralEmojiStaysOneChunkOfItsSurrogatePair() {
        // U+1F600 is a surrogate pair in UTF-16; it must ride one key event
        // whole, never split across two events mid-scalar.
        let chunks = unicodeTypingChunks("😀")
        #expect(chunks.count == 1)
        #expect(chunks[0] == [0xD83D, 0xDE00])
    }

    @Test func combiningSequenceStaysOneChunk() {
        // "é" as e + combining acute is a single grapheme cluster (two units).
        let chunks = unicodeTypingChunks("e\u{0301}")
        #expect(chunks.count == 1)
        #expect(chunks[0] == [0x65, 0x0301])
    }

    @Test func flagEmojiStaysOneChunk() {
        // Regional-indicator pair (🇯🇵) is one grapheme, four UTF-16 units.
        let chunks = unicodeTypingChunks("🇯🇵")
        #expect(chunks.count == 1)
        #expect(chunks[0].count == 4)
    }

    @Test func chunksReassembleToOriginalText() {
        let text = "aé😀 z🇯🇵!"
        let reassembled = unicodeTypingChunks(text)
            .map { String(utf16CodeUnits: $0, count: $0.count) }
            .joined()
        #expect(reassembled == text)
    }
}
