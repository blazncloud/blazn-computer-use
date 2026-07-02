# computer-use-mcp

**This is the open, agent-agnostic version of the computer-use capability.** A single
signed Swift binary that exposes macOS computer use as a standard
[MCP](https://modelcontextprotocol.io) server. Point Claude Code, Cursor, Codex, Gemini
CLI, or your own agent at it and the agent can **see and operate the apps on your Mac —
in the background, without hijacking your cursor or stealing focus.**

> **Status:** early development. macOS only. Local use while the Mac is unlocked
> (the system is kept from idle-sleeping during active sessions; if the screen
> locks, mutating tools pause with a recoverable error until the user unlocks).

## Why it's different

- **Universal — works on every app.** Accessibility-first for precision, with an
  automatic pixel-coordinate fallback (z-order hit-testing) for apps with poor or absent
  accessibility trees. The agent's own vision provides the grounding — no bundled ML model.
  Web apps included: Chromium/Electron web-content accessibility is enabled on demand,
  and structural wrapper nodes are collapsed so deeply nested page content actually
  reaches the agent.
- **Background-safe.** A layered input ladder (AX action → per-window event → per-PID
  event, with explicit global fallback for clicks) delivers actions to the target app
  without moving the real cursor or changing focus by default. You keep working while
  the agent works.
- **Agent-agnostic.** Standard MCP over stdio. Any compliant client connects with one line
  of config — no lock-in.
- **Observable.** A smooth self-drawn agent cursor (separate from your real pointer) glides
  to each target so you can watch what the agent does.
- **Multi-session safe.** Sessions are thin shims over one shared engine daemon
  (spawned on demand, retired on version changes, self-reaping when idle), so any number
  of concurrent agents go through a single process that owns capture, accessibility,
  input, and the cursor — and per-app leases keep two agents from interleaving actions
  inside the same app.
- **Reliable.** Every action returns fresh app state (screenshot + accessibility tree).
  Elements are addressed by re-resolving locators (not stale indices), and destructive
  actions pass a confirmation policy.
- **Production-grade.** One native binary, zero runtime dependencies, frictionless install.

## Tools

**Perceive** `get_app_state` (with `scope_element_id`/`max_elements` for huge windows,
`ocr: true` for apps that draw their own UI) · `find` (search elements by text — the
fast way to locate a control) · `list_apps` · `list_windows` · `read_text` · `wait_for`
**Act** `click` · `type_text` · `press_key` · `scroll` · `drag` · `set_value` ·
`select_text` · `perform_secondary_action` · `click_menu_item` · `batch` (a short
action sequence in one round-trip, stopping at the first failure)
**System** `open_app` · `open_url` · `manage_window` · `read_clipboard` · `write_clipboard`
**Skills** `save_skill` · `run_skill` · `list_skills` · `delete_skill` — teach/replay: an
agent performs a task once and saves it as a named, parameterized skill; element anchors
are frozen into durable locators (role + label + tree path) that re-resolve on every run,
so the skill survives app restarts and replays at engine speed with no model in the loop.
Each replayed step passes the same per-step safety gates as a live action, steps can
assert their effect (`expect`, in `wait_for` terms), and a step that no longer resolves
stops the run with a report of exactly what broke — fix that step, re-save, run again.

Every interaction tool accepts **either** a stable element id **or** raw screenshot
coordinates.

Action results return a reduced-resolution screenshot to keep the agent loop fast, and
skip resending the element tree when the action changed nothing (existing ids stay
valid). When the UI did change, results carry a compact diff of what changed, appeared,
or disappeared — elements that survive a change keep their ids, so everything the agent
holds stays valid. Pass `include_screenshot: false` for tree-only results,
`include_state: false` for a bare confirmation (fastest), and call `get_app_state`
whenever full-resolution pixels are needed.

For the precise production contract across observation, dispatch, coordinate
spaces, foreground/background guarantees, TCC requirements, stale snapshots, and
failure recovery, see [Modality Contract](docs/architecture/modality-contract.md).
For strict background focus/cursor behavior, see
[Background Control Contract](docs/architecture/background-control-contract.md).

## How it works

Each MCP client spawns `serve`, a thin stdio shim; tool calls are forwarded to a
shared engine **daemon** (one per user, spawned on demand over a unix socket) that
owns accessibility, screen capture, input delivery, and the agent cursor. One engine
process means concurrent agent sessions cannot collide on shared system services, and
short per-app leases keep two sessions from interleaving actions inside the same app.
`COMPUTER_USE_MCP_NO_DAEMON=1` runs the engine in-process instead.

Click interactions first resolve to an accessibility element and a screen
point, then descend a delivery ladder, stopping at the first tier that works:

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
  (Input Monitoring is *not* required). Run `computer-use-mcp health_report`
  to inspect current identity/permission state, or
  `computer-use-mcp doctor --prompt` when you intentionally want macOS prompts.

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

Browser pages get their own gate: before acting in a known browser the server
reads the current URL from the accessibility tree and applies the URL policy —
`url_deny` patterns block the action outright (confirm does not override),
`url_confirm` patterns (plus built-in payment-page defaults) require `confirm`
per action. The server also yields to the human: when real hardware input was
seen in the last second and the target app is the one the user is working in
(or the action uses the global cursor), the call returns a recoverable error
instead of interleaving with the user (see `interference_idle_seconds`).

## Configuration

Every option is settable as an environment variable (`COMPUTER_USE_MCP_<KEY>`) or a
key in `~/.config/computer-use-mcp.json` (env wins):

| Key (file) / variable | Effect |
| --- | --- |
| `cursor` / `COMPUTER_USE_MCP_CURSOR=0` | Hide the animated agent-cursor overlay (on by default; set 0 for headless/CI). |
| `cursor_idle_fade` | Seconds of quiet before the agent cursor fades (default 12). |
| `status_chip` / `COMPUTER_USE_MCP_STATUS_CHIP=0` | Hide the "Agent working" pill shown on the primary display during activity (on by default). |
| `no_safety` / `COMPUTER_USE_MCP_NO_SAFETY=1` | Disable the safety policy entirely. |
| `confirm_apps` | Apps (name or bundle id) where every action needs `confirm`. |
| `destructive` | Extra destructive label substrings to gate. |
| `url_deny` | URL substrings where browser actions are blocked outright (`confirm` does not override). |
| `url_confirm` | Extra URL substrings where browser actions need `confirm` (defaults cover payment pages). |
| `ax_timeout` | Per-call accessibility timeout in seconds (default 2). |
| `no_daemon` / `COMPUTER_USE_MCP_NO_DAEMON=1` | Run the engine in-process instead of through the shared daemon. |
| `no_app_lease` | Disable per-app session arbitration. |
| `app_lease_seconds` | How long an app stays leased to a session after its last action (default 10). |
| `no_interference_yield` | Disable yielding to real user input (yield is on by default). |
| `interference_idle_seconds` | Hardware quiet time required before acting in the app the user is working in, or via the global cursor (default 1; 0 disables). |
| `no_sleep_assertion` | Do not hold a prevent-idle-sleep assertion while tool calls are flowing. |
| `log` / `COMPUTER_USE_MCP_LOG=1` | Per-tool-call stderr log lines (name, ok/error, duration). |
| `max_actions_per_sec` | Optional global throttle on tool calls (off by default). |

## Distribution notes

The binary needs **Accessibility** and **Screen Recording** permission, and macOS
ties those grants to the *host process* that spawns the server (your terminal or
agent app). A rebuilt binary keeps its grants; a different host needs its own.
Use `computer-use-mcp health_report --json` to record the current executable,
bundle id (if any), parent process, permission state, and daemon socket/secret
paths without revealing daemon secrets. Add `--probe-capture` when you
intentionally want a bounded ScreenCaptureKit/replayd responsiveness probe. For
redistribution, codesign with a Developer ID and notarize
(`codesign --sign "Developer ID Application: ..." && xcrun notarytool submit ...`)
so TCC grants attach to a stable identity. See
[Permissions and app identity](docs/release/permissions.md) for the first
productionization checklist.

## Known limitations

- Background delivery uses macOS per-process event posting, which is
  app-dependent: a few apps that require real keyboard focus (e.g. some pro
  audio apps, secure input fields) may ignore background events. For clicks,
  use `allow_global_cursor: true` as an explicit fallback.
- Menu key-equivalents (e.g. `cmd+a`) are reliable when the app is the key
  window; some apps ignore them when targeted purely in the background.
- macOS only (the engine is built on Accessibility, ScreenCaptureKit, and
  CoreGraphics). The protocol/tool layer is OS-agnostic.

## Development

```bash
swift build
swift test
.build/debug/computer-use-mcp serve                  # run the stdio MCP server
.build/debug/computer-use-mcp call get_app_state '{"app":"Calculator"}'   # drive one tool
.build/debug/computer-use-mcp health_report --json   # non-mutating diagnostics
.build/debug/computer-use-mcp health_report --probe-capture   # bounded capture-service probe
.build/debug/computer-use-mcp doctor                 # check permissions
python3 scripts/preflight.py                         # CI-safe release preflight
python3 scripts/build_app_bundle.py                  # local .app wrapper build
python3 scripts/deploy_app_bundle.py                 # release build + bundle + install to ~/Applications + daemon handover
python3 scripts/deploy_app_bundle.py --check         # exit 1 if the installed bundle is older than source/build
python3 scripts/preflight.py --use-app-bundle        # non-live checks through the .app executable
python3 scripts/e2e_demo.py                          # safe structured smoke artifact; no GUI mutation
```

Default CI covers the non-mutating path: package build, pure unit tests, and CLI
`version`/`help`/`health_report --json` smoke checks. Live app-control checks are
local-only because they require a logged-in macOS desktop plus
Accessibility/Screen Recording permission and can operate real apps. See
[Testing and Preflight](docs/TESTING.md) for the testing tiers, local command
loop, and release preflight expectations. The architecture-level behavior target
for these tiers is captured in
[Modality Contract](docs/architecture/modality-contract.md).

### Benchmark and smoke tiers

Use deterministic checks for hosted CI and live GUI checks only on a local Mac
or a future self-hosted macOS runner with explicit permissions.

| Tier | What it proves | Safe for hosted CI? | Command |
| --- | --- | --- | --- |
| Deterministic unit tests | Pure Swift behavior such as parsing, safety policy, coordinates, and tree shaping. | Yes | `swift test` |
| Structured dry-run smoke | The benchmark entrypoint, schema, git/macOS metadata collection, and opt-in gate. It does not start the MCP server or open apps. | Yes | `python3 scripts/e2e_demo.py` |
| Release preflight | Build, unit tests, CLI smoke, health report, and dry-run background eval in one JSON report. | Yes | `python3 scripts/preflight.py` |
| Local app-bundle runtime | Produces an ad-hoc signed `.app` wrapper and runs non-live CLI/dry-run checks through `Contents/MacOS/computer-use-mcp`. | No | `python3 scripts/preflight.py --use-app-bundle` |
| Deterministic background eval | The fixture-app path mutates a stable AX text field while preserving the current frontmost app. | No | `python3 scripts/live_background_eval.py --live` |
| Real-app compatibility smoke | Lightweight live matrix for Finder read-only discovery and TextEdit background stdio behavior. | No | `python3 scripts/real_app_smoke.py --live` |
| Live GUI smoke | The real MCP stdio path against TextEdit in the background, including perceive, type, select, and focus-stability checks. Setup launches TextEdit without activation and fails if the current frontmost app changes. | No | `python3 scripts/e2e_demo.py --live` |

The smoke and preflight scripts write JSON by default. The main smoke script can
also write JSONL for trend ingestion:

```bash
python3 scripts/e2e_demo.py --format jsonl --output /tmp/computer-use-mcp-smoke.jsonl
python3 scripts/preflight.py --build-app --output /tmp/computer-use-mcp-preflight.json
python3 scripts/preflight.py --use-app-bundle --output /tmp/computer-use-mcp-bundle-preflight.json
```

Live GUI mutation is opt-in. Use `--live` for local manual runs; the environment
variable is available for automation gates that need an explicit opt-in:

```bash
python3 scripts/e2e_demo.py --live
```

Before running the live tier, build the binary and make sure the spawning
terminal has Accessibility and Screen Recording permissions:

```bash
swift build
.build/debug/computer-use-mcp doctor --prompt
python3 scripts/e2e_demo.py --live
```

Do not add the live tier to hosted CI. It depends on an unlocked macOS desktop,
TCC permissions, Finder/TextEdit behavior, and user-visible app state.
Use `--use-app-bundle` when the preflight should run the non-live CLI and dry-run
checks through the `.app` executable. `--build-app` remains build-only.

## License

MIT — see [LICENSE](LICENSE).
