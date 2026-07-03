# ComputerUseFixture — truth-suite fixture app

`ComputerUseFixture` is a deterministic SwiftUI app whose controls have **known
ground truth**, so the end-to-end "truth suite" can test the verifier-first
outcome contract (`success` / `unsupported` / `effect_not_verified` /
`verifier_ambiguous`) against controls that behave predictably instead of
against whatever a real third-party app happens to render.

The guiding principle is **read-act-read**: every interactive control writes its
outcome into an independently AX-readable *readout* (a labelled element whose
`AXValue` is the live state). A verifier reads the readout before and after an
action and classifies the outcome from the *observed* change — never from the
command's own `ok:true`. Some controls are deliberate **KNOWN LIARS**: they
report AX success while mutating nothing, giving the suite a ground-truth case
where a naive "trust the command" verifier would be wrong.

## Build & run

```bash
swift build
.build/debug/ComputerUseFixture         # or: swift run ComputerUseFixture
```

Then drive it through the real server, e.g.:

```bash
.build/debug/computer-use-mcp call get_app_state '{"app":"ComputerUseFixture"}'
```

The process registers as an app named **ComputerUseFixture**.

## Launch mode: background by default

The fixture launches **in the background** so its window never pops over
whoever is frontmost while a worker runs live tests. The AppDelegate sets
`NSApplication.setActivationPolicy(.accessory)` in `applicationWillFinishLaunching`
(before SwiftUI shows the window), then `orderBack` + `resignKey` + `deactivate`
the window so it is on-screen but never key/front and the app is not activated.
The server drives it in the background by design, so the window stays visible,
orderable, AX-readable, SCK-capturable, and hit-testable — verified below.

Set **`COMPUTER_USE_FIXTURE_FOREGROUND=1`** to restore a normal foreground app
(`.activationPolicy(.regular)` + `activate(ignoringOtherApps: true)` +
`makeKeyAndOrderFront`). Use this for occlusion-proof scenarios where a worker
deliberately arranges windows and needs the fixture actually frontmost.

The window is pinned to a consistent modest position (top-left of the main
screen's visible area, inset 80pt) rather than SwiftUI's centered splash, so its
frame is deterministic across launches.

```bash
.build/debug/ComputerUseFixture                          # background (default)
COMPUTER_USE_FIXTURE_FOREGROUND=1 .build/debug/ComputerUseFixture   # foreground
```

Verified (launched while Finder was frontmost):

| Check | Background default | Foreground opt-out |
|---|---|---|
| `System Events … background only` | **true** (`.accessory`) | **false** (`.regular`) |
| Process is frontmost | false | — (restores regular activation) |
| Frontmost app changed at launch | **no** (stayed Finder) | app is `.regular`/activatable |
| Window exists (`list_windows`) | yes | yes |
| All controls perceivable (`get_app_state`) | yes | yes |
| Background honest-button click | **lands** (counter 0→1, `ax-press`), frontmost unchanged | — |

## Control → scenario map

| Control | AX label | Role | Readout (label → value) | Truth-suite scenario |
|---|---|---|---|---|
| Honest button | `honest-button` | AXButton (Press) | `counter` → count | Baseline `success`: press increments a visible counter, read-act-read confirms the effect. |
| **Liar button** | `liar-button` | AXButton (Press) | `liar-readout` → `never-changes` (wired to nothing) | `effect_not_verified`: `accessibilityPerformPress()` returns `true` but mutates no state. A verifier that trusts `ok:true` is wrong; read-act-read sees no change. |
| Disabled button | `disabled-button` | AXButton, `disabled` | — | `unsupported`: control is present but disabled; an action attempt must not be classified `success`. |
| Toggle | `toggle-box` | AXCheckBox (`value` 0/1) | `toggle-state` → `on`/`off` | `success` with a settable value: toggling flips both the checkbox `AXValue` and the independent state readout. |
| Keystroke input | `keystroke-input` | AXTextArea, read-only `AXValue` | `keystroke-echo` → typed text | `type_text` CGEvent fallback: the element is **not** AX-value-settable (getter only, no setter), so an AX `set_value` must fail and typing has to fall back to synthetic key events routed to the focused first responder. The echo readout confirms keystrokes landed. |
| Virtualized list | `row-list` | AXTable of 500 AXRows (AppKit NSScrollView + NSTableView via NSViewRepresentable) | row `AXValue` = `Row 001`…`Row 500` | Dense-collection viewport windowing: only ~visible rows are realized in the AX tree at a time; rows past the viewport report off-screen frames, and NSTableView exposes AXRows/AXVisibleRows natively. Scroll + re-read exercises progressive traversal. Background scrolling: a real NSScrollView does NOT honor `AXScrollDownByPage` on perform (returns `attributeUnsupported`), but its `AXVerticalScrollBar` value IS settable and moves the content — which the scroll tool's tier-1 uses to actually scroll the list in the background (a plain SwiftUI `List` moved nothing). |
| Web pane | `web-pane` | AXGroup → AXWebArea | see web sub-controls below | Web-AX exposure and skeleton traversal into WKWebView content. |
| Window clamp | window `ComputerUse Fixture` | AXWindow | (frame via `list_windows`) | `manage_window` resize clamping — see below. |

### Web pane sub-controls (inside `web-pane`)

| Element | AX label / role | Scenario |
|---|---|---|
| Heading | `Fixture Web Heading` (AXHeading) | Web-AX heading is reachable via skeleton traversal. |
| Link | `Fixture Web Link` (AXLink, Press) | Web link exposes an actionable Press. |
| DOM-mutate button | `Mutate DOM` (AXButton, Press) | Read-act-read across the web boundary: pressing it changes the `unmutated` paragraph's text to `mutated`, observable as a web-AX value change. |
| Article | 40 `Article paragraph N` static texts | Long scrollable web content for scroll + visible-range read tests. |

## Window resize clamp

The window uses SwiftUI `.windowResizability(.contentSize)` with a root-view
`.frame(minWidth: 720, maxWidth: 1200, minHeight: 540, maxHeight: 900)`, so
SwiftUI itself maintains the window's content min/max (a delegate-set
`contentMinSize`/`contentMaxSize` gets overridden by SwiftUI's layout pass and
does **not** clamp reliably).

Observed clamp behavior for `manage_window action:resize` (read back via
`list_windows`, values are window-frame points including the ~32pt title bar):

| Request (w×h) | Result (w×h) | Note |
|---|---|---|
| 2000 × 2000 | **1200** × ~760 | Width clamped to the 1200 max; height bounded by content. |
| 200 × 200 | **720** × ~572 | Both axes clamped up to the 720 × 540 minimum (+ title bar). |
| 800 × 700 | 800 × 700 | Mid-range request passes through unclamped. |

- **Width** is a clean two-sided clamp: requests are constrained to
  **[720, 1200]** pt. The content is intentionally wider than 1200, so the max
  is always the binding constraint.
- **Height** minimum is enforced at **540** pt (frame ~572 with title bar). The
  configured maximum is **900** pt, but under content-size resizability a window
  cannot grow taller than its content's natural height, so on the current layout
  an oversize height request settles at ~760 pt (content-bound) rather than the
  900 ceiling. The clamp is still observable (2000 → ~760); it is simply
  content-limited below the nominal ceiling.

## Notes

- The row-list is a real AppKit `NSScrollView` + `NSTableView` bridged via
  `NSViewRepresentable` (not a SwiftUI `List`), specifically so its scroll
  position is drivable in the background through the AX scroll-bar value. A
  SwiftUI `List` swallows synthetic wheels and no-ops `AXScrollDownByPage`, so a
  correctly-routed background scroll moved nothing.
- The fixture never steals focus on launch (`activate(ignoringOtherApps:
  false)`) so it cannot mask a headless-policy focus violation in the suite.
