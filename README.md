# computer-use-mcp

**Give any AI agent a Mac it can actually use.** A single signed Swift binary that
exposes macOS computer use as a standard [MCP](https://modelcontextprotocol.io) server.
Point Claude Code, Cursor, Codex, Gemini CLI, or your own agent at it and the agent can
**see and operate any Mac app — in the background, without hijacking your cursor or
stealing focus.**

This is the open, agent-agnostic version of the computer-use capability that ships
locked inside tools like OpenAI's Codex app. MIT licensed.

> **Status:** early development. macOS only. Local use while the Mac is unlocked.

## Why it's different

- **Universal — works on every app.** Accessibility-first for precision, with an
  automatic pixel-coordinate fallback (z-order hit-testing) for apps with poor or absent
  accessibility trees. The agent's own vision provides the grounding — no bundled ML model.
- **Background-safe.** A layered input ladder (AX action → per-window event → per-PID
  event → last-resort global) delivers actions to the target app without moving the real
  cursor or changing focus. You keep working while the agent works.
- **Agent-agnostic.** Standard MCP over stdio. Any compliant client connects with one line
  of config — no lock-in.
- **Observable.** A smooth self-drawn agent cursor (separate from your real pointer) glides
  to each target so you can watch what the agent does.
- **Reliable.** Every action returns fresh app state (screenshot + accessibility tree).
  Elements are addressed by re-resolving locators (not stale indices), and destructive
  actions pass a confirmation policy.
- **Production-grade.** One native binary, zero runtime dependencies, frictionless install.

## Tools

`get_app_state` · `list_apps` · `click` · `type_text` · `press_key` · `scroll` · `drag` ·
`set_value` · `select_text` · `perform_secondary_action`

Every interaction tool accepts **either** a stable element id **or** raw screenshot
coordinates.

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

## Configuration (environment variables)

| Variable | Effect |
| --- | --- |
| `COMPUTER_USE_MCP_CURSOR=1` | Show the animated agent-cursor overlay (off by default). |
| `COMPUTER_USE_MCP_NO_SAFETY=1` | Disable the safety policy entirely. |
| `COMPUTER_USE_MCP_CONFIRM_APPS=a,b` | Apps (name or bundle id) where every action needs `confirm`. |
| `COMPUTER_USE_MCP_DESTRUCTIVE=pat,pat` | Extra destructive label substrings to gate. |

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
