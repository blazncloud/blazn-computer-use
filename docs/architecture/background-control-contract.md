# Background Control Contract

This is the product contract for running `computer-use-mcp` while the user keeps
working in another app. The default promise is strict: tools must not silently
steal foreground focus, move the real cursor, or deliver global keyboard input.

## Modes

| Mode | Meaning | Default behavior |
| --- | --- | --- |
| Background safe | Uses Accessibility attributes/actions or per-process delivery that does not activate the app or move the real cursor. | Allowed by default. |
| Background best effort | Uses background delivery that macOS or the target app may ignore, such as `CGEventPostToPid`. | Allowed by default, but the result must report the delivery tier. It must not auto-escalate. |
| Focus mutating | Brings an app/window forward, uses the global cursor, or sends global session input. | Requires explicit opt-in. |

If a background-best-effort action does not land, the caller must retry
explicitly with the relevant escalation. The server should return actionable
guidance instead of silently switching to a foreground path.

## Tool Requirements

- `get_app_state`, `find`, `read_text`, `list_apps`, `list_windows`, and
  `read_clipboard` are read-only and must not change foreground focus.
- `set_value`, `type_text` with `element_id`, `select_text`, AX button presses,
  and AX secondary actions should stay background safe when the target app
  implements the relevant Accessibility contract.
- `click`, `scroll`, and `drag` use element/coordinate resolution plus targeted
  delivery. Click has a real-cursor escape hatch; global cursor delivery
  requires both `allow_global_cursor` and `allow_focus_change`.
- `press_key` uses per-pid delivery by default. Its global keyboard escape hatch
  also requires `allow_focus_change` because shortcuts can change foreground
  focus even when the target app is already frontmost.
- `open_app` must launch in the background by default. `activate:true` is the
  explicit focus-changing path.
- `open_url` requires `allow_focus_change` because LaunchServices may activate
  the browser or document handler.
- `manage_window raise` requires `allow_focus_change`. Other window actions may
  change visible state and still report telemetry so clients can recover.

## Result Telemetry

Mutating tools attach MCP result metadata under `computer-use-mcp/focus`:

```json
{
  "focus_changed": false,
  "focus_change_allowed": false,
  "cursor_movement_allowed": false,
  "delivery_tier": "tier1-ax-attribute",
  "frontmost_before": {
    "name": "Finder",
    "bundle_identifier": "com.apple.finder",
    "pid": 123
  },
  "frontmost_after": {
    "name": "Finder",
    "bundle_identifier": "com.apple.finder",
    "pid": 123
  }
}
```

Generic MCP clients should treat `focus_changed:true` with
`focus_change_allowed:false` as a regression signal.

## Deterministic Evaluation

Use the repo-owned fixture app for deterministic background-control checks:

```bash
python3 scripts/live_background_eval.py
python3 scripts/live_background_eval.py --live
```

The default command is CI-safe and skips live GUI work. `--live` builds a small
AppKit fixture with stable Accessibility identifiers, keeps Finder frontmost,
mutates the fixture through MCP, and asserts Finder remains frontmost while the
fixture value changes.

TextEdit, Finder, Safari, Electron, and third-party apps remain compatibility
smoke targets, not the deterministic source of truth.
