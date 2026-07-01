import MCP
import Testing

@testable import computer_use_mcp

private func toolSpec(_ name: String) throws -> ToolSpec {
    guard let spec = toolCatalog.first(where: { $0.name == name }) else {
        throw ToolError.failed("Missing tool spec \(name).")
    }
    return spec
}

private func objectValue(_ value: Value) throws -> [String: Value] {
    guard case let .object(object) = value else {
        throw ToolError.failed("Expected object value.")
    }
    return object
}

private func schemaProperty(_ property: String, in toolName: String) throws -> Value {
    let schema = try objectValue(try toolSpec(toolName).inputSchema)
    let properties = try objectValue(schema["properties"] ?? .object([:]))
    guard let value = properties[property] else {
        throw ToolError.failed("\(toolName) schema is missing \(property).")
    }
    return value
}

private func schemaType(_ value: Value) throws -> String {
    let object = try objectValue(value)
    guard let type = object["type"]?.stringValue else {
        throw ToolError.failed("Schema property is missing type.")
    }
    return type
}

private func requiredProperties(for toolName: String) throws -> [String] {
    let schema = try objectValue(try toolSpec(toolName).inputSchema)
    guard case let .array(required)? = schema["required"] else {
        return []
    }
    return required.compactMap(\.stringValue)
}

@Suite struct SchemaTests {
    @Test func secondaryActionAcceptsConfirmArgument() throws {
        #expect(try schemaType(schemaProperty("confirm", in: "perform_secondary_action")) == "boolean")
    }

    @Test func manageWindowAcceptsConfirmArgument() throws {
        #expect(try schemaType(schemaProperty("confirm", in: "manage_window")) == "boolean")
    }

    @Test func systemToolsExposeConfirmArgument() throws {
        #expect(try schemaType(schemaProperty("confirm", in: "open_app")) == "boolean")
        #expect(try schemaType(schemaProperty("confirm", in: "write_clipboard")) == "boolean")
    }

    @Test func manageWindowKeepsRequiredContractNarrow() throws {
        #expect(try requiredProperties(for: "manage_window") == ["app", "action"])
    }

    @Test func clickExposesFocusChangeOptInForGlobalCursorEscalation() throws {
        #expect(try schemaType(schemaProperty("allow_global_cursor", in: "click")) == "boolean")
        #expect(try schemaType(schemaProperty("allow_focus_change", in: "click")) == "boolean")
    }

    @Test func pressKeyExposesFocusChangeOptInForGlobalKeyboardEscalation() throws {
        #expect(try schemaType(schemaProperty("allow_global_cursor", in: "press_key")) == "boolean")
        #expect(try schemaType(schemaProperty("allow_focus_change", in: "press_key")) == "boolean")
    }

    @Test func focusMutatingSystemToolsExposeFocusChangeOptIn() throws {
        #expect(try schemaType(schemaProperty("allow_focus_change", in: "open_url")) == "boolean")
        #expect(try schemaType(schemaProperty("allow_focus_change", in: "manage_window")) == "boolean")
    }
}
