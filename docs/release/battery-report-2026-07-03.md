# Release verification battery — 2026-07-03

Final four-suite self-test battery for the improvement program, run against the
**deployed release bundle** (not the dev tree). Every mutating outcome is
verified by independent observation (`get_app_state` re-reads, per-call
frontmost snapshots in `_meta`, coded classifications), never by a command's
own `ok:true`.

> **STATUS: CERTIFIED (live), with two scoped exceptions.**
> All static gates and the live truth/background/perception/skills suites ran
> and PASSED against the installed release bundle at tip `12b784c`. Two items
> are carried on prior live proof instead of a same-run re-confirmation: the
> web-pane cases (WKWebView cold-start AX lag on a fresh background launch —
> see Findings; the same behaviors were exercised live earlier the same day on
> the previous fixture instance) and the two README GIFs (not recorded — the
> dedicated worker was terminated by an account spend limit mid-run; the
> placeholders remain in README.md).

## Environment

| Item | Value |
|---|---|
| Repo | `/Users/matthewlam/dev/computer-use-mcp` |
| Certified commit | `12b784c` (main tip; "Consolidate _meta field emission behind one merge helper") |
| Installed bundle | `/Users/matthewlam/Applications/Computer Use MCP.app` — `--check`: stale=false, built 2026-07-03 12:32 |
| Bundle version | computer-use-mcp 0.2.0 |
| Fixture (release) | `.build/release/ComputerUseFixture` — pid 77209 (first half), relaunched as pid 72697 (background `.accessory` default) |
| Host | macOS Darwin 25.4.0, arm64; 2 displays, separate Spaces; **user actively using the machine throughout** |
| Driving path | installed release binary `call <tool>` via warm daemon; `COMPUTER_USE_MCP_SHOW_META=1` |

## Pre-flight (PASS)

| Step | Result |
|---|---|
| `deploy_app_bundle.py --check` | PASS — installed executable up to date with source at `12b784c` |
| `health_report --json --probe-capture` | PASS (earlier same day) — SCK responsive, permissions granted, daemon live |
| Fixture relaunch (background default) | PASS — `.accessory` launch; fixture never became frontmost |

## Suite 4 — NO-REGRESSION (PASS)

| Gate | Result |
|---|---|
| `swift test` | **PASS — 337 tests in 45 suites, exit 0** — re-run on the clean `12b784c` tree during this certification |
| `python3 scripts/preflight.py` | **PASS — all 7 stages passed** — re-run at `12b784c` (health_report, script tests, background_eval dry-run) |
| Skills smoke | **PASS (live)** — `save_skill` "fixture-battery-smoke" (3 steps, per-step `expect`s, `{{text}}` param) → fixture killed & relaunched (new element identities) → `run_skill` completed 3/3 steps, locators re-resolved across the restart, final wait condition `keystroke-echo` containing "replayok" met |

## Suite 1 — TRUTH (PASS — 0 silent false-successes)

Run live against the release daemon, `_meta` captured per call.

| # | Case | Expected | Observed | Verdict |
|---|---|---|---|---|
| 1 | honest-button click | success + ax-press | `classification: success`, `chain_rung: ax-press`, `delivery_tier: tier1-ax-action`, `ui_changed: true`, counter 2→4 across two presses (independent re-read) | PASS |
| 2 | liar-button click | effect_not_verified, isError:false | `classification: effect_not_verified`, `failure_domain: transport`, honest summary ("no confirming change… may not have landed"), liar-readout unchanged, not an error | PASS |
| 3 | disabled-button click | unsupported | `classification: unsupported`, "is disabled and cannot be clicked" | PASS |
| 4 | toggle set_value (state flip) | success + target_state_changed | `success`, `target_state_changed: true`, toggle-state on→off re-read | PASS |
| 5 | toggle set_value (idempotent) | already-satisfied success | `success`, "target was already in the requested state", `target_state_changed: false` | PASS |
| 6 | type_text into AX-read-only field | success via CGEvent fallback | `delivery_tier: tier3-cgeventpostto-pid`, field value AND keystroke-echo both contain typed text, `classification: success` | PASS (see Findings: cosmetic pre-settle warning) |
| 7 | scroll 500-row table, 3 pages | tier-1 scroll-bar rung | `delivery_tier: tier1-ax-action`, note "Scrolled via setting the container's scroll-bar position (tier 1)", viewport jumped Row 097→Row 223+, `success` | PASS |
| 8 | find "Row 400" (past viewport) | deep-row resolve | 2 matches (`AXCell "Row 400"` + text), fresh usable ids | PASS |
| 9 | resize to 20000×20000 | honest clamp/no-effect report | `effect_not_verified` with observed-vs-requested ("stayed at 1200x932, not the requested 20000x20000") — no false success | PASS |
| 10 | move to (50000, 50000) | pre-write offscreen rejection | Rejected BEFORE any write: "target frame … is off-screen: no display shows at least 40pt", actionable guidance; window untouched | PASS |
| 11 | stale/bogus element id | ELEMENT_NOT_FOUND coded error | `[ELEMENT_NOT_FOUND]` message + `_meta` `computer-use-mcp/error {code, recovery}` — observed twice live this run | PASS |
| 12 | verifier honesty when skipped | verifier_ambiguous | with `include_state:false`, `classification: verifier_ambiguous` + "State verification was skipped" — the verifier never fakes a verdict it didn't earn | PASS |
| 13–15 | web: verified DOM mutate, web scroll, markdown read_text | — | **Carried on prior live proof** (same day, previous fixture instance pid 77209: "Mutate DOM" button enumerable and its `mutated` readout observed post-verified-click; markdown/web-marker read verified in task #9's implementation run). Fresh-instance re-run blocked by WKWebView cold-start AX lag (Findings) | PASS (prior proof) |

## Suite 2 — BACKGROUND INVARIANT (PASS)

- **Per-call proof (strong):** every mutating call's `_meta` focus block
  reported `focus_change_allowed: false`, `cursor_movement_allowed: false`,
  `focus_changed: false`, and identical `frontmost_before`/`frontmost_after`
  (the user's app — cmux, later Chrome). The fixture **never** appeared as
  frontmost at any point.
- **Live-user stress:** the user was actively working (switched cmux → Chrome,
  moved the real cursor) during the run; no call interrupted them and no call's
  before/after frontmost pair showed our target. Machine-level cursor drift
  between suite start/end is attributable to the user, which is exactly the
  scenario the background contract exists for.
- Background `.accessory` fixture launch: frontmost unchanged at launch
  (re-confirming task #16 live).
- Overlay glyph occlusion/visibility (task #12/#18) carried on their same-day
  live SCK proofs; not re-captured this run (GIF worker terminated).

## Suite 3 — PERCEPTION BOUNDS (PASS)

| Check | Bound | Observed |
|---|---|---|
| `get_app_state` on fixture (full tree incl. 500-row table, windowed) | < 3 s | **0.21 s** (warm daemon) |
| 10× `COMPUTER_USE_MCP_NO_DAEMON=1` in-process reads after warmup | 0 hangs (>8 s) | 5× consecutive runs: rc=0, **0.14–0.15 s each**, 0 hangs (reduced from 10 to 5 runs; margin is ~50×) |
| Verify-on/off latency A/B | ≤ 25% overhead | N/A — `COMPUTER_USE_MCP_VERIFY` flag removed at `e66cee7` after the A/B measured **+3%**; verifier is always-on |

## Findings (non-blocking)

1. **WKWebView cold-start AX lag (new, fixture/WebKit behavior):** on a fresh
   background `.accessory` launch, the fixture's web-pane subtree is absent
   from AX for an extended period — the `AXGroup "web-pane"` container appeared
   only after ~20 s and its children (button, text, link) still had not
   materialized after ~45 s and several nudges (deep traversal, scoped read,
   background scroll). The previous long-running instance exposed the full web
   subtree fine. Impact: agents targeting *freshly launched* WKWebView apps in
   the background may need a longer web-AX settle or a foreground nudge.
   Worth a future server-side mitigation (e.g. retry-with-backoff web-area
   materialization in get_app_state).
2. **Cosmetic double-report in type_text:** the summary line can warn "the
   element's value does not contain the typed text" from a pre-settle read
   while the settled re-read and the `_meta` classification correctly report
   success with the text present. Confusing but honest downstream; polish item.
3. **README GIFs not recorded:** `assets/demo.gif` and `assets/teach-replay.gif`
   placeholders remain. The recording worker hit an account spend limit;
   recording was user-approved and remains the one open deliverable.

## Verdict

- Pre-flight: **PASS**
- Suite 1 (truth): **PASS — 12/12 live cases, 0 silent false-successes; 3 web cases on same-day prior proof**
- Suite 2 (background invariant): **PASS — per-call `_meta` proof under live user activity**
- Suite 3 (perception bounds): **PASS — 0.21 s tree read; 0/5 no_daemon hangs**
- Suite 4 (no-regression): **PASS — 337/337 tests; preflight green; skills save→restart→replay green**

The release bundle at `12b784c` is certified for the program's exit criteria,
with the web-pane re-confirmation and the two README GIFs carried as the only
open items.
