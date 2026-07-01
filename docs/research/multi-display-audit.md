# Multi-display audit (read-only)

Date: 2026-07-01. Machine under test: two displays with "Displays have separate Spaces" enabled.

- Primary: LG ULTRAWIDE, displayID 3, Quartz bounds (0,0 3440x1440), scale **1x**
- Secondary: Built-in Retina Display, displayID 1, Quartz bounds (947,1440 1512x982), scale **2x** — arranged *below* the primary, so all display-2 Quartz coordinates are positive here (AppKit frame is (947,-982 1512x982)). Negative-origin arrangements are covered by analysis only.
- Display-2 windows at probe time: Google Chrome (pid 647, two windows) and VS Code (pid 654), all at Quartz origin (947,1473).

Method: code reading plus read-only Swift probes (NSScreen/CGDisplay/CGWindowList/SCShareableContent enumeration; AX frame + hit-test + windowID SPI against Chrome's display-2 window; one SCK window capture per display, dimensions only, images discarded). No clicks, no typing, no app activation, no window moves.

**Bottom line: the coordinate pipeline itself is display-2 clean — every probe agreed across CGWindowList, AX, and SCK — but a non-geometric bug in the app resolver makes both display-2 apps on this machine unreachable today, and one code path carries a misleading primary-screen dependency that happens to cancel out.**

---

## Finding 1 — HIGH: `proc_listallpids` return value misread; display-2 apps unresolvable today

`Sources/computer-use-mcp/Core/AppResolver.swift:47-49`

```swift
let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
guard bytes > 0 else { return NSWorkspace.shared.runningApplications }
let count = min(Int(bytes) / MemoryLayout<pid_t>.size, pids.count)
```

`proc_listallpids` returns the **number of pids written, not bytes**. Probe evidence: it returned 756 on a system where `ps ax` shows 756 processes, and buffer entries past index 756 were zero. Dividing by 4 keeps only the newest ~quarter of processes (kernel returns pids newest-first), so every long-running app is invisible to `resolveApp`/`list_apps`.

Empirical failure (repo release build, via the daemon):

- `call list_windows '{"app":"Google Chrome"}'` → `"Google Chrome" is not running.` while Chrome (pid 647) owned two on-screen windows.
- `call list_apps` listed only Claude, Codex, Electron, System Settings, TextEdit — Chrome (647) and Code (654) missing; a replication probe confirmed both pids are absent from the truncated prefix but resolve fine via `NSRunningApplication` (policy `.regular`).

This is **age-correlated, not display-correlated** — but on this machine the login-time apps are exactly the ones parked on display 2, so it *presents* as "nothing on display 2 can be controlled." It also blocked the planned end-to-end `get_app_state` test against a display-2 window; the pipeline was validated at the API layer instead (Finding 6).

Minimal fix: `let count = min(Int(returned), pids.count)`. (Spawned as background task `task_8402ce9a`.)

## Finding 2 — MEDIUM (risk, by design): windows on an inactive Space can't be screenshotted, and the scale fallback can silently change the coordinate space

`Sources/computer-use-mcp/Core/Screenshot.swift:86` fetches `SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)`; a window not on the *current* Space of its display is absent, so `Screenshot.swift:101-103` throws "No capturable window found". With separate Spaces this is per-display: verified empirically that windows on display 2's **active** Space are enumerated and capturable (see Finding 6), but each display multiplies the inactive-Space surface.

The degradation path: `Perception.swift:107-111` catches the error into a note, then `Perception.swift:116-125` falls back to the prior snapshot's `pixelsPerPoint`, else `1`. AX tree building continues (AX works across Spaces — verified). If there is no prior snapshot, element boxes are emitted at 1 px/pt while a later successful capture of the same Retina display-2 window yields ~1.06 px/pt (measured), so coordinates from the first state don't line up with the next screenshot. Concrete scenario: agent targets a Chrome window that the user has since pushed to another Space of display 2 (e.g. by full-screening something there); first `get_app_state` has no screenshot and 1:1 boxes; the agent clicks by those coordinates after the window returns — off by ~6% at 2x.

Minimal fix: when capture fails and no prior scale exists, derive the scale from the display containing the window frame (`NSScreen` whose frame contains `window.frame.origin` → `backingScaleFactor`... note reduced-detail captures are 1x, so the honest minimal fix is to state in the result that boxes are in *points* when no capture happened, or persist scale per window rather than per pid).

## Finding 3 — LOW (works, but misleading + fragile): `bridgedWindowEvent` "primary screen height" cancels out

`Sources/computer-use-mcp/Core/Input.swift:149-154`

```swift
guard let screenHeight = NSScreen.screens.first?.frame.height else { return nil }
let localX = point.x - windowFrame.origin.x
let globalBottomLeftY = screenHeight - point.y
let windowBottomLeftY = screenHeight - (windowFrame.origin.y + windowFrame.height)
let localY = globalBottomLeftY - windowBottomLeftY
```

Algebraically `localY = windowFrame.maxY - point.y` — `screenHeight` cancels, so Tier-2 window-local coordinates are correct for a window on **any** display, including negative-origin arrangements. Verified numerically for Chrome's display-2 window: center (1703, 1947.5) → local (756, 474.5), exactly the window midpoint in bottom-left coords.

Risks that remain: (a) the guard makes Tier 2 silently unavailable if `NSScreen.screens` is ever empty (headless/session-change), degrading all clicks to Tier 3 with no signal; (b) the code *reads* like a primary-display assumption and invites wrong "fixes". Minimal fix: delete the `NSScreen` dependency and compute `localY = windowFrame.origin.y + windowFrame.height - point.y` directly. Note: Tier-2 delivery to a display-2 window was not click-tested (read-only audit); the residual unknown is AppKit's foreign-`windowNumber` bridging, not the coordinate math.

## Finding 4 — INFO: overlay math is display-correct; chip is primary-only by design; pulse ring is 1x on Retina

`Sources/computer-use-mcp/Overlay/OverlayHelper.swift`

- Flip: `appKitPoint` (332-334) uses `primaryHeight` (174-175), which deliberately picks the screen with `frame.origin == .zero` — the correct global Quartz→AppKit flip for any point in the unified plane, including negative origins. For a display-2 point here: Quartz y=1473 → AppKit y=-33, inside the secondary's AppKit frame (947,-982 1512x982). Correct.
- Mirroring: `syncLayers` (159-168) and `showPulse` (343-346) subtract each panel's own `frame.origin` — plain vector subtraction, valid for zero, positive, or negative origins. Cursor and pulse therefore render correctly on display 2; a glide straddling the boundary shows on whichever panel contains the point.
- One panel per `NSScreen` (107-142) with `.canJoinAllSpaces` (118) — with separate Spaces each panel covers all Spaces of its own display. Per-screen `contentsScale` is set for the cursor glyph (125) and chip (132).
- Chip: created only for the `screen.frame.origin == .zero` panel (131) — **primary-only by design** (comments at 65-66 and 401-403). While the agent works entirely on display 2, the "Agent working" pill shows only on display 1; a user watching display 2 sees the cursor/pulses but not the chip. If that's not wanted, add a chip per panel instead of the origin check.
- Cosmetic nit: the pulse `CAShapeLayer` (351-360) never sets `contentsScale`, so the ring rasterizes at 1x — slightly soft on the 2x display 2. One line: `ring.contentsScale = panel.backingScaleFactor` (or the screen's).
- Rendering on display 2 was not visually verified (read-only session; per prior findings the overlay is invisible to `screencapture` and needs SCK via the real server to observe).

## Finding 5 — INFO: remaining core files have no origin-(0,0) assumptions

- `Core/Window.swift:51-54` — window frame comes from `axFrame` (`Core/AX.swift:192-204`), raw `kAXPosition`/`kAXSize` in the global top-left plane; no clamping, negatives pass through.
- `Core/PointTarget.swift:47,54-63` — element path takes the live AX frame midpoint; coordinate path delegates to `screenPoint`.
- `Core/HitTest.swift:34-49` + `Core/Snapshot.swift:65-70` — screenshot pixels are *window-relative*; bounds check against `windowSize` and the `windowOrigin + x/pixelsPerPoint` conversion are display-independent and negative-origin safe. `HitTest.swift:11-13` passes global floats (incl. negative) straight to `AXUIElementCopyElementAtPosition` — verified working at a display-2 point.
- `Tools/SystemTools.swift:153-154` (`list_windows`) prints raw global frames — a display-2 window correctly shows e.g. `(947,1473 1512x949 pt)`. `manage_window move` bounds (`Core/SafetyPolicy.swift:225-234`) check magnitude only, so negative-origin targets are accepted.
- `Screenshot.swift:110-113` fallback matches AX frame against `SCWindow.frame` — probe confirmed both are the same global top-left space on display 2 (identical rects), so cross-display window matching is sound.
- Caveat (staleness, not geometry): coordinate clicks use the *snapshot's* `windowOrigin`; if the user drags the window to the other display between `get_app_state` and the click, the click lands at the old spot. The element-id path is immune (live re-resolve).
- Inverse-display nit: `Screenshot.swift:35-37` floors the full-detail capture scale at 2 — on this 1x primary that upscales 2x for no added detail (bigger payload); on the 2x display 2 it's exact.
- `Tools/Perception.swift:22-27`: `get_app_state` ignores `include_screenshot` (always `.full`) — unrelated to displays; already tracked (pending task `task_4e84e90d`).

## Finding 6 — Empirical evidence: the display-2 pipeline works (metadata level)

All numbers cross-checked, no image content retained:

| Probe | Result on display 2 |
|---|---|
| `CGWindowList` vs AX vs SCK frame for Chrome window 28067 | identical: (947,1473 1512x949) in all three APIs |
| SCK enumeration with separate Spaces (`onScreenWindowsOnly: true`) | both display-2 windows listed, `isOnScreen=true` — **SCK can see and capture the other display's active Space** |
| `SCContentFilter(desktopIndependentWindow:)` | `pointPixelScale=2.0` (correct Retina scale; primary window gives 1.0) |
| Capture (dimensions only) | 1600x1004 px for the 1512x949 pt window → `pixelsPerPoint≈1.058`, cap logic correct |
| `AXUIElementCopyElementAtPosition` at (1703,1947.5) (y beyond primary's 1440) | resolves `AXStaticText` with sane frame (1558,1924 290x31) |
| `_AXUIElementGetWindow` SPI | returns 28067, matches CGWindowList |
| `bridgedWindowEvent` math | local (756,474.5) == expected window midpoint |
| Capture latency | ~10.4s from the ephemeral probe process on **both** displays (identical), i.e. a probe-environment artifact, not display-dependent; note the server's own timeout is 8s (`Screenshot.swift:57`) so cold-replayd latency is worth keeping an eye on generally |

Not verifiable read-only: actual Tier-2/3/4 event delivery to a display-2 window (needs a click), overlay rendering on display 2 (needs the real server + SCK), and negative-origin arrangements (this machine's secondary sits below the primary, all-positive Quartz coords).

## Severity ranking

1. **Finding 1 (HIGH)** — fixes the only thing empirically broken; today it blocks controlling both display-2 apps on this machine (root cause is process age, not geometry).
2. **Finding 2 (MEDIUM)** — inactive-Space capture failure + scale-1 fallback can misalign coordinates; multiplied by separate Spaces.
3. **Finding 3 (LOW)** — correct but fragile/misleading; one-line simplification removes the false primary-screen dependency.
4. **Finding 4 (INFO)** — overlay correct; chip primary-only by design; 1-line Retina pulse nit.
5. **Finding 5 (INFO)** — no other origin assumptions found.
