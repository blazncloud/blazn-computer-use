# Modality Contract

This document is the production contract for how `computer-use-mcp` observes
and operates a local macOS desktop. It is meant to be specific enough for tool
docs, tests, evals, and future driver comparisons.

For foreground focus and cursor guarantees, see
[Background Control Contract](background-control-contract.md).

The default mode is a local, unlocked Mac with a visible desktop. The server is
not a sandboxed browser, VM stream, or remote framebuffer driver: it can combine
macOS Accessibility, ScreenCaptureKit, CoreGraphics event posting, AppKit
window metadata, and a shared local daemon in one trusted user session.

## Contract Matrix

| Surface | Default contract | Fallback or escape hatch | Primary failure language |
| --- | --- | --- | --- |
| Observation | `get_app_state` returns one target window's Accessibility tree plus a ScreenCaptureKit screenshot. Element boxes and coordinate inputs are in the returned screenshot's pixel space. | `find` searches a deeper AX tree without a new screenshot. `read_text` returns long AX values. `ocr:true` adds Vision OCR boxes when AX is sparse. | Missing Accessibility permission, missing Screen Recording permission, no running app, no queryable window, no capturable on-screen window, ScreenCaptureKit timeout. |
| Capture scope | Window capture is desktop-independent for the target app window and does not foreground the app. It requires the window to be on screen and capturable by ScreenCaptureKit. | `include_screenshot:false` keeps tree-only action results. `include_state:false` returns only a confirmation note. | "Screenshot unavailable" may be returned with a usable AX tree; capture timeout includes `replayd` recovery guidance. |
| Action target | Interaction tools target a running app by name or bundle id. A window title may select a specific window for perception and some window operations. | `open_app` can launch an app without activation by default. `list_windows` disambiguates windows. | Unknown or non-running app, no matching window title, app quit or crashed after resolution. |
| Element identity | `element_id` values are generation-tagged per pid, for example `e12@s3`, but validity is membership in the current in-memory snapshot. A surviving `AXUIElement` handle carries its id forward. Before acting, the daemon proves that exact handle is live, still has the captured semantic identity, and remains attached to the captured process/window. | Call `get_app_state` or use the state/diff returned after an action. Use `scope_element_id` when the tree was truncated. | A recreated, detached, missing, semantically changed, or ambiguously attached element produces a clear retry-with-fresh-state error. |
| Post-action state | Mutating tools return reduced-detail fresh state. An unchanged tree is not resent (existing ids remain valid); a changed tree returns a compact diff of changed, appeared, and disappeared elements, with surviving elements keeping their ids. | `include_state:false` or `include_screenshot:false` reduce the result further. `get_app_state` always returns the full tree and full-detail pixels. | Diffs fall back to the full tree when more than half the elements changed. Scoped snapshots are never diffed against. |
| Batched actions | `batch` runs up to 10 app-scoped actions (plus `wait_for`) against one app in one round-trip. Every step passes the normal dispatch funnel and server-side gates. All steps are validated before any runs. | Intermediate steps skip state for speed; the final step returns fresh state, which composes with diffs. | Execution stops at the first failure and reports which steps already ran. `batch` cannot nest itself or `run_skill`. |
| Saved skills | `save_skill` freezes an element anchor as role plus stable label; `run_skill` requires exactly one live match and replays through the same per-step gates with no model in the loop. `list_skills` and `delete_skill` manage the store. | `{{param}}` placeholders substitute into string arguments; steps may assert their effect with `expect` (in `wait_for` terms). | Unlabeled or duplicate role+label controls cannot be replayed safely and fail instead of guessing. A missing anchor or failed expectation stops the run with the step and reason. `delete_skill` requires `confirm`. |
| Coordinate identity | Raw `x` and `y` are screenshot pixels from the latest snapshot for that app. They are bounds-checked, converted to global screen points, then optionally hit-tested back to an AX element for labels and safety gates. | Use coordinates when the target is absent from AX, custom drawn, or found by OCR. | Coordinates outside the latest screenshot are rejected; coordinates require a prior state capture. |
| Dispatch ladder | Left click prefers AX actions first, then window-routed process events, then per-pid CoreGraphics events. AX-backed text/value/menu/window operations use Accessibility directly. Scroll and drag use targeted event delivery. | `allow_global_cursor:true` enables the real-cursor/session-tap path for clicks. `press_key` can use global keyboard delivery only when the target app is already foreground. | Background event posting is app-dependent and has no reliable success signal, so global escalation is explicit rather than automatic. |
| Foreground guarantee | Default pointer and key delivery does not activate the target app, move the real cursor, or steal user focus. `open_app` also avoids activation by default. | `open_app activate:true`, `manage_window raise`, or explicit global cursor/keyboard modes can affect focus or visible ordering. | Global keyboard delivery fails if requested while the target app is not foreground. Apps that require real focus may ignore background events. |
| Session ownership | `serve` and `call` are thin clients over one per-user daemon. The daemon owns capture, AX, input, overlay cursor, app leases, and metrics persistence. | All tool calls cross the authenticated daemon boundary. | Any daemon failure returns a structured `DAEMON_UNAVAILABLE` error; no tool runs in-process. |
| Multi-session guarantee | Per-app leases serialize action tools against the same resolved pid for a short window after each action. Perception is never blocked. | Work in another app, retry when the lease expires, or explicitly disable app leases for local experiments. | Lease denial names the app and remaining wait time. It prevents interleaved actions, not every possible app-level race. |
| Safety policy | Destructive labels, confirmation-listed apps, secure password fields, risky URL schemes, and destructive window actions require `confirm:true`. Browser actions additionally pass a server-side URL policy, mutating tools yield to live user input in the target app, and mutating tools pause while the screen is locked. | The caller may retry with `confirm:true` after reading the server's reason, retry after the user goes idle, or wait for unlock. `url_deny` matches are hard blocks that `confirm` does not override. | Recoverable "Confirmation required", interference-yield, and lock-pause errors are part of the tool contract, not crashes. |

## Observation Surfaces

`get_app_state` is the canonical state surface. It:

- requires Accessibility permission before reading app structure;
- targets the front window by default, or a matching `window_title`;
- captures the target window with ScreenCaptureKit when screenshots are
  requested;
- enables Chromium/Electron web accessibility flags when needed;
- emits element ids, roles, labels, values, actions, and boxes in screenshot
  pixels;
- keeps the current live snapshot in the daemon so later calls can resolve ids
  across `serve` and `call` clients while that daemon remains alive.

Action tools return fresh state by default. Reduced screenshots keep the loop
cheap after actions; explicit `get_app_state` returns full-detail pixels. If an
action leaves the tree unchanged, the result says existing ids remain valid
instead of resending an identical tree. If the tree did change, the result
carries a compact diff — changed (`~`), appeared (`+`), and disappeared (`-`)
elements — instead of a full re-send. Diffs fall back to the full tree when
more than half the elements changed; `get_app_state` always returns the full
tree, and scoped snapshots are never diffed against.

`find` is a search surface, not a capture surface. It walks up to 5000 AX
elements and persists fresh ids, but it keeps coordinates in the last screenshot
scale because it does not capture a new screenshot.

`ocr:true` is a fallback for custom-drawn or sparse AX UIs. OCR boxes are still
reported in screenshot pixels and should normally be used with coordinate
actions.

## Element Identity Across UI Changes

Element ids remain generation-tagged (`e12@s3`), but id validity is membership
in a current in-memory snapshot. During capture, Core Foundation equality and
hashing match the same live `AXUIElement` handle to its earlier id. Screenshot
scale does not participate in that identity. Before an action, the daemon reads
the handle's live role, compares its captured semantic facts, and proves that it
still belongs to the captured process and window. A recreated or detached
control fails stale and tells the caller to fetch fresh state; the runtime does
not search for a similar replacement or act on a structural neighbor.

## Coordinate Spaces

The repo uses three coordinate spaces, and tools must name which one they
accept or return:

| Space | Used by | Origin and units |
| --- | --- | --- |
| Screenshot pixels | `get_app_state` boxes, OCR boxes, `click`/`scroll` coordinates, `drag` coordinates | Top-left of the latest target-window screenshot, in pixels. |
| Global screen points | AX window frames, AX element frames, internal delivery, `manage_window move` | macOS global display space, top-left origin, in points. |
| Window-local points | Window-routed synthetic events | Internal bridge for `windowNumber` delivery, bottom-left AppKit window coordinates. |

Coordinate actions require a prior snapshot because the snapshot carries the
window origin, screenshot scale, and window pixel bounds. The server rejects
coordinates outside the latest screenshot rather than clipping or guessing.

## Dispatch Modes

Dispatch is intentionally AX-first and event-last:

1. **AX action or attribute**: `AXPress`, `AXShowMenu`, value setting, text
   selection, menu selection, and window attributes. This is precise,
   background-capable, and posts no input event.
2. **Per-window event**: when the target AX window can be mapped to a
   `CGWindowID`, the server bridges an `NSEvent` with that `windowNumber` and
   posts it to the target pid.
3. **Per-pid event**: if no window id is available, the server posts a
   CoreGraphics event to the target pid.
4. **Global session tap**: explicit escape hatch only. Clicks require
   `allow_global_cursor:true`; keyboard delivery additionally requires the
   target app to already be foreground. Current scroll and drag delivery stays
   on targeted event posting.

The server does not automatically escalate from per-pid delivery to the global
session tap because macOS does not provide a dependable "event landed" signal.
Instead the result reports what was observable: focus telemetry carries a
`ui_changed` flag, and a tier-2/3 background-event delivery that produced no
visible UI change appends a dropped-event hint naming the explicit
global-cursor/focus-change retry. AX-tier actions fail loudly and get no hint.
The caller inspects the returned state and chooses whether to retry with an
escape hatch.

## Batched Actions

`batch` runs up to 10 app-scoped actions (plus `wait_for`) against one app in
a single round-trip. Every step goes through the normal dispatch funnel, so
safety confirmation, interference yield, and the URL policy apply per step.
All steps are validated before any runs; execution stops at the first failure
and reports which steps already ran — an invalid element id is the built-in
brake when the UI does something unexpected. Intermediate steps skip state for
speed; the final step returns fresh state, which composes with state diffs
into a few lines for the whole sequence. One app per batch keeps lease
arbitration coherent, and `batch` cannot nest itself.

## Skills: Save And Replay

`save_skill`, `run_skill`, `list_skills`, and `delete_skill` form a
teach/replay surface. An agent performs a task once and saves it as a named,
parameterized skill; `element_id` anchors are frozen as role plus stable label
at save time, and every run requires one unique role+label match in the live
tree, so skills can survive app restarts without inheriting the runtime's live
AX handles. `{{param}}`
placeholders substitute into any string argument, and steps may assert their
effect with `expect` (in `wait_for` terms).

Replay dispatches each step through the normal funnel, so per-step safety
confirmation, interference yield, and the URL policy all apply, and no model
runs between steps. `run_skill` is app-scoped for leases and gates like any
mutating action. A step that cannot resolve or whose expectation fails stops
the run with a report naming the step and reason — the repair loop is one
`save_skill` away. Skills are JSON files under Application Support; names are
validated, steps are limited to the batchable tool set (never `batch` or
`run_skill`), and `delete_skill` requires `confirm`.

## App And Window Targeting

Tool calls address running apps by exact bundle id, exact localized app name,
or prefix match among regular apps. Installed-but-not-running apps are not
controllable until opened.

Window targeting defaults to the focused window, then main window, then the
first AX window. `window_title` matches exact title first, then substring. If a
requested window disappears after an action, state capture falls back to the
front window and reports that fallback in the result.

The driver can raise, move, resize, minimize, unminimize, enter fullscreen,
exit fullscreen, and close windows through AX window attributes/actions. These
window-management coordinates are global screen points, not screenshot pixels.

## Foreground And Background Guarantees

Default operation is background-safe on supported apps:

- target apps are not activated for normal perception or action;
- the real cursor is not moved for normal pointer delivery;
- key events post to the target pid unless the caller explicitly asks for
  global keyboard delivery;
- `open_app` does not activate the launched app unless `activate:true`.

This is a best-effort macOS guarantee, not an absolute app guarantee. Apps that
require real keyboard focus, secure input, unusual event loops, remote desktop
surfaces, games, and some pro apps may ignore background delivery. The contract
in that case is: return state, let the caller observe no effect, and require an
explicit foreground/global fallback where one exists instead of silently taking
over the user session.

## Server-Side Gates

Beyond confirmation gating, mutating dispatch passes server-side gates the
calling agent cannot bypass:

- **Interference yield.** When real hardware input was seen within
  `interference_idle_seconds` (default 1) and the target app is the one the
  user is working in — or the action uses the global cursor or keyboard — the
  call returns a recoverable yield error instead of interleaving synthetic
  events with the user's real ones. User activity is read from CGEventSource
  HID system state, which the server's own synthetic per-pid/per-window events
  do not update, so the agent cannot trip its own guard. Actions on apps the
  user is not using are never blocked. Disable with `no_interference_yield` or
  `interference_idle_seconds:0`. See
  [Background Control Contract](background-control-contract.md) for the
  human-side framing.
- **Browser URL policy.** Before delivering an app-scoped mutating action to a
  known browser, the server reads the current page URL from the accessibility
  tree and applies policy: `url_deny` substrings block the action outright
  (`confirm` does not override), and `url_confirm` substrings plus built-in
  payment-page defaults require `confirm` per action. An unreadable URL fails
  closed only when the user configured explicit patterns. `open_url` applies
  the same patterns to its URL argument.
- **Screen lock and sleep.** The engine holds a prevent-idle-sleep assertion
  while tool calls are flowing and releases it after a quiet period; the
  display may still sleep because background delivery does not need it.
  Disable with `no_sleep_assertion`. When the screen is actually locked,
  mutating tools return a recoverable pause error while read-only perception
  stays available. Unlocking is the user's decision — there is no auto-unlock.

## Permissions And Local Trust

The required permissions are:

- Accessibility: required for AX tree reads, AX actions, AX attributes, window
  targeting, hit-testing, and most safety checks.
- Screen Recording: required for screenshots and OCR input.

Input Monitoring is not part of the stated requirement. Clipboard tools use the
system clipboard and are treated as system-side effects; live clipboard checks
belong in local-only verification, not hosted CI.

The daemon is a per-user local trust boundary. It uses a Unix domain socket in a
0700 runtime directory, same-UID peer validation, and a per-user bearer token.
If a daemon is stale, the client asks it to shut down during version handover.
If daemon dispatch fails, mutating tools fail closed rather than bypassing
leases and safety arbitration in-process.

## Unsupported Or Weakly Supported Cases

These are known non-goals or best-effort areas:

- locked Mac (mutating tools pause with a recoverable error until the user
  unlocks), logged-out session, headless session without a capturable user
  desktop;
- off-screen, minimized, hidden, or non-capturable windows when screenshots are
  required;
- apps that do not expose useful Accessibility structure and cannot be operated
  reliably by coordinates or OCR;
- secure password fields, destructive actions, or confirmation-listed apps
  without `confirm:true`;
- background keyboard shortcuts in apps that require key-window focus;
- global click or keyboard delivery without explicit caller opt-in;
- hosted CI claims for live GUI, TCC, clipboard, window-management, or input
  delivery behavior.

## Local Mac Versus Sandbox Or VM Drivers

A local unlocked-Mac driver is privileged compared with sandbox or VM
computer-use environments because it can act below the visual stream:

- AX provides semantic roles, labels, values, actions, focused elements, window
  metadata, and settable attributes that a pure screenshot stream does not.
- ScreenCaptureKit can capture a specific window without foregrounding it,
  while many VM drivers observe one composited display stream.
- CoreGraphics can post events to a process or window instead of always moving
  a virtual or real pointer through a global display.
- The daemon can coordinate multiple local agents with app leases and shared
  snapshots in the same user session.

The tradeoff is that correctness depends on macOS TCC grants, the target app's
AX/event behavior, an unlocked desktop, and user-session state. The production
contract should therefore distinguish deterministic unit guarantees from local
runtime guarantees.

## Failure And Recovery Language

Public failures should be recoverable and specific:

- permission missing: run `computer-use-mcp doctor --prompt` and grant the host
  app Accessibility or Screen Recording;
- element id did not survive the latest snapshot: call `get_app_state` (or use
  the diff returned by the last action) and use a fresh id;
- missing app/window: call `list_apps`, `open_app`, or `list_windows`;
- coordinate out of bounds: use coordinates from the latest screenshot;
- sparse tree: retry `get_app_state` with `ocr:true`, use `find`, or target by
  coordinates;
- background action did not land: focus telemetry reports `ui_changed`, a
  no-visible-change background delivery appends a dropped-event hint, and the
  caller retries with an explicit global or foreground path when acceptable;
- interference yield: retry after the user has been idle for
  `interference_idle_seconds`;
- URL policy: `url_deny` blocks are final; `url_confirm` matches retry with
  `confirm:true`;
- screen locked: wait for the user to unlock; read-only perception stays
  available;
- daemon unavailable: every tool fails fast with `DAEMON_UNAVAILABLE`; restore
  the daemon and retry;
- app lease denied: retry after the reported lease expiry;
- skill step failed: fix the named step, `save_skill` again, and re-run.

Avoid ambiguous success claims. If the server cannot observe the post-action
effect, the caller should use returned state or `wait_for` as the verification
surface.

## Future Test Harness Hooks

Useful next hooks should stay split by risk tier:

- Pure unit/contract tests:
  - tool-schema assertions for modality-specific parameters such as
    `allow_global_cursor`, `include_state`, `include_screenshot`,
    `scope_element_id`, and coordinate descriptions;
  - coordinate-space round trips and bounds checks;
  - snapshot diff shaping and element-id survival across UI changes
    (covered by `SnapshotDiffTests`);
  - interference-yield decisions, URL policy matching, batch validation, and
    skill validation/templating/unique-anchor resolution (covered by the
    corresponding deterministic suites in `Tests/`);
  - daemon fallback classification for read-only versus mutating tools;
  - safety-policy confirmation coverage.
- CLI or daemon integration checks on a non-mutating surface:
  - `version` and `help`;
  - daemon handshake/version/auth behavior with test sockets where possible;
  - dry-run smoke metadata from `scripts/e2e_demo.py`.
- Local live macOS checks, only with explicit approval:
  - TextEdit or Calculator state capture with Accessibility and Screen
    Recording already granted;
  - AX-first click/type/value flows that return fresh state;
  - background focus-stability checks;
  - explicit global-cursor fallback proof in a disposable app/window;
  - lease contention across two MCP sessions.

Hosted CI should remain in the first two categories unless a self-hosted,
pre-authorized macOS runner is intentionally provisioned for live GUI/TCC
coverage.

## Source Anchors

- `Sources/computer-use-mcp/Tools/Catalog.swift`: public tool schemas and model
  descriptions.
- `Sources/computer-use-mcp/Tools/Perception.swift`: canonical state result,
  live snapshot capture, screenshot detail, OCR, and sparse-web retry.
- `Sources/computer-use-mcp/Core/Screenshot.swift`: ScreenCaptureKit window
  capture, permission gate, capture timeout, and replayd recovery language.
- `Sources/computer-use-mcp/Core/Snapshot.swift`: live AX-handle identity,
  attachment validation, tree diffs, and id survival across snapshots.
- `Sources/computer-use-mcp/Core/FocusTelemetry.swift`: focus/cursor/delivery
  telemetry including `ui_changed`.
- `Sources/computer-use-mcp/Core/InterferenceGuard.swift`: HID-idle yield gate.
- `Sources/computer-use-mcp/Core/URLPolicy.swift`: browser URL deny/confirm
  policy.
- `Sources/computer-use-mcp/Core/SessionPower.swift`: sleep assertion and
  screen-lock pause.
- `Sources/computer-use-mcp/Tools/BatchTool.swift`: batch validation and
  stop-at-first-failure execution.
- `Sources/computer-use-mcp/Skills/SkillStore.swift` and
  `Sources/computer-use-mcp/Skills/SkillTools.swift`: skill persistence,
  validation, templating, unique semantic anchoring, and replay.
- `Sources/computer-use-mcp/Core/HitTest.swift`: screenshot-pixel to
  global-point conversion and coordinate bounds.
- `Sources/computer-use-mcp/Core/Input.swift`: dispatch ladder, per-window and
  per-pid delivery, global cursor and keyboard escape hatches.
- `Sources/computer-use-mcp/Core/Window.swift`: default and title-based window
  targeting.
- `Sources/computer-use-mcp/Daemon/DaemonServer.swift`,
  `Sources/computer-use-mcp/Daemon/DaemonClient.swift`, and
  `Sources/computer-use-mcp/Dispatch.swift`: daemon ownership, handoff, leases,
  and fail-closed mutating fallback.
- `docs/TESTING.md`: verification tiers and live-GUI safety boundary.
