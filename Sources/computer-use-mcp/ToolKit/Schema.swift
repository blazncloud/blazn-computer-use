// Small helpers for building JSON Schema fragments as MCP `Value` trees.

import MCP

func objectSchema(_ properties: [String: Value], required: [String] = []) -> Value {
    var schema: [String: Value] = [
        "type": .string("object"),
        "properties": .object(properties),
        "additionalProperties": .bool(false),
    ]
    if !required.isEmpty {
        schema["required"] = .array(required.map { .string($0) })
    }
    return .object(schema)
}

func stringParam(_ description: String) -> Value {
    .object(["type": .string("string"), "description": .string(description)])
}

func numberParam(_ description: String) -> Value {
    .object(["type": .string("number"), "description": .string(description)])
}

func integerParam(_ description: String) -> Value {
    .object(["type": .string("integer"), "description": .string(description)])
}

func boolParam(_ description: String) -> Value {
    .object(["type": .string("boolean"), "description": .string(description)])
}

func enumParam(_ values: [String], _ description: String) -> Value {
    .object([
        "type": .string("string"),
        "enum": .array(values.map { .string($0) }),
        "description": .string(description),
    ])
}
