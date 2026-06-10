// Tool handler entry points. M0 stubs — each milestone replaces these with
// the real implementation (M1 perception, M2 AX actions, M3 input ladder).

import MCP

func listApps(_ args: [String: Value]) async throws -> CallTool.Result {
    try await listAppsImpl(args)
}

func getAppState(_ args: [String: Value]) async throws -> CallTool.Result {
    try await getAppStateImpl(args)
}

func click(_ args: [String: Value]) async throws -> CallTool.Result {
    try await clickImpl(args)
}

func typeText(_ args: [String: Value]) async throws -> CallTool.Result {
    throw ToolError.notImplemented("type_text")
}

func pressKey(_ args: [String: Value]) async throws -> CallTool.Result {
    throw ToolError.notImplemented("press_key")
}

func scroll(_ args: [String: Value]) async throws -> CallTool.Result {
    throw ToolError.notImplemented("scroll")
}

func drag(_ args: [String: Value]) async throws -> CallTool.Result {
    throw ToolError.notImplemented("drag")
}

func setValue(_ args: [String: Value]) async throws -> CallTool.Result {
    throw ToolError.notImplemented("set_value")
}

func selectText(_ args: [String: Value]) async throws -> CallTool.Result {
    throw ToolError.notImplemented("select_text")
}

func performSecondaryAction(_ args: [String: Value]) async throws -> CallTool.Result {
    throw ToolError.notImplemented("perform_secondary_action")
}
