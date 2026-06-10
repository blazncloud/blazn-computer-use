// The tool catalog: the public, model-facing surface of computer-use-mcp.
//
// Conventions shared by every interaction tool:
// - `app` targets a running app by name or bundle identifier (app-scoped control).
// - Elements are addressed by `element_id` from the latest get_app_state result.
// - Coordinate parameters (`x`, `y`, ...) are pixel coordinates in the most recent
//   screenshot returned for that app, used as the fallback when an element is not
//   exposed in the accessibility tree.
// - Every interaction returns fresh app state (accessibility tree + screenshot) so
//   the agent can verify the effect of its action before acting again.

import MCP

private let appParam = stringParam(
    "Target app, by name (e.g. \"Notes\") or bundle identifier (e.g. \"com.apple.Notes\")."
)

private let elementIDParam = stringParam(
    "Element id from the latest get_app_state result. Prefer this over coordinates."
)

private let allowGlobalCursorParam = boolParam(
    "Escape hatch (default false). When true, uses the real system cursor to deliver "
        + "the action — this MOVES the pointer and may change focus. Only set it if "
        + "background delivery did not land for a stubborn app."
)

private let confirmParam = boolParam(
    "Set true to confirm a potentially destructive or irreversible action (e.g. a "
        + "Delete button, typing into a password field, or an app on the confirmation "
        + "list). Required only when the server flags the action; the error says so."
)

let toolCatalog: [ToolSpec] = [
    ToolSpec(
        name: "list_apps",
        description: """
            List the currently-running apps that can be controlled, plus installed apps \
            for reference. Only running apps can be controlled — an installed app must be \
            opened first. Call this first when the target app is unknown or ambiguous.
            """,
        inputSchema: objectSchema([:]),
        handler: { args in try await listApps(args) }
    ),
    ToolSpec(
        name: "get_app_state",
        description: """
            Get the current state of an app: its accessibility tree (elements with ids, \
            roles, labels, values, and pixel bounding boxes) plus a screenshot of its \
            front window. You MUST call this before interacting with an app, and use the \
            element ids and screenshot coordinates it returns. State changes after every \
            action, so never reuse ids or coordinates from before an action.
            """,
        inputSchema: objectSchema(
            [
                "app": appParam,
                "window_title": stringParam(
                    "Optional window title to target a specific window. Defaults to the app's front window."
                ),
            ],
            required: ["app"]
        ),
        handler: { args in try await getAppState(args) }
    ),
    ToolSpec(
        name: "click",
        description: """
            Click an element by id, or by screenshot pixel coordinates when the target \
            is not in the accessibility tree. Runs in the background: the user's real \
            cursor and focus are not disturbed. Returns fresh app state.
            """,
        inputSchema: objectSchema(
            [
                "app": appParam,
                "element_id": elementIDParam,
                "x": numberParam("X pixel coordinate in the latest screenshot (fallback when no element_id)."),
                "y": numberParam("Y pixel coordinate in the latest screenshot (fallback when no element_id)."),
                "click_count": integerParam("Number of clicks: 1 (default) or 2 for double-click."),
                "mouse_button": enumParam(["left", "right", "middle"], "Mouse button. Defaults to left."),
                "allow_global_cursor": allowGlobalCursorParam,
                "confirm": confirmParam,
            ],
            required: ["app"]
        ),
        handler: { args in try await click(args) }
    ),
    ToolSpec(
        name: "type_text",
        description: """
            Type literal text into an editable element (by id), or into the app's \
            focused field when no element is given. Inserts at the current selection. \
            Returns fresh app state — verify the field's new value in it.
            """,
        inputSchema: objectSchema(
            [
                "app": appParam,
                "element_id": elementIDParam,
                "text": stringParam("Literal text to type."),
                "confirm": confirmParam,
            ],
            required: ["app", "text"]
        ),
        handler: { args in try await typeText(args) }
    ),
    ToolSpec(
        name: "press_key",
        description: """
            Press a key or key combination, using xdotool key syntax: a single key \
            (\"Return\", \"Tab\", \"Escape\", \"Up\", \"F5\", \"a\") or modifiers joined \
            with \"+\" (\"cmd+s\", \"cmd+shift+t\", \"ctrl+a\"). Use for shortcuts and \
            navigation; use type_text for entering text. Returns fresh app state.
            """,
        inputSchema: objectSchema(
            [
                "app": appParam,
                "key": stringParam("Key or combination in xdotool syntax, e.g. \"Return\", \"cmd+n\"."),
                "allow_global_cursor": allowGlobalCursorParam,
                "confirm": confirmParam,
            ],
            required: ["app", "key"]
        ),
        handler: { args in try await pressKey(args) }
    ),
    ToolSpec(
        name: "scroll",
        description: """
            Scroll within a scrollable element (by id) or at screenshot coordinates. \
            Positive delta_y scrolls content up (wheel down). Returns fresh app state.
            """,
        inputSchema: objectSchema(
            [
                "app": appParam,
                "element_id": elementIDParam,
                "x": numberParam("X pixel coordinate in the latest screenshot (fallback when no element_id)."),
                "y": numberParam("Y pixel coordinate in the latest screenshot (fallback when no element_id)."),
                "delta_x": integerParam("Horizontal scroll amount in pixels."),
                "delta_y": integerParam("Vertical scroll amount in pixels."),
                "allow_global_cursor": allowGlobalCursorParam,
                "confirm": confirmParam,
            ],
            required: ["app"]
        ),
        handler: { args in try await scroll(args) }
    ),
    ToolSpec(
        name: "drag",
        description: """
            Drag from one point to another, in screenshot pixel coordinates. Use for \
            sliders, reordering, selection rectangles, and drag-and-drop within an app. \
            Returns fresh app state.
            """,
        inputSchema: objectSchema(
            [
                "app": appParam,
                "from_x": numberParam("Start X pixel coordinate in the latest screenshot."),
                "from_y": numberParam("Start Y pixel coordinate in the latest screenshot."),
                "to_x": numberParam("End X pixel coordinate in the latest screenshot."),
                "to_y": numberParam("End Y pixel coordinate in the latest screenshot."),
                "allow_global_cursor": allowGlobalCursorParam,
                "confirm": confirmParam,
            ],
            required: ["app", "from_x", "from_y", "to_x", "to_y"]
        ),
        handler: { args in try await drag(args) }
    ),
    ToolSpec(
        name: "set_value",
        description: """
            Set the complete value of an element directly (text fields, sliders, \
            checkboxes, pickers). Replaces the current value — faster and more reliable \
            than clicking and typing when the element supports it. Returns fresh app state.
            """,
        inputSchema: objectSchema(
            [
                "app": appParam,
                "element_id": elementIDParam,
                "value": stringParam("New value. For checkboxes use \"true\"/\"false\"; for sliders a number."),
                "confirm": confirmParam,
            ],
            required: ["app", "element_id", "value"]
        ),
        handler: { args in try await setValue(args) }
    ),
    ToolSpec(
        name: "select_text",
        description: """
            Select a range of text inside a text element so it can be replaced, copied, \
            or styled. Provide the exact text to select as it appears in the element's \
            value in the accessibility tree. Returns fresh app state.
            """,
        inputSchema: objectSchema(
            [
                "app": appParam,
                "element_id": elementIDParam,
                "text": stringParam("Exact text to select, as it appears in the element's current value."),
                "occurrence": integerParam("Which occurrence to select when the text appears multiple times (1-based, default 1)."),
            ],
            required: ["app", "element_id", "text"]
        ),
        handler: { args in try await selectText(args) }
    ),
    ToolSpec(
        name: "perform_secondary_action",
        description: """
            Perform an element's secondary action: open its context menu \
            (right-click equivalent) or another accessibility action it exposes, such \
            as AXShowMenu, AXConfirm, AXIncrement, or AXDecrement. Returns fresh app state.
            """,
        inputSchema: objectSchema(
            [
                "app": appParam,
                "element_id": elementIDParam,
                "action": stringParam(
                    "Accessibility action to perform. Defaults to AXShowMenu (context menu)."
                ),
            ],
            required: ["app", "element_id"]
        ),
        handler: { args in try await performSecondaryAction(args) }
    ),
]
