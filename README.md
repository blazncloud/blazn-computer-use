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

## Requirements

- macOS 14+
- Permissions granted on first run: **Accessibility** and **Screen Recording**
  (Input Monitoring is *not* required).

## Usage (MCP client config)

```json
{
  "mcpServers": {
    "computer-use": { "command": "computer-use-mcp", "args": ["serve"] }
  }
}
```

## Development

```bash
swift build
.build/debug/computer-use-mcp serve                  # run the stdio MCP server
.build/debug/computer-use-mcp call get_app_state '{"app":"Calculator"}'   # drive one tool
```

## License

MIT — see [LICENSE](LICENSE).
