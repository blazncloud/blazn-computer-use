import Testing

@testable import computer_use_mcp

@Suite struct ClipboardGuardTests {
    @Test func committedWriteLeavesClipboardAlone() {
        #expect(clipboardRestoreValue(committed: true, previous: "old") == nil)
    }

    @Test func failedWriteRestoresPriorContents() {
        #expect(clipboardRestoreValue(committed: false, previous: "old") == "old")
    }

    @Test func failedWriteWithNoPriorContentsRestoresNothing() {
        #expect(clipboardRestoreValue(committed: false, previous: nil) == nil)
    }
}
