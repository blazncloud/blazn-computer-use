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

- `get_app_state`, `list_apps`, `list_windows`, `read_clipboard`, and
  `health_report` are read-only and must not change foreground focus.
- `set_value`, `type_text` with `element_id`, `select_text`, AX button presses,
  and AX secondary actions should stay background safe when the target app
  implements the relevant Accessibility contract.
- `click`, `scroll`, and `drag` use element/coordinate resolution plus targeted
  delivery. Click has a real-cursor escape hatch; global cursor delivery
  requires both `allow_global_cursor` and `allow_focus_change`.
- `COMPUTER_USE_MCP_SKYLIGHT=1` enables a flagged prototype click/key rung that
  posts through private SkyLight `SLEventPostToPid` after per-window delivery is
  unavailable and before public per-pid `CGEventPostToPid`. It is off by
  default, `dlopen`/`dlsym` resolved at runtime, and still subject to the normal
  verifier outcome contract. The SPI may break across macOS versions and may be
  rejected by notarization or App Review, so release builds should treat it as
  experimental.
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
  "ui_changed": true,
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

`ui_changed` reports whether the action visibly changed the target app's tree.
Background event delivery (tiers 2-3) has no macOS success signal, so this is
the honest substitute: when such a delivery produced no visible UI change, the
result text also appends a dropped-event hint naming the explicit escalation
to retry (`allow_global_cursor:true` plus `allow_focus_change:true`). AX-tier
actions fail loudly and get no hint. `type_text` additionally reads the
element's value back after insertion and warns when the typed text is absent
(skipped for secure fields and huge documents).

## Yielding To The Human

Background-safe delivery is not enough when the user is actively working in
the same app. App-scoped mutating tools wait briefly and then return a
recoverable error when the target app is frontmost and real hardware input was
seen within `interference_idle_seconds` (default 1 second), so the agent's
synthetic events never interleave with the user's real ones inside the same
app. Global-cursor and global-keyboard escalations yield on any recent user
activity, regardless of which app is frontmost. Actions on apps the user is
not using are never blocked.

User activity is read from CGEventSource HID system state, which the server's
own synthetic per-pid/per-window events do not update, so the agent cannot
trip its own guard. Disable with `no_interference_yield` or
`interference_idle_seconds:0`.

## Screen Lock And Sleep

The engine holds a prevent-idle-sleep assertion while tool calls are flowing
and releases it after a quiet period, so long background tasks do not die to
idle sleep; the display may still sleep because background delivery does not
need it. Disable with `no_sleep_assertion`. When the screen is actually
locked, mutating tools pause with a recoverable error while read-only
perception stays available — unlocking is deliberately the user's decision.

## Deterministic Evaluation

Use the repo-owned fixture app for deterministic background-control checks:

```bash
python3 scripts/live_background_eval.py
python3 scripts/live_background_eval.py --live
```

The default command is CI-safe and skips live GUI work. `--live` builds a small
AppKit fixture with stable Accessibility identifiers, launches it in the
background, mutates the fixture through MCP, and asserts the frontmost app from
before setup remains frontmost while the fixture value changes. The live eval
extracts element ids once from the initial state and drives every subsequent
action from them, so it also exercises the id-stability contract: ids must
survive the UI changes the eval itself causes.

TextEdit, Finder, Safari, Electron, and third-party apps remain compatibility
smoke targets, not the deterministic source of truth.
