# Changelog

All notable changes to `computer-use-mcp` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) once it reaches
1.0.

> **Note:** `v0.3.0` is the only git-tagged release so far. The `v0.1.0` and
> `v0.2.0` sections below are reconstructed from milestone commits to give an
> honest history of how the project reached its current shape.

## [Unreleased]

Verifier-first reliability and large-tree perception, landed this cycle on `main`.

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

### Changed

- Per-element accessibility messaging timeout during tree traversal, so one slow
  element can't stall a whole snapshot.
- `type_text` falls back to synthetic Unicode key events when an AX value is
  unsettable.
- `click_menu_item` opens lazily-populated submenus before reading them.

### Fixed

- Stale-identity false negatives on text-entry elements (their AX labels churn
  with content); locators now retry on structure alone for text-entry roles.

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

[Unreleased]: https://github.com/minghinmatthewlam/computer-use-mcp/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/minghinmatthewlam/computer-use-mcp/releases/tag/v0.3.0
</content>
