// Tool handler entry points. M0 stubs — each milestone replaces these with
// the real implementation (M1 perception, M2 AX actions, M3 input ladder).

import MCP

func listApps(_ args: [String: Value]) async throws -> CallTool.Result {
    try await listAppsImpl(args)
}

func getAppState(_ args: [String: Value]) async throws -> CallTool.Result {
    try await getAppStateImpl(args)
}

func find(_ args: [String: Value]) async throws -> CallTool.Result {
    try await findImpl(args)
}

func click(_ args: [String: Value]) async throws -> CallTool.Result {
    try await clickImpl(args)
}

func typeText(_ args: [String: Value]) async throws -> CallTool.Result {
    try await typeTextImpl(args)
}

func pressKey(_ args: [String: Value]) async throws -> CallTool.Result {
    try await pressKeyImpl(args)
}

func scroll(_ args: [String: Value]) async throws -> CallTool.Result {
    try await scrollImpl(args)
}

func drag(_ args: [String: Value]) async throws -> CallTool.Result {
    try await dragImpl(args)
}

func setValue(_ args: [String: Value]) async throws -> CallTool.Result {
    try await setValueImpl(args)
}

func selectText(_ args: [String: Value]) async throws -> CallTool.Result {
    try await selectTextImpl(args)
}

func performSecondaryAction(_ args: [String: Value]) async throws -> CallTool.Result {
    try await performSecondaryActionImpl(args)
}

func openApp(_ args: [String: Value]) async throws -> CallTool.Result {
    try await openAppImpl(args)
}

func openURL(_ args: [String: Value]) async throws -> CallTool.Result {
    try await openURLImpl(args)
}

func listWindows(_ args: [String: Value]) async throws -> CallTool.Result {
    try await listWindowsImpl(args)
}

func manageWindow(_ args: [String: Value]) async throws -> CallTool.Result {
    try await manageWindowImpl(args)
}

func clickMenuItem(_ args: [String: Value]) async throws -> CallTool.Result {
    try await clickMenuItemImpl(args)
}

func readClipboard(_ args: [String: Value]) async throws -> CallTool.Result {
    try await readClipboardImpl(args)
}

func writeClipboard(_ args: [String: Value]) async throws -> CallTool.Result {
    try await writeClipboardImpl(args)
}

func waitFor(_ args: [String: Value]) async throws -> CallTool.Result {
    try await waitForImpl(args)
}

func readText(_ args: [String: Value]) async throws -> CallTool.Result {
    try await readTextImpl(args)
}
