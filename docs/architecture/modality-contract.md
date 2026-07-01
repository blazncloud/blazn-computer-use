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
| Element identity | `element_id` values belong to the latest snapshot generation for a pid, for example `e12@s3`. Actions re-resolve the stored locator against the live AX tree before acting. | Call `get_app_state` or use the fresh state returned after an action. Use `scope_element_id` when the tree was truncated. | Stale generation, missing id, locator identity mismatch, or app death produces a clear retry-with-fresh-state error. |
| Coordinate identity | Raw `x` and `y` are screenshot pixels from the latest snapshot for that app. They are bounds-checked, converted to global screen points, then optionally hit-tested back to an AX element for labels and safety gates. | Use coordinates when the target is absent from AX, custom drawn, or found by OCR. | Coordinates outside the latest screenshot are rejected; coordinates require a prior state capture. |
| Dispatch ladder | Left click prefers AX actions first, then window-routed process events, then per-pid CoreGraphics events. AX-backed text/value/menu/window operations use Accessibility directly. Scroll and drag use targeted event delivery. | `allow_global_cursor:true` enables the real-cursor/session-tap path for clicks. `press_key` can use global keyboard delivery only when the target app is already foreground. | Background event posting is app-dependent and has no reliable success signal, so global escalation is explicit rather than automatic. |
| Foreground guarantee | Default pointer and key delivery does not activate the target app, move the real cursor, or steal user focus. `open_app` also avoids activation by default. | `open_app activate:true`, `manage_window raise`, or explicit global cursor/keyboard modes can affect focus or visible ordering. | Global keyboard delivery fails if requested while the target app is not foreground. Apps that require real focus may ignore background events. |
| Session ownership | `serve` is a thin MCP stdio shim over one per-user daemon by default. The daemon owns capture, AX, input, overlay cursor, and app leases. | `COMPUTER_USE_MCP_NO_DAEMON=1` runs the engine in process. Read-only tools may fall back in process if the daemon is unavailable. | Mutating tools fail closed when daemon arbitration is unavailable, unless in-process mode was explicitly selected. |
| Multi-session guarantee | Per-app leases serialize action tools against the same resolved pid for a short window after each action. Perception is never blocked. | Work in another app, retry when the lease expires, or explicitly disable app leases for local experiments. | Lease denial names the app and remaining wait time. It prevents interleaved actions, not every possible app-level race. |
| Safety policy | Destructive labels, confirmation-listed apps, secure password fields, risky URL schemes, and destructive window actions require `confirm:true`. | The caller may retry with `confirm:true` after reading the server's reason. | Recoverable "Confirmation required" errors are part of the tool contract, not crashes. |

## Observation Surfaces

`get_app_state` is the canonical state surface. It:

- requires Accessibility permission before reading app structure;
- targets the front window by default, or a matching `window_title`;
- captures the target window with ScreenCaptureKit when screenshots are
  requested;
- enables Chromium/Electron web accessibility flags when needed;
- emits element ids, roles, labels, values, actions, and boxes in screenshot
  pixels;
- persists the snapshot so later calls can resolve ids across `serve`, `call`,
  and daemon boundaries.

Action tools return fresh state by default. Reduced screenshots keep the loop
cheap after actions; explicit `get_app_state` returns full-detail pixels. If an
action leaves the tree unchanged, the result says existing ids remain valid
instead of resending an identical tree.

`find` is a search surface, not a capture surface. It walks up to 5000 AX
elements and persists fresh ids, but it keeps coordinates in the last screenshot
scale because it does not capture a new screenshot.

`ocr:true` is a fallback for custom-drawn or sparse AX UIs. OCR boxes are still
reported in screenshot pixels and should normally be used with coordinate
actions.

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
The caller should inspect the returned state and choose whether to retry with
an escape hatch.

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

- locked Mac, logged-out session, headless session without a capturable user
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
- stale element id: call `get_app_state` and use a fresh id;
- missing app/window: call `list_apps`, `open_app`, or `list_windows`;
- coordinate out of bounds: use coordinates from the latest screenshot;
- sparse tree: retry `get_app_state` with `ocr:true`, use `find`, or target by
  coordinates;
- background action did not land: inspect returned state and retry with an
  explicit global or foreground path when acceptable;
- daemon unavailable: read-only fallback may continue, mutating tools require a
  healthy daemon or explicit `no_daemon` mode;
- app lease denied: retry after the reported lease expiry.

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
  - snapshot-generation stale-id rejection;
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
  snapshot persistence, screenshot detail, OCR, and sparse-web retry.
- `Sources/computer-use-mcp/Core/Screenshot.swift`: ScreenCaptureKit window
  capture, permission gate, capture timeout, and replayd recovery language.
- `Sources/computer-use-mcp/Core/Snapshot.swift`: generation-tagged element ids
  and stale locator recovery.
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
