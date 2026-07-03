# Changelog

All notable changes to `computer-use-mcp` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) once it reaches
1.0.

> **Note:** `v0.3.0` and later are git-tagged releases. The `v0.1.0` and
> `v0.2.0` sections below are reconstructed from milestone commits to give an
> honest history of how the project reached its current shape.

## [Unreleased]

Nothing yet.

## [0.4.0] — 2026-07-03

Verifier-first reliability and large-tree perception. Certified by a live
four-suite battery against the release bundle
([docs/release/battery-report-2026-07-03.md](docs/release/battery-report-2026-07-03.md));
tests grew 184 → 337.

### Added

- **Verified action outcomes.** Every mutating tool now does a read → act →
  re-read of the target and classifies whether the effect actually happened
  (`success` / `unsupported` / `effect_not_verified` / `verifier_ambiguous`),
  surfaced in a `computer-use-mcp/outcome` block in `_meta`, alongside a
  `failure_domain` and a plain-language sentence for non-success verdicts.
  `isError` semantics are unchanged. Design in `docs/outcome-contract.md`.
- **Delivery fallback telemetry.** A `computer-use-mcp/delivery` block in `_meta`
  carries `delivery_tier`, a `fallback_reasons` array explaining why each higher
  input tier was skipped, and `ui_changed`.
- **`skeleton: true` on `get_app_state`.** A shallow overview that recurses a few
  levels and collapses deeper containers to a `children_count` drill target;
  drill in with `scope_element_id`.
- **Dense-collection viewport windowing.** Virtualized lists/tables/outlines/grids
  are windowed to the on-screen slice (preferring the app's own visible-rows
  attributes) instead of a blind first-N prefix; off-window items are summarised
  as a count, and locator identity is preserved. `find` and skill replay opt out.
- **Teach-mode text-entry anchoring** by role + tree path rather than the churning
  content label, so text-field skills survive content changes and app restarts.
- **`run_skill` cold-launch**: launches a closed target app in the background
  before replaying.
- **Multi-strategy AX action chains.** When a plain press can't land, clicks walk
  a verified chain (press → confirm → open → pick → selection relay → child /
  ancestor press); the winning rung is reported as `chain_rung` in `_meta`.
- **Structured error codes.** Failures carry a `[CODE]` prefix and a
  `computer-use-mcp/error` `_meta` block with a machine-readable `code`
  (`ELEMENT_NOT_FOUND`, `APP_NOT_FOUND`, `OFFSCREEN_TARGET`, …) and a one-line
  `recovery` hint.
- **Background-reliable scrolling.** Scroll containers are ranked instead of
  taking the first ancestor, and delivery tries the container's own AX
  mechanisms first — setting the scroll bar's value (the one that actually moves
  an NSScrollView in the background), page actions, reveal-descendant — before
  synthetic wheel events.
- **Window-motion verification.** `manage_window` pre-validates geometry
  (offscreen targets are rejected before any write), settle-polls animated
  frames, applies one corrective re-write, and reports the honest applied frame
  when the app clamps.
- **Visible-range `read_text`** (`visible_only`) and web-area rich text rendered
  to markdown via WebKit text markers.
- **Deep-collection `find` and skill replay**: server-side search and locator
  re-resolution reach rows far past the windowed viewport.
- **`ComputerUseFixture`** truth-suite app (honest/liar/disabled buttons, toggle,
  keystroke echo, 500-row table, web pane) — launches in the background by
  default and backs the release battery. See `docs/fixture-app.md`.

### Changed

- Per-element accessibility messaging timeout during tree traversal, so one slow
  element can't stall a whole snapshot.
- `type_text` falls back to synthetic Unicode key events when an AX value is
  unsettable.
- `click_menu_item` opens lazily-populated submenus before reading them.
- Outcome verification is always on (the `COMPUTER_USE_MCP_VERIFY` flag was
  removed after an A/B measured ~3% median latency overhead).
- Agent-cursor overlay z-order: the cursor shows whenever the target window is
  visible (split view, second display, unfocused) and clips only when the
  frontmost app's window genuinely overlaps the target.
  `COMPUTER_USE_MCP_CURSOR_TOPMOST=1` forces always-on-top.
- `write_clipboard` restores prior clipboard contents when a write fails, and
  `drag` guarantees button release (aborting back to the origin on failure).

### Fixed

- Stale-identity false negatives on text-entry elements (their AX labels churn
  with content); locators now retry on structure alone for text-entry roles.
- Continuation leak that could hang daemon-less (`COMPUTER_USE_MCP_NO_DAEMON=1`)
  calls when a wedged `replayd` never answered a capture handshake; timeouts now
  bound un-cancellable work.
- Agent cursor invisible over visible-but-unfocused targets on fullscreen /
  cross-Space setups (regression from the first z-order fix).

## [0.3.0] — 2026-07 (tagged)

Turns the server from a per-action driver into a system that can **learn a task
once and replay it at engine speed**, and hardens reliability, safety, and
visibility around it. Full notes in
[docs/release/v0.3.0-notes.md](docs/release/v0.3.0-notes.md).

### Added

- **Teach / replay skills.** `save_skill`, `run_skill`, `list_skills`,
  `get_skill`, `delete_skill`, plus `record_skill_start` / `record_skill_stop`
  teach mode (agent-performed or user-demonstrated). Durable role+label+path
  locators re-resolve on each run; self-healing paths, resume via `start_at_step`,
  `read_text` extract steps, per-step safety gates and `expect` assertions, and
  repair reports naming nearest candidates.
- **`batch`** tool: a short action sequence in one round-trip, stopping at the
  first failure.
- **Interference yield, browser URL policy, screen-lock pause, sleep assertion**
  as server-side safety and coexistence gates.
- Per-tool funnel counters surfaced via `health_report`; one-command release
  deploy (`scripts/deploy_app_bundle.py`) with staleness `--check`.
- Inactive-Space screenshot capture; opaque-canvas OCR hint; richer identity for
  unlabeled native controls; click-pulse and all-displays "Agent working" chip.

### Changed

- Element ids are stable across UI changes; actions return compact state diffs and
  keep ids for elements that survive.
- Frontmost app read from the window server (not `NSWorkspace`); running apps
  enumerated freshly; display scale derived from CoreGraphics.
- Daemon retires on binary change (not just version string) for clean handover.

### Fixed

- Chronic CI build failure (daemon wire types marked `Sendable`; strong actor
  reference bound before reader-thread tasks; full build error surfaced in CI).
- Focus given back to the user's app after a cold launch steals it.

## [0.2.0] — reconstructed

Perception, the shared daemon, and the bulk of the tool surface.

### Added

- **Shared engine daemon**: one process serves every agent session over a unix
  socket, with cross-process snapshot/screenshot/overlay coordination — the basis
  for multi-session safety.
- **New tools**: `open_app`, `open_url`, `list_windows`, `manage_window`,
  `click_menu_item`, `read_clipboard`, `write_clipboard`, `wait_for`, and
  server-side `find` element search.
- **Web-app support**: Chromium/Electron web accessibility enabled on demand;
  structural wrapper nodes collapsed so deep page content reaches the agent.
- **OCR fallback** via Vision for apps without accessibility trees.
- Scoped subtree queries and a `max_elements` budget for large-app trees;
  reduced-resolution action screenshots and tree-only / note-only fast paths.

### Changed

- Snapshots serialized through an actor with disk-allocated generations; unchanged
  trees skipped in action results; window enumeration cached between captures.

### Fixed

- Bounded AX calls with a messaging timeout and clearer AX errors; frameless
  elements fail loudly instead of clicking at `(0,0)`; window capture bounded so a
  wedged `replayd` can't hang tools.

## [0.1.0] — reconstructed

First working end-to-end computer-use MCP server.

### Added

- MCP stdio server spine and CLI (`serve`, `call`, `version`, `help`).
- **Perception**: `get_app_state`, `list_apps`, `read_text`.
- **Action tools**: `click` (with stale-id safety), `type_text`, `set_value`,
  `select_text`, `perform_secondary_action`, `press_key`, `scroll`, `drag`.
- **Background-safe input delivery ladder** (AX action → per-window event →
  per-pid event → opt-in global cursor) with an xdotool-style keymap.
- **Observable agent-cursor overlay** as a separate helper process, on by default.
- **Server-side safety policy**: destructive-action and secure-field confirmation
  gates enforced independent of the calling agent.
- Config file + env-var configuration, per-call logging, optional rate limit.

[Unreleased]: https://github.com/minghinmatthewlam/computer-use-mcp/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/minghinmatthewlam/computer-use-mcp/releases/tag/v0.4.0
[0.3.0]: https://github.com/minghinmatthewlam/computer-use-mcp/releases/tag/v0.3.0
</content>
