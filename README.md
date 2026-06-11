# computer-use-mcp

**This is the open, agent-agnostic version of the computer-use capability.** A single
signed Swift binary that exposes macOS computer use as a standard
[MCP](https://modelcontextprotocol.io) server. Point Claude Code, Cursor, Codex, Gemini
CLI, or your own agent at it and the agent can **see and operate the apps on your Mac —
in the background, without hijacking your cursor or stealing focus.**

> **Status:** early development. macOS only. Local use while the Mac is unlocked.

## Why it's different

- **Universal — works on every app.** Accessibility-first for precision, with an
  automatic pixel-coordinate fallback (z-order hit-testing) for apps with poor or absent
  accessibility trees. The agent's own vision provides the grounding — no bundled ML model.
  Web apps included: Chromium/Electron web-content accessibility is enabled on demand,
  and structural wrapper nodes are collapsed so deeply nested page content actually
  reaches the agent.
- **Background-safe.** A layered input ladder (AX action → per-window event → per-PID
  event → last-resort global) delivers actions to the target app without moving the real
  cursor or changing focus. You keep working while the agent works.
- **Agent-agnostic.** Standard MCP over stdio. Any compliant client connects with one line
  of config — no lock-in.
- **Observable.** A smooth self-drawn agent cursor (separate from your real pointer) glides
  to each target so you can watch what the agent does.
- **Multi-session safe.** Each MCP client spawns its own server process; concurrent
  sessions share one agent cursor, serialize screenshots (concurrent ScreenCaptureKit
  callers can wedge macOS's capture daemon), and never collide on element-id generations.
- **Reliable.** Every action returns fresh app state (screenshot + accessibility tree).
  Elements are addressed by re-resolving locators (not stale indices), and destructive
  actions pass a confirmation policy.
- **Production-grade.** One native binary, zero runtime dependencies, frictionless install.

## Tools

**Perceive** `get_app_state` (with `scope_element_id`/`max_elements` for huge windows) ·
`list_apps` · `list_windows` · `read_text` · `wait_for`
**Act** `click` · `type_text` · `press_key` · `scroll` · `drag` · `set_value` ·
`select_text` · `perform_secondary_action` · `click_menu_item`
**System** `open_app` · `open_url` · `manage_window` · `read_clipboard` · `write_clipboard`

Every interaction tool accepts **either** a stable element id **or** raw screenshot
coordinates.

Action results return a reduced-resolution screenshot to keep the agent loop fast.
Pass `include_screenshot: false` for tree-only results, `include_state: false` for a
bare confirmation (fastest), and call `get_app_state` whenever full-resolution pixels
are needed.

## How it works

Every interaction first resolves to an accessibility element and a screen
point, then descends a delivery ladder, stopping at the first tier that works:

1. **Accessibility action** (`AXPress`, etc.) — precise, background, no event posted.
2. **Per-window event** — a `windowNumber`-routed event delivered to the target
   process, so the action lands without activating the app or moving the cursor.
3. **Per-pid event** — delivered to the process when no window id resolves.
4. **Global cursor** — opt-in last resort only (`allow_global_cursor: true`); it
   moves the real pointer, then restores it.

State is re-perceived after every action and returned to the caller, so the
agent always acts on current ground truth. Element ids carry a snapshot
generation, so reusing a stale id fails loudly instead of mis-clicking.

## Requirements

- macOS 14+
- Permissions granted on first run: **Accessibility** and **Screen Recording**
  (Input Monitoring is *not* required). Run `computer-use-mcp doctor --prompt`.

## Usage (MCP client config)

```json
{
  "mcpServers": {
    "computer-use": { "command": "computer-use-mcp", "args": ["serve"] }
  }
}
```

## Safety

The server gates risky actions itself (it does not trust the calling agent).
Destructive/irreversible button clicks (Delete, Erase, Reset, …), typing into
secure password fields, and actions against apps on a confirmation list return
a recoverable `Confirmation required: …` error until the caller retries with
`"confirm": true`.

## Configuration

Every option is settable as an environment variable (`COMPUTER_USE_MCP_<KEY>`) or a
key in `~/.config/computer-use-mcp.json` (env wins):

| Key (file) / variable | Effect |
| --- | --- |
| `cursor` / `COMPUTER_USE_MCP_CURSOR=0` | Hide the animated agent-cursor overlay (on by default; set 0 for headless/CI). |
| `cursor_idle_fade` | Seconds of quiet before the agent cursor fades (default 12). |
| `no_safety` / `COMPUTER_USE_MCP_NO_SAFETY=1` | Disable the safety policy entirely. |
| `confirm_apps` | Apps (name or bundle id) where every action needs `confirm`. |
| `destructive` | Extra destructive label substrings to gate. |
| `ax_timeout` | Per-call accessibility timeout in seconds (default 2). |
| `log` / `COMPUTER_USE_MCP_LOG=1` | Per-tool-call stderr log lines (name, ok/error, duration). |
| `max_actions_per_sec` | Optional global throttle on tool calls (off by default). |

## Distribution notes

The binary needs **Accessibility** and **Screen Recording** permission, and macOS
ties those grants to the *host process* that spawns the server (your terminal or
agent app). A rebuilt binary keeps its grants; a different host needs its own.
For redistribution, codesign with a Developer ID and notarize
(`codesign --sign "Developer ID Application: …" && xcrun notarytool submit …`) so
TCC grants attach to a stable identity.

## Known limitations

- Background delivery uses macOS per-process event posting, which is
  app-dependent: a few apps that require real keyboard focus (e.g. some pro
  audio apps, secure input fields) may ignore background events. Use
  `allow_global_cursor: true` as an explicit fallback.
- Menu key-equivalents (e.g. `cmd+a`) are reliable when the app is the key
  window; some apps ignore them when targeted purely in the background.
- macOS only (the engine is built on Accessibility, ScreenCaptureKit, and
  CoreGraphics). The protocol/tool layer is OS-agnostic.

## Development

```bash
swift build
.build/debug/computer-use-mcp serve                  # run the stdio MCP server
.build/debug/computer-use-mcp call get_app_state '{"app":"Calculator"}'   # drive one tool
.build/debug/computer-use-mcp doctor                 # check permissions
python3 scripts/e2e_demo.py                          # end-to-end demo over stdio
```

## License

MIT — see [LICENSE](LICENSE).
