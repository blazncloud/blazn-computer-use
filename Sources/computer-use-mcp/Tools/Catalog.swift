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
        + "background delivery did not land for a stubborn app. Requires allow_focus_change:true."
)

private let allowFocusChangeParam = boolParam(
    "Default false. Set true only when you explicitly allow this call to change "
        + "the user's foreground app/focus. The result metadata reports whether focus changed."
)

private let allowGlobalKeyboardParam = boolParam(
    "Escape hatch (default false). When true, allows global keyboard delivery only "
        + "when the target app is already foreground. Use only if per-app delivery "
        + "did not land for a stubborn app. Requires allow_focus_change:true because "
        + "global shortcuts can change foreground focus."
)

private let confirmParam = boolParam(
    "Set true to confirm a potentially destructive or irreversible action (e.g. a "
        + "Delete button, typing into a password field, or an app on the confirmation "
        + "list). Required only when the server flags the action; the error says so."
)

private let includeScreenshotParam = boolParam(
    "Default true. Set false to omit the screenshot from the returned state — faster "
        + "and cheaper. The accessibility tree is always returned; call get_app_state "
        + "when you need full-resolution pixels again."
)

private let includeStateParam = boolParam(
    "Default true. Set false to return only a confirmation note — no tree, no screenshot. "
        + "The fastest mode for chained actions; call get_app_state when you need state again."
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
                "scope_element_id": stringParam(
                    "Optional container element id: return the tree for just that subtree, with the "
                        + "full element budget. Use when the whole-window tree was truncated."
                ),
                "max_elements": integerParam(
                    "Maximum elements in the returned tree (default 500, cap 5000). Raise for large windows."
                ),
                "ocr": boolParam(
                    "Default false. Set true to also OCR the screenshot and return recognized text "
                        + "with pixel boxes — the fallback for apps whose accessibility tree is "
                        + "missing or sparse (custom-drawn UIs, games, remote desktops)."
                ),
            ],
            required: ["app"]
        ),
        handler: { args in try await getAppState(args) }
    ),
    ToolSpec(
        name: "find",
        description: """
            Search a window's accessibility tree for elements matching a text query — \
            the fast way to locate a control without reading the whole tree. Searches \
            deeper than get_app_state returns (up to 5000 elements) and matches labels, \
            values, and roles, case-insensitively. Returned element ids are fresh and \
            directly usable in action tools.
            """,
        inputSchema: objectSchema(
            [
                "app": appParam,
                "query": stringParam("Substring to search for in element labels, values, and roles."),
                "role": stringParam("Optional exact role filter, e.g. \"AXButton\"."),
                "max_results": integerParam("Maximum matches to return (default 20, cap 100)."),
                "window_title": stringParam(
                    "Optional window title to target a specific window. Defaults to the app's front window."
                ),
            ],
            required: ["app", "query"]
        ),
        handler: { args in try await find(args) }
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
                "click_count": integerParam(
                    "Number of clicks: 1 (default) or \(ArgumentBounds.maxClickCount) for double-click."
                ),
                "mouse_button": enumParam(["left", "right", "middle"], "Mouse button. Defaults to left."),
                "allow_global_cursor": allowGlobalCursorParam,
                "allow_focus_change": allowFocusChangeParam,
                "include_screenshot": includeScreenshotParam,
                "include_state": includeStateParam,
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
                "text": stringParam("Literal text to type. Maximum \(ArgumentBounds.maxTypeTextCharacters) characters."),
                "include_screenshot": includeScreenshotParam,
                "include_state": includeStateParam,
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
                "allow_global_cursor": allowGlobalKeyboardParam,
                "allow_focus_change": allowFocusChangeParam,
                "include_screenshot": includeScreenshotParam,
                "include_state": includeStateParam,
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
                "direction": enumParam(
                    ["up", "down", "left", "right"],
                    "Semantic scroll direction (sized from the element; combine with pages). "
                        + "Alternative to raw deltas."
                ),
                "pages": numberParam(
                    "How many element-heights/widths to scroll with direction (default 1, max \(Int(ArgumentBounds.maxScrollPages)))."
                ),
                "delta_x": integerParam(
                    "Horizontal scroll amount in pixels (alternative to direction, max +/-\(ArgumentBounds.maxScrollDelta))."
                ),
                "delta_y": integerParam(
                    "Vertical scroll amount in pixels (alternative to direction, max +/-\(ArgumentBounds.maxScrollDelta))."
                ),
                "include_screenshot": includeScreenshotParam,
                "include_state": includeStateParam,
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
                "include_screenshot": includeScreenshotParam,
                "include_state": includeStateParam,
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
                "value": stringParam(
                    "New value. For checkboxes use \"true\"/\"false\"; for sliders a number. "
                        + "Maximum \(ArgumentBounds.maxSetValueCharacters) characters."
                ),
                "include_screenshot": includeScreenshotParam,
                "include_state": includeStateParam,
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
                "position": enumParam(
                    ["select", "before", "after"],
                    "select the text (default), or collapse the cursor before/after it for inserting with type_text."
                ),
                "include_screenshot": includeScreenshotParam,
                "include_state": includeStateParam,
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
                "include_screenshot": includeScreenshotParam,
                "include_state": includeStateParam,
                "confirm": confirmParam,
            ],
            required: ["app", "element_id"]
        ),
        handler: { args in try await performSecondaryAction(args) }
    ),
    ToolSpec(
        name: "open_app",
        description: """
            Open (launch) an app so it can be controlled, without stealing focus unless \
            activate is true. Accepts an app name, bundle id, or .app path. If the app is \
            already running this is a no-op (plus optional activation). Returns fresh app state.
            """,
        inputSchema: objectSchema(
            [
                "app": stringParam("App name (e.g. \"Notes\"), bundle id, or full .app path."),
                "activate": boolParam(
                    "Default false. When true, brings the app to the foreground — this changes the user's focus."
                ),
                "confirm": confirmParam,
            ],
            required: ["app"]
        ),
        handler: { args in try await openApp(args) }
    ),
    ToolSpec(
        name: "open_url",
        description: """
            Open a URL or file path with its default handler (browser, document app, …). \
            Local files and non-http(s) schemes require confirm:true because they can \
            launch apps or trigger arbitrary handlers. Requires allow_focus_change:true \
            because LaunchServices may activate the handling app.
            """,
        inputSchema: objectSchema(
            [
                "url": stringParam("URL (https://…, file://…, app schemes) or an existing file path."),
                "allow_focus_change": allowFocusChangeParam,
                "confirm": confirmParam,
            ],
            required: ["url"]
        ),
        handler: { args in try await openURL(args) }
    ),
    ToolSpec(
        name: "list_windows",
        description: """
            List every window of an app — including dialogs, floating panels, and \
            minimized windows — with titles, frames, and which one is focused. Use when an \
            app has multiple windows, a save dialog appeared, or get_app_state shows the \
            wrong window.
            """,
        inputSchema: objectSchema(["app": appParam], required: ["app"]),
        handler: { args in try await listWindows(args) }
    ),
    ToolSpec(
        name: "manage_window",
        description: """
            Manage an app window: raise (bring to front within the app), minimize, \
            unminimize, move, resize, fullscreen, exit_fullscreen, or close. Targets the \
            front window unless window_title is given. Move/resize use global screen \
            points (not screenshot pixels). Geometry must be finite and within \
            server-enforced bounds. close requires confirm:true.
            """,
        inputSchema: objectSchema(
            [
                "app": appParam,
                "action": enumParam(
                    ["raise", "minimize", "unminimize", "move", "resize", "fullscreen", "exit_fullscreen", "close"],
                    "What to do with the window."
                ),
                "window_title": stringParam("Optional window title; defaults to the front window."),
                "x": numberParam(
                    "Target X for move (global screen points, top-left origin, max +/-"
                        + "\(Int(ArgumentBounds.maxWindowCoordinateMagnitude)))."
                ),
                "y": numberParam(
                    "Target Y for move (global screen points, max +/-"
                        + "\(Int(ArgumentBounds.maxWindowCoordinateMagnitude)))."
                ),
                "width": numberParam(
                    "Target width for resize (points, "
                        + "\(Int(ArgumentBounds.minWindowDimension))..."
                        + "\(Int(ArgumentBounds.maxWindowDimension)))."
                ),
                "height": numberParam(
                    "Target height for resize (points, "
                        + "\(Int(ArgumentBounds.minWindowDimension))..."
                        + "\(Int(ArgumentBounds.maxWindowDimension)))."
                ),
                "allow_focus_change": allowFocusChangeParam,
                "confirm": confirmParam,
            ],
            required: ["app", "action"]
        ),
        handler: { args in try await manageWindow(args) }
    ),
    ToolSpec(
        name: "click_menu_item",
        description: """
            Select an item from the app's menu bar by path, e.g. \"File > Export As…\" or \
            \"Format > Font > Bold\". Works in the background without opening the menu \
            visually. Use for commands that have no on-screen button.
            """,
        inputSchema: objectSchema(
            [
                "app": appParam,
                "path": stringParam("Menu path with \" > \" separators, e.g. \"File > Save\"."),
                "include_screenshot": includeScreenshotParam,
                "include_state": includeStateParam,
                "confirm": confirmParam,
            ],
            required: ["app", "path"]
        ),
        handler: { args in try await clickMenuItem(args) }
    ),
    ToolSpec(
        name: "read_clipboard",
        description: "Read the current text content of the system clipboard.",
        inputSchema: objectSchema([:]),
        handler: { args in try await readClipboard(args) }
    ),
    ToolSpec(
        name: "write_clipboard",
        description: """
            Replace the system clipboard with the given text, e.g. to paste a long value \
            with press_key cmd+v. Note: this overwrites whatever the user had copied.
            """,
        inputSchema: objectSchema(
            [
                "text": stringParam(
                    "Text to place on the clipboard. Maximum \(ArgumentBounds.maxClipboardCharacters) characters."
                ),
                "confirm": confirmParam,
            ],
            required: ["text"]
        ),
        handler: { args in try await writeClipboard(args) }
    ),
    ToolSpec(
        name: "wait_for",
        description: """
            Wait until an element appears (or disappears, with gone:true) in an app's \
            window, then return fresh state. Use after actions that trigger loading, \
            instead of polling get_app_state manually.
            """,
        inputSchema: objectSchema(
            [
                "app": appParam,
                "label": stringParam("Match elements whose title/description contains this text (case-insensitive)."),
                "role": stringParam("Match elements with this exact AX role, e.g. AXButton."),
                "value_contains": stringParam("Match elements whose value contains this text."),
                "gone": boolParam("Default false. When true, wait for the match to disappear instead."),
                "timeout_seconds": numberParam("How long to wait (default 10, max 60)."),
                "window_title": stringParam("Optional window title; defaults to the front window."),
            ],
            required: ["app"]
        ),
        handler: { args in try await waitFor(args) }
    ),
    ToolSpec(
        name: "read_text",
        description: """
            Read the full text value of an element — the tree truncates long values. \
            Supports offset/length chunking for very large documents.
            """,
        inputSchema: objectSchema(
            [
                "app": appParam,
                "element_id": elementIDParam,
                "offset": integerParam("Character offset to start from (default 0)."),
                "length": integerParam(
                    "Maximum characters to return (default \(ArgumentBounds.maxReadTextCharacters), "
                        + "max \(ArgumentBounds.maxReadTextCharacters))."
                ),
            ],
            required: ["app", "element_id"]
        ),
        handler: { args in try await readText(args) }
    ),
]
