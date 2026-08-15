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
    @Test func catalogIsTheFocusedSeventeenToolSurface() {
        let expected: Set<String> = [
            "list_apps", "get_app_state", "click", "type_text", "press_key",
            "scroll", "drag", "set_value", "select_text",
            "perform_secondary_action", "open_app", "open_url", "list_windows",
            "manage_window", "read_clipboard", "write_clipboard", "health_report",
        ]
        #expect(Set(toolCatalog.map(\.name)) == expected)
        #expect(toolCatalog.count == expected.count)
    }

    @Test func everyRegisteredToolHasAnnotations() {
        #expect(!toolCatalog.isEmpty)
        for spec in toolCatalog {
            #expect(!spec.annotations.isEmpty, "\(spec.name) is missing MCP tool annotations")
            #expect(spec.tool.annotations == spec.annotations)
        }
    }

    @Test func toolAnnotationsCoverInterestingClassifications() throws {
        let getAppState = try toolSpec("get_app_state").annotations
        #expect(getAppState.readOnlyHint == true)
        #expect(getAppState.destructiveHint == false)
        #expect(getAppState.idempotentHint == true)
        #expect(getAppState.openWorldHint == true)

        let click = try toolSpec("click").annotations
        #expect(click.readOnlyHint == false)
        #expect(click.destructiveHint == true)
        #expect(click.idempotentHint == false)
        #expect(click.openWorldHint == true)

        let setValue = try toolSpec("set_value").annotations
        #expect(setValue.readOnlyHint == false)
        #expect(setValue.idempotentHint == false)

        let openApp = try toolSpec("open_app").annotations
        #expect(openApp.readOnlyHint == false)
        #expect(openApp.destructiveHint == false)
        #expect(openApp.idempotentHint == true)
        #expect(openApp.openWorldHint == true)

        let openURL = try toolSpec("open_url").annotations
        #expect(openURL.readOnlyHint == false)
        #expect(openURL.idempotentHint == false)
        #expect(openURL.openWorldHint == true)

    }

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

    @Test func getAppStateExposesScreenshotOptOut() throws {
        #expect(try schemaType(schemaProperty("include_screenshot", in: "get_app_state")) == "boolean")
    }

    @Test func manageWindowKeepsRequiredContractNarrow() throws {
        #expect(try requiredProperties(for: "manage_window") == ["app", "action"])
    }

    @Test func clickExposesFocusChangeOptInForGlobalCursorEscalation() throws {
        #expect(try schemaType(schemaProperty("allow_global_cursor", in: "click")) == "boolean")
        #expect(try schemaType(schemaProperty("allow_focus_change", in: "click")) == "boolean")
    }

    @Test func pressKeyExposesFocusChangeOptInForGlobalKeyboardEscalation() throws {
        #expect(try schemaType(schemaProperty("allow_global_keyboard", in: "press_key")) == "boolean")
        #expect(try schemaType(schemaProperty("allow_global_cursor", in: "press_key")) == "boolean")
        #expect(try schemaType(schemaProperty("allow_focus_change", in: "press_key")) == "boolean")
    }

    @Test func focusMutatingSystemToolsExposeFocusChangeOptIn() throws {
        #expect(try schemaType(schemaProperty("allow_focus_change", in: "open_url")) == "boolean")
        #expect(try schemaType(schemaProperty("allow_focus_change", in: "manage_window")) == "boolean")
    }
}
