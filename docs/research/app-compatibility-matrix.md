# App Compatibility Matrix (macOS Accessibility)

Read-only survey run 2026-07-01 with the release CLI (`.build/release/computer-use-mcp call ...`).
Running apps were probed live with `list_windows` + `get_app_state` (`max_elements: 300`);
non-running apps were classified statically from `Contents/Frameworks` and `Info.plist`
(never launched).

Classification legend:

- **RICH** — full native AX tree with roles/labels; element-id interaction works directly.
- **SPARSE-ENABLEABLE** — web renderer (Electron/Chromium/WebKit) that honors the
  accessibility opt-in (`AXEnhancedUserInterface`/manual); tree is rich once enabled.
- **OPAQUE** — CEF-style renderer that rejects the opt-in; OCR + coordinates only.
- **UNKNOWN-STATIC** — not running; classification predicted from bundle inspection only.

## Live results (running apps)

| App | Bundle id | Windows | Elements | Depth | Labels/values | AXWebArea | Sparse hint | Classification |
|---|---|---|---|---|---|---|---|---|
| Claude | com.anthropic.claudefordesktop | 1 ("Claude") | 300 (truncated at cap) | 8 | 35 labeled, 226 with values | Yes (2) | No | SPARSE-ENABLEABLE (verified: tree fully populated) |
| Codex | com.openai.codex | 1 ("Codex") | 300 (truncated at cap) | 7 | 35 labeled, 115 with values | Yes (1) | No | SPARSE-ENABLEABLE (verified) |
| Electron (pi dev build) | com.github.Electron | 1 ("pi") | 57 | 4 | 22 labeled, 37 with values | Yes (1) | No | SPARSE-ENABLEABLE (verified) |
| System Settings | com.apple.systempreferences | 1 ("Screen & System Audio Recording") | 204 | 7 | 9 labeled, 67 with values; outline rows/cells well-formed | No | No | RICH |
| TextEdit | com.apple.TextEdit | 0 | n/a | n/a | n/a | n/a | n/a | RICH (AppKit) — untestable now; `get_app_state` returns a clean "no windows" error |

Notes on the live probes:

- **Claude**: Electron. Dual AXWebArea (main view + an overlay/second web area). Buttons
  carry labels ("New session", "Customize", session titles); static text carries values.
  Deep chat content pushed the 300-element cap immediately — real trees need
  `max_elements` raised or `scope_element_id`.
- **Codex**: not Electron. It is a **Chromium app-mode shell**: `Codex Framework.framework`
  with the Chromium helper layout (`Codex (Renderer).app`, `(GPU)`, `(Service)`,
  `(Alerts)`, `app_mode_loader`, `browser_crashpad_handler`). Behaves like Chrome for AX:
  honors the opt-in, full web AX tree, lots of AXImage/AXListMarker noise.
- **Electron "pi"**: generic `com.github.Electron` bundle id (unsigned dev run of pi-gui,
  distinct from `/Applications/pi-gui.app`). Small clean tree; window chrome buttons
  (close/zoom/minimize) are unlabeled AXButtons.
- **System Settings**: classic AppKit/SwiftUI. Structure (AXOutline/AXRow/AXCell) is
  excellent but **icon-only buttons are unlabeled** (only 9 quoted labels in 204
  elements) — element roles + values do most of the work here.

## Static results (installed, not running — never launched)

All of these are **UNKNOWN-STATIC**; the "Predicted" column is the expected runtime class.

| App | Bundle id | Toolkit evidence | Predicted class |
|---|---|---|---|
| 1Password | com.1password.1password | Electron Framework | SPARSE-ENABLEABLE |
| CleanShot X | pl.maketheweb.cleanshotx | AppKit; `LSUIElement=true` (menu-bar app) | RICH, but windows are transient/overlay-style |
| Cluely (New) | com.cluely.app.april22 | Electron Framework | SPARSE-ENABLEABLE |
| Codex 2 | com.openai.codex2.launcher | zsh launcher script (sets `CODEX_HOME=~/.codex-2`, execs Codex) | Same as Codex: SPARSE-ENABLEABLE |
| Cursor | com.todesktop.230313mzl4w4u92 | Electron Framework | SPARSE-ENABLEABLE |
| Devin | com.exafunction.windsurf | Electron Framework (rebranded Windsurf) | SPARSE-ENABLEABLE |
| Docker | com.docker.docker | Outer bundle `LSUIElement=true`; nested `Docker Desktop.app` has Electron Framework | SPARSE-ENABLEABLE (target the nested app's process) |
| Flux | org.herf.Flux | AppKit; `LSUIElement=true` | RICH (menu-bar only) |
| Freedom | com.80pct.FreedomPlatform | AppKit; `LSUIElement=true` | RICH (menu-bar only) |
| GarageBand | com.apple.garageband10 | AppKit (37 Apple frameworks) | RICH structurally; heavy custom-drawn controls may need OCR |
| General Work | io.fant.colleague | Electron Framework | SPARSE-ENABLEABLE |
| Ghostty | com.mitchellh.ghostty | Native Swift/AppKit shell, GPU-rendered terminal surface | RICH chrome; terminal grid likely sparse → OCR/read_text fallback |
| Google Chrome | com.google.Chrome | Chromium (Google Chrome Framework) | SPARSE-ENABLEABLE (canonical opt-in responder) |
| Keynote Creator Studio | com.apple.Keynote | AppKit (renamed Keynote) | RICH |
| Ledger Wallet | com.ledger.live | Electron Framework | SPARSE-ENABLEABLE |
| Numbers Creator Studio | com.apple.Numbers | AppKit (renamed Numbers) | RICH |
| Orca | com.stablyai.orca | Electron Framework | SPARSE-ENABLEABLE |
| Pages Creator Studio | com.apple.Pages | AppKit (renamed Pages) | RICH |
| Rectangle | com.knollsoft.Rectangle | AppKit; `LSUIElement=true` | RICH (menu-bar only) |
| Safari | com.apple.Safari | Native WebKit | RICH (WebKit exposes web AX without the Chromium opt-in) |
| Screen Studio | com.timpler.screenstudio | Electron Framework | SPARSE-ENABLEABLE |
| Spotify | com.spotify.client | **Chromium Embedded Framework** + CEF helper apps | **OPAQUE (predicted)** — the only CEF app installed; expect the "rejects the accessibility opt-in" sparse-hint variant → OCR + coordinates |
| Starry (+5 backup copies) | com.matthewlam.interviewcopilot | Tauri (`pluely` binary links system WebKit; second binary `openai_eval_gate`) | WKWebView exposes AX natively → likely RICH-ish web tree |
| T3 Code (Alpha) | com.t3tools.t3code | Electron Framework | SPARSE-ENABLEABLE |
| Tailscale | io.tailscale.ipn.macsys | Native; `LSUIElement=true` | RICH (menu-bar only) |
| Telegram | ru.keepcoder.Telegram | Native Swift/AppKit (no web markers) | RICH; some custom-drawn list rows may be thin |
| Visual Studio Code | com.microsoft.VSCode | Electron Framework | SPARSE-ENABLEABLE |
| Wispr Flow | com.electron.wispr-flow | Electron Framework | SPARSE-ENABLEABLE |
| Xcode | com.apple.dt.Xcode | AppKit | RICH (huge trees; expect truncation at default caps) |
| cmux | com.cmuxterm.app | Native Swift + system WebKit (WKWebView) | RICH shell + WebKit web AX |
| iMovie | com.apple.iMovieApp | AppKit | RICH; timeline canvas may be custom-drawn |
| logioptionsplus | com.logi.optionsplus | Electron Framework | SPARSE-ENABLEABLE |
| pi-gui (+2 backup copies) | com.pi-gui.desktop | Electron Framework | SPARSE-ENABLEABLE (verified indirectly via the running dev build) |
| zoom.us | us.zoom.xos | Native (130 frameworks) + WebView bundles (`zUnifyWebViewApp`) | RICH chrome; meeting canvas custom-drawn → OCR fallback likely |

Population summary: of 34 distinct installed apps, **15 are Electron**, **2 are
Chromium-shell** (Chrome, Codex), **1 is CEF** (Spotify), **2 are Tauri/WKWebView-hybrid**
(Starry, cmux), and the rest are native AppKit (about half of those are `LSUIElement`
menu-bar apps with no standing windows).

## Quirks

- `get_app_state` **ignores `include_screenshot`**: the handler hardcodes
  `screenshot: .full` (`Sources/computer-use-mcp/Tools/Perception.swift:23`) and the
  param is not in the tool's schema (`Catalog.swift` get_app_state entry) — it only
  exists on action tools. Every probe captured a full-window PNG regardless; the CLI
  persisted it to a temp path instead of inlining it. If callers expect the flag to
  suppress capture on `get_app_state`, it doesn't.
- **Element ids are namespaced by snapshot scope** (`e1@s1` vs `e1@s2`): the pi window
  returned two different `e1`/`e2`/`e3` (web-area children at `@s2`, titlebar buttons at
  `@s1`) in one output. Correct behavior, but an agent that strips the `@sN` suffix would
  collide.
- **Scrolled-out content gets height-1 boxes**: Claude and Codex trees contain many
  elements with `h=1` geometry (e.g. `(487,38,255,1)`) — present in the tree but with
  collapsed bounds. Element-id actions should still work; raw-coordinate clicks on those
  boxes would miss.
- **No sparse-tree hint fired for any running app** — every web renderer currently
  running (2 Electron, 1 Chromium shell) had an effective opt-in and produced >10
  elements. The OPAQUE/"rejects the opt-in" path is untested live; Spotify is the
  candidate to exercise it.
- **TextEdit runs windowless**: `list_windows` and `get_app_state` both return the clean
  "has no windows" guidance rather than an error object. Good UX; worth remembering that
  a "running" app can still be unprobeable.
- **System Settings labels are thin**: only 9/204 elements had quoted labels (toolbar and
  icon buttons unlabeled); a disabled `AXMenuButton "Forward"` and an `AXStaticText`
  window title advertising `actions=Press` were also observed. The open pane was
  "Screen & System Audio Recording" (permission management in progress on this machine).
- **Bundle-id surprises**: Devin is `com.exafunction.windsurf`; Cursor is a ToDesktop
  build id (`com.todesktop.230313mzl4w4u92`); "Codex 2" is just a zsh script that
  launches Codex with a different `CODEX_HOME`; the Apple iWork apps are installed under
  renamed bundles ("… Creator Studio") but keep their real `com.apple.*` ids. Name-based
  app resolution must not assume display name ≈ bundle id.
- **Element-count truncation is the norm for real apps**: both chat apps hit the
  300-element cap instantly; the tool's own hint (`scope_element_id` / raise
  `max_elements`) is the right recourse and was emitted correctly.

## Recommendations

- **Electron / Chromium-shell apps (largest class here, 17+ apps)**: the opt-in +
  settle-and-rebuild pipeline is the right default and demonstrably works (Claude, Codex,
  pi). Invest in tree-budget ergonomics — these apps blow past `max_elements` fastest, so
  scoped re-query and role-based filtering matter more than raw coverage.
- **CEF apps (Spotify)**: keep the OPAQUE fast-path — remember the rejected opt-in (the
  code already persists this) and steer the agent straight to `ocr:true` + coordinate
  clicks; don't re-attempt the opt-in each call.
- **Native AppKit apps**: trees are structurally rich but label-poor (System Settings:
  4% labeled). OCR-assisted labeling or value/role heuristics would help disambiguate
  icon-only buttons; pure label matching in `find` will under-perform here.
- **Custom-drawn surfaces inside native apps** (Ghostty's terminal grid, zoom.us meeting
  canvas, GarageBand/iMovie editors): expect a rich shell around an opaque canvas —
  the sparse-tree heuristic won't fire because the window tree isn't sparse overall.
  Consider a per-subtree "large empty region with no elements" heuristic to suggest OCR
  for just that region.
- **Menu-bar (`LSUIElement`) apps** (CleanShot X, Flux, Freedom, Rectangle, Tailscale):
  no standing windows; interactions go through status items and transient panels. The
  windowless-app guidance TextEdit produced is the right pattern; make sure status-item
  menus are reachable without a main window.
- **WKWebView/Tauri apps** (Starry, cmux, Safari): WebKit exposes web AX without the
  Chromium opt-in — do not burn the settle-and-rebuild retry on them; a WebKit check
  before forcing `AXEnhancedUserInterface` avoids wasted latency.
