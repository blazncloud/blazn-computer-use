# Verifier-first outcome contract

Implementation design for Wave 2's anchor change: move `computer-use-mcp` from
"success = the tool didn't throw" to "success = the action's effect was
observed." Inspired by `actuallyepic/background-computer-use` (BCU), adapted to
our snapshot/locator architecture.

Status: implemented (task #4, Wave 2). All mutating tools emit a
`computer-use-mcp/outcome` block; the reducer is unit-tested per §4 matrix row.

As-built notes (where the code deviates from this design):
- The delivery telemetry split (§6, open question) was adopted: a new
  `computer-use-mcp/delivery` block owns `delivery_tier`, `fallback_reasons`,
  and `ui_changed`; `computer-use-mcp/focus` keeps frontmost identity only.
- `focusedElementChanged` is carried in the schema but is **not** used for
  classification — counting a focus change as a click success signal risks a
  false pass on a liar button (an AX press can focus the control), and dialogs
  already flip `renderedTextChanged`. Menus rely on `renderedTextChanged`.
- `manage_window` verifies `resize`/`move` (numeric frame compare); the other
  window actions emit no outcome block (settle-poll + already-in-state depth is
  window-verify task #6). Scroll extent detection is best-effort off the
  container's own scroll bar (fuller ranking is scroll task #7).
- `batch` aggregation (§8) is not yet implemented: each sub-action verifies
  individually through dispatch, but the batch result carries only the final
  step's outcome block.
- The verifier is always on. It shipped behind a temporary `COMPUTER_USE_MCP_VERIFY`
  flag to A/B the latency overhead (~3% median on a click); the flag has since been
  removed and the reread runs unconditionally.

---

## 1. Problem and the shape of the fix

### 1.1 What "success" means today

Every mutating tool funnels through `stateResult()`
(`Tools/Perception.swift:125`). The handler dispatches the action, then
`stateResult` re-perceives the whole window, and the call returns a
`CallTool.Result`. `isError` is set only when a handler *throws* — see
`Dispatch.swift:54` (`result = .text("\(error)", isError: true)`). So the
contract an agent sees is binary and structural: **"the AX write returned
`.success`" or "an exception bubbled up."**

That misses the entire middle: the AX call succeeded, no exception, but *the
thing the user asked for did not happen*. A background NSEvent click silently
dropped by the app; `AXUIElementSetAttributeValue` returning `.success` on a
field the app then ignores; a press on a disabled control. All of these return
`isError: false` today.

We already have three half-built pieces of the verifier we need:

1. **Whole-tree change bit.** `stateResult` computes `unchanged` from a
   normalized `treeFingerprint` (`Core/Snapshot.swift:206`) and surfaces it as
   `ui_changed` in the focus `_meta` block (`Tools/Perception.swift:299-303`).
   Too coarse — it can't tell "checkbox toggled" from "unrelated clock ticked."
2. **Field-level readback, for two tools only.** `type_text` reads the value
   back and warns on mismatch (`readBackWarning`, `TextTools.swift:52`);
   `set_value`'s checkbox path already no-ops when `current == desired`
   (`TextTools.swift:148-151`). These are exactly the verifier and the
   already-satisfied case — but ad hoc, per-tool, and not reflected in a
   machine-readable classification.
3. **Loud stale-target guard.** `resolveElement` (`Snapshot.swift:298`)
   re-resolves a generation-tagged id against the live tree, checks role+label
   identity, and throws a clear stale error. This is already BCU's `stateToken`
   guard (see §5).

### 1.2 What BCU does that we don't

BCU captures the **target element's own state before dispatch**, dispatches,
then **re-reads that specific element** (re-resolving it if it relocated) and
diffs field-level: `renderedTextChanged`, `selectionSummaryChanged`,
`focusedElementChanged`, `windowTitleChanged`, `targetStateChanged`
(selected/focused/value of the target). It reduces those booleans to a
four-value `classification` plus a `failureDomain`
(`Contracts/TextActionContracts.swift:3-17`,
`Actions/Click/ClickRouteService.swift:1258-1368`). Crucially the "after" reread
**never hard-errors** — a failed reread yields `verifier_ambiguous`, not an
exception (`verifyClick` tolerates `after == nil`,
`ClickRouteService.swift:1272-1297`).

### 1.3 The fix in one paragraph

Introduce a small `ActionOutcome` value type carrying a four-case
`classification`, an optional `failureDomain`, and a field-level `verification`
record. Give `stateResult` an optional "before" targeted capture and an "after"
targeted reread of the acted-on element, diff the fields that matter for the
action family, reduce to a classification, and emit it under a new
`computer-use-mcp/outcome` key in `_meta` — alongside, never replacing, the
existing `computer-use-mcp/focus` block. `isError` semantics are unchanged;
agents that ignore `_meta` see identical behavior. Verified failure
(`effect_not_verified`) is reported in `_meta` and in a human sentence in the
text body, but does **not** flip `isError` (see §5.3 for why).

---

## 2. The Swift types

New file: `Core/ActionOutcome.swift`. Everything is `Sendable` and `Encodable`
to `MCP.Value` (we don't use `JSONEncoder` on the wire — we build `Value`
objects by hand like `FocusTelemetry.value`).

### 2.1 Classification

```swift
/// The verifier's verdict on whether an action's intended effect occurred.
/// Mirrors BCU's ActionClassificationDTO. Serialized as the snake_case
/// rawValue.
enum ActionClassification: String, Sendable {
    /// The effect was observed, or the target was already in the requested
    /// state (idempotent no-op is a success, not a failure — see §3).
    case success

    /// The target cannot perform this action at all (disabled control, no
    /// settable value, unsupported AX action). Distinct from a verified
    /// failure: retrying won't help.
    case unsupported

    /// The action dispatched without error but no confirming effect was
    /// observed. This is the case today's contract silently reports as
    /// success. Retry (possibly at a higher delivery tier) may help.
    case effectNotVerified = "effect_not_verified"

    /// The action dispatched, but the verifier could not read enough state to
    /// judge (after-reread failed, target relocated unrecoverably, element has
    /// no observable fields). Never a hard error — the action may well have
    /// worked; we just can't prove it.
    case verifierAmbiguous = "verifier_ambiguous"
}
```

We keep BCU's exact four cases and wire strings so cross-tool telemetry lines
up with the reference. Note the deliberate asymmetry: `success` absorbs the
already-satisfied case, and `verifier_ambiguous` absorbs every "couldn't prove
it" case so the verifier itself can never manufacture a false failure.

### 2.2 Failure domain

```swift
/// Why an action did not reach `success`. nil when classification == .success.
/// Adapted from BCU's ActionFailureDomainDTO to our vocabulary.
enum FailureDomain: String, Sendable {
    /// The element id/coordinate could not be resolved to a live, matching
    /// target (stale id, relocated element, ambiguous descendant). Pairs with
    /// verifier_ambiguous, and with the existing stale-id throw path.
    case targeting

    /// The control cannot perform the action (disabled, no settable value,
    /// no AX action and no usable point). Pairs with unsupported.
    case unsupported

    /// The requested value could not be represented for this element
    /// (non-numeric string into a slider, un-parseable bool into a checkbox).
    /// Pairs with unsupported. (BCU: `coercion`.)
    case coercion

    /// The synthetic event was posted but likely dropped; the delivery tier
    /// is one an app can silently swallow. Pairs with effect_not_verified.
    /// (BCU: `transport`.)
    case transport

    /// Dispatch reported success but the reread showed no confirming change.
    /// Pairs with effect_not_verified. (BCU: `verification`.)
    case verification

    /// The app accepted the action but applied app-specific semantics that
    /// diverge from the request (clamped a window frame, snapped a slider to a
    /// step, auto-corrected typed text). Pairs with success OR
    /// effect_not_verified depending on whether the divergence defeats intent.
    /// (BCU: `app_specific_semantics`.)
    case appSpecificSemantics = "app_specific_semantics"
}
```

### 2.3 The verification record

The field-level evidence. Every field is optional so the same struct serves all
action families — a tool populates only what it can observe. Booleans are
three-valued (`Bool?`): `nil` = "not observed," which is distinct from `false` =
"observed, did not change."

```swift
/// Field-level before/after evidence for one action. All-optional so one type
/// covers click/type/set_value/scroll/window. nil means "not captured for this
/// action family," never "false."
struct ActionVerification: Sendable {
    // Target identity across the action (did it relocate? by what strategy?)
    var targetRelocated: Bool? = nil
    var refreshedTargetStrategy: String? = nil   // e.g. "locator-path", "focused-element"

    // Target-local field diffs (populated when we hold the acted-on element)
    var beforeValuePreview: String? = nil
    var afterValuePreview: String? = nil
    var beforeSelected: Bool? = nil
    var afterSelected: Bool? = nil
    var beforeFocused: Bool? = nil
    var afterFocused: Bool? = nil

    // Whole-window observations (available even for coordinate clicks)
    var renderedTextChanged: Bool? = nil     // from the existing treeFingerprint bit
    var focusedElementChanged: Bool? = nil   // window's AXFocusedUIElement moved
    var windowTitleChanged: Bool? = nil
    var windowFrameChanged: Bool? = nil      // window family only
    var scrollPositionChanged: Bool? = nil   // scroll family only

    // Derived: any target-local field moved
    var targetStateChanged: Bool? = nil

    /// Human-readable trail, appended by each predicate. Never load-bearing for
    /// the classification — that's computed from the booleans.
    var notes: [String] = []
}
```

`_valuePreview` is the same truncated, secure-field-aware preview
`readBackWarning` already uses; reuse `axString(element, kAXValueAttribute)`
with the existing secure-subrole and length guards (`TextTools.swift:52-59`) so
we never echo a password field.

### 2.4 The outcome envelope

```swift
struct ActionOutcome: Sendable {
    let classification: ActionClassification
    let failureDomain: FailureDomain?      // nil iff classification == .success
    let summary: String                    // one human sentence
    let verification: ActionVerification?

    var isSuccess: Bool { classification == .success }
}
```

### 2.5 The `_meta` JSON shape

The outcome rides in its own top-level `_meta` key, `computer-use-mcp/outcome`,
next to the existing `computer-use-mcp/focus`. Both are built as `MCP.Value`
objects and merged into `result._meta.fields`, exactly the pattern
`withFocusTelemetry` already uses (`FocusTelemetry.swift:146-153`). We add a
sibling `withActionOutcome(_:)`.

```jsonc
"_meta": {
  "computer-use-mcp/focus": {            // UNCHANGED — existing block
    "focus_changed": false,
    "focus_change_allowed": false,
    "cursor_movement_allowed": false,
    "delivery_tier": "tier1-ax-action",  // stays here (see §6 for the merge plan)
    "ui_changed": true,
    "frontmost_before": { "...": "..." },
    "frontmost_after":  { "...": "..." }
  },
  "computer-use-mcp/outcome": {          // NEW block
    "classification": "success",
    "failure_domain": null,              // omitted when null
    "summary": "Checkbox \"Remember me\" is now checked.",
    "verification": {
      "target_relocated": false,
      "target_state_changed": true,
      "before_selected": false, "after_selected": true,
      "rendered_text_changed": true,
      "window_title_changed": false,
      "notes": ["Target value evidence changed after click."]
    }
  }
}
```

Serialization rules, matching `FocusTelemetry.value`'s style: emit a key only
when its source is non-nil (so `verifier_ambiguous` outcomes with no
verification simply omit `verification`); booleans emit as `.bool`; the
`classification`/`failure_domain` emit their snake_case rawValue as `.string`.

---

## 3. Read–act–read mechanics

### 3.1 Where the three phases live

Today `stateResult` does only the *final* read. We split the action tools into
an explicit read→act→read shape. The cleanest seam: the handler already holds
the resolved live target (`target.element`, an `AXUIElement`) *before* it
dispatches. So:

- **Read (before):** the handler captures the target element's fields into an
  `ActionVerification` seed *before* calling `deliverClick`/`performAXAction`/
  `AXUIElementSetAttributeValue`. This is a handful of AX attribute reads on one
  element — cheap, no tree walk. For coordinate-only clicks (no element) the
  before-target fields stay `nil` and we lean on the whole-window bit.
- **Act:** unchanged dispatch.
- **Read (after):** `stateResult` already re-perceives the whole window. We
  extend it to *also* re-resolve the acted-on element via its locator and read
  the same fields, then compute the diff and the classification.

To thread this without rewriting every handler signature, `stateResult` gains
two optional parameters:

```swift
func stateResult(
    app: ResolvedApp,
    windowTitle: String?,
    note: String? = nil,
    screenshot detail: ScreenshotDetail = .reduced,
    scope: TreeScope? = nil,
    maxElements: Int = defaultMaxTreeElements,
    ocr: Bool = false,
    focusTelemetry: FocusTelemetry? = nil,
    // NEW:
    verifier: ActionVerifier? = nil            // captures before-state + reduces
) async throws -> CallTool.Result
```

`ActionVerifier` is a small struct the handler builds pre-dispatch:

```swift
struct ActionVerifier: Sendable {
    let family: ActionFamily          // .click / .type / .setValue / .scroll / .window / .menu
    let target: ResolvedTarget?       // the element + its snapshot locator, nil for coordinate clicks
    let before: ActionVerification    // captured before dispatch
    let intent: ActionIntent          // e.g. .toggle(to: true), .setText("foo"), .setFrame(rect)
    let dispatchSucceeded: Bool       // did the AX call / event post return success?
    let deliveryTier: InputTier
}
```

The handler: build `before` via `ActionVerifier.captureBefore(target:family:)`,
dispatch, set `dispatchSucceeded`, pass the verifier to `stateResult`.
`stateResult` then re-resolves the target, captures `after`, and calls
`verifier.reduce(after:wholeWindow:)` to produce the `ActionOutcome`.

### 3.2 Fields diffed per action family

The "after" reread re-resolves the acted-on element with the **existing**
`resolveElement` (`Snapshot.swift:298`), which already retries for up to 1s and
enforces role+label identity. If it returns an element, we read the family's
fields; if it throws (relocated/gone), we do **not** propagate the throw — we
record `targetRelocated: true`, leave `after*` fields `nil`, and fall back to
the whole-window bit. Reread failure ⇒ at worst `verifier_ambiguous`.

| Family | Before/after target fields | Whole-window fields | Primary success signal |
|---|---|---|---|
| **click** | `value`, `selected`, `focused` | `renderedTextChanged`, `focusedElementChanged`, `windowTitleChanged` | any target field changed OR any window bit changed |
| **type_text** | `value`, `focused` | `renderedTextChanged` | `after.value` contains the inserted text (reuses `typedTextWarning`) |
| **set_value** | `value` (numeric-aware), `selected` for toggles | `renderedTextChanged` | `after.value` equals requested (or toggle reached desired) |
| **scroll** | — (container) | `scrollPositionChanged` (AXScrollBar value or first-visible-child identity), `renderedTextChanged` | scroll position moved OR visible children changed |
| **manage_window** | — | `windowFrameChanged` (AXPosition/AXSize) | frame reached requested within tolerance (§3.4) |
| **click_menu_item** | — | `renderedTextChanged`, `focusedElementChanged` | tree changed after the menu action fired |

Scroll's "visible children changed" uses the same `treeFingerprint` machinery
scoped to the scroll container — no new capture primitive. Window frame diff
reads `AXPosition`/`AXSize` on the window element (already read in
`manageWindowImpl`, `SystemTools.swift:226-234`).

### 3.3 How "after" tolerates failure

The single rule, applied everywhere: **a reread problem degrades the
classification, it never throws.** Concretely:

1. `resolveElement` throws (stale/relocated) → catch inside the verifier,
   `targetRelocated = true`, target fields `nil`. If the whole-window bit shows
   a change consistent with intent → still `success`; else →
   `verifier_ambiguous` (domain `targeting`), *not* `effect_not_verified`,
   because we genuinely could not observe.
2. The element resolves but exposes none of the family's fields (e.g. a custom
   view with no AXValue) → target fields `nil`, `verifier_ambiguous`.
3. The whole-window recapture itself fails (screenshot/AX error — already
   handled by `stateResult`'s existing `captureNote` path) → `verifier_ambiguous`.

The only path to `effect_not_verified` is: **dispatch succeeded, reread
succeeded, and every relevant field shows no change.** That is the one case we
must stop reporting as success.

### 3.4 Semantic tolerance (`app_specific_semantics`)

Some apps legitimately transform the request. Window managers clamp frames to
the visible screen; sliders snap to steps; text fields auto-format. These are
not failures. Rule:

- If the observed after-value is *within tolerance* of the request (frame
  within N px of requested after clamping to screen bounds; slider at the
  nearest step; text field value differs only by known auto-format) →
  `success`, `failureDomain: nil`, and a `verification.notes` entry recording
  the divergence. (Window-motion clamping detection is the parallel Wave-2
  window-verify task #6; this contract just consumes its "clamped vs failed"
  signal.)
- If the after-value diverges *beyond* tolerance (window didn't move at all;
  slider unchanged) → `effect_not_verified`, domain `verification`.

---

## 4. Per-tool verification predicates — the false-success trap matrix

This is the crux. Each row is a real situation where naive "did the tree
change?" or "did the AX call succeed?" gives the wrong verdict. The predicate
column is what the verifier must actually check.

### 4.1 Click

| Scenario | Naive verdict | Correct classification | Predicate |
|---|---|---|---|
| Button press, dialog opens | change → success ✓ | `success` | window title changed OR focused element changed OR rendered text changed |
| Checkbox toggle off→on | change → success ✓ | `success` | `before.selected(false) != after.selected(true)` (target field, not whole tree) |
| **Checkbox already checked, click to "check"** | AX press succeeds → success ✗ | `success` (already-satisfied) | if `intent == .toggle(to: v)` and `before.value == v`, skip dispatch, classify `success` with note "already in requested state" (this is `set_value`'s existing line 148 logic, generalized) |
| **Liar button (fires nothing)** | AX press `.success` → success ✗ | `effect_not_verified` (verification) | dispatch ok, reread ok, no target field changed, no window bit changed |
| **Click a focused text field (legit no-op visual)** | no tree change → false failure ✗ | `success` | `after.focused == true` — focus/caret is the effect; focus being (or staying) on target is success for a focus-intent click |
| **Idempotent radio already selected** | change/no-change ambiguous | `success` (already-satisfied) | same as checkbox: `before.selected == true` for the requested option |
| **Disabled button** | AX press returns error → throws today | `unsupported` (unsupported) | detect `AXEnabled == false` before dispatch → classify `unsupported`, do not dispatch. If discovered only via AX error, map that error to `unsupported` not a raw throw |
| Coordinate click, no element | tree change → success | `success` if window bit changed, else `verifier_ambiguous` | no target fields to read; rely on `renderedTextChanged`/focus/title; absence ⇒ ambiguous (could be a legit invisible effect), NOT effect_not_verified |
| Click that scrolls content into view | tree change → success | `success` | rendered text changed |
| Background NSEvent dropped by app | no change, no error → success ✗ | `effect_not_verified` (transport) | dispatch tier is droppable (`isDroppableBackgroundDeliveryTier`) AND no field/window change → domain `transport` (retry at higher tier may help), distinct from `verification` |

The two subtle wins: **already-satisfied → `success`** (never punish the agent
for a correct no-op) and **focused-field click → `success`** (focus is a valid,
often invisible, effect). The two subtle catches: **liar button →
`effect_not_verified/verification`** and **dropped background event →
`effect_not_verified/transport`** — same classification, different domain, so
the agent knows whether escalating the delivery tier is worth trying.

### 4.2 type_text

| Scenario | Correct classification | Predicate |
|---|---|---|
| Text inserted, value reflects it | `success` | `after.value` contains the inserted substring (reuse `typedTextWarning`, `TextTools.swift:64`) |
| Value unchanged after AX write reported success (app ignored it) | `effect_not_verified` (verification) | `after.value == before.value` and doesn't contain inserted text |
| Secure field | `success` if focused & no error (can't read back) → but `verifier_ambiguous` if we truly can't confirm | never read the value (existing secure-subrole guard); rely on focus + no-error; if no confirmable signal → `verifier_ambiguous`, note "secure field, value not observable" |
| Typed into a field that auto-formats (phone, currency) | `success` + `app_specific_semantics` note | `after.value` differs from raw input but contains the digits/core → within tolerance |
| No focused element, no element_id | throws today (invalid args) | keep as thrown `invalidArguments` (pre-dispatch arg error, not an outcome) |
| Field rejects (read-only masquerading as editable) | `effect_not_verified` (verification) | value unchanged |

### 4.3 set_value

| Scenario | Correct classification | Predicate |
|---|---|---|
| Slider set to in-range value | `success` | `after.value` ≈ requested (numeric compare with epsilon) |
| Slider snaps to nearest step | `success` + `app_specific_semantics` | after within one step of requested |
| Non-numeric string into numeric element | `unsupported` (coercion) | detect at coercion (`TextTools.swift:174`); today it silently sends the string — instead classify `unsupported/coercion` |
| Checkbox already in desired state | `success` (already-satisfied) | existing `current != desired` guard at `TextTools.swift:149` → when equal, `success` with note |
| Element not settable | `unsupported` (unsupported) | existing `AXUIElementIsAttributeSettable == false` throw (`TextTools.swift:160`) → classify `unsupported` instead of raw throw |
| Set succeeded per AX, value unchanged on reread | `effect_not_verified` (verification) | `after.value != requested` |

### 4.4 scroll

| Scenario | Correct classification | Predicate |
|---|---|---|
| Scroll moves content | `success` | scroll position changed OR container's visible-children fingerprint changed |
| **Scroll at end of content (can't scroll further)** | `success` (already-satisfied) | before/after scroll position both at max/min → note "already at extent," `success` (asking to scroll past the end is not a failure) |
| Scroll on a non-scrollable container | `unsupported` (unsupported) | no AXScrollBar / no scrollable ancestor found (this pairs with Wave-2 scroll task #7's container ranking) |
| Scroll event dropped (background tier) | `effect_not_verified` (transport) | droppable tier AND no position/children change AND not already at extent |

The already-at-extent case is scroll's version of already-satisfied and is easy
to get wrong: no change looks like a dropped event. Distinguish by reading
whether the scroll position is already pinned at the boundary.

### 4.5 manage_window

| Scenario | Correct classification | Predicate |
|---|---|---|
| Move/resize to a valid frame | `success` | after frame ≈ requested within px tolerance |
| Frame clamped to screen | `success` + `app_specific_semantics` | after frame == requested-clamped-to-visible-bounds |
| Window refuses to move (fixed-size dialog) | `effect_not_verified` (verification) | after frame == before frame, ≠ requested |
| Minimize/zoom/fullscreen toggle already in that state | `success` (already-satisfied) | before state == requested |

Window verification depends on the settle-poll + clamp detection from task #6;
this contract defines the *classification*, that task provides the *observed
frame after settling*.

### 4.6 click_menu_item and perform_secondary_action

| Scenario | Correct classification | Predicate |
|---|---|---|
| Menu item fires, UI changes | `success` | rendered text or focused element changed after the action |
| Menu item is a no-op toggle already in state (e.g. "Show Sidebar" already shown) | `verifier_ambiguous` | menu items rarely expose readable state; if no window change and we can't read the item's mark → ambiguous, note it |
| Menu item disabled | `unsupported` (unsupported) | `AXEnabled == false` on the item |
| Secondary action (right-click / AXShowMenu) opens context menu | `success` | a menu element appeared in the tree (focused element / new AXMenu) |

Menus are the family most prone to `verifier_ambiguous`, and that's correct:
menu semantics are frequently unobservable via AX, and we must not fabricate
either success or failure. Ambiguous-but-dispatched is the honest answer.

### 4.7 The decision procedure (pseudocode)

```
reduce(before, after, family, intent, dispatchSucceeded, deliveryTier) -> ActionOutcome:
  # 1. Pre-dispatch already-satisfied (checked BEFORE dispatch, short-circuits)
  if intent.isSatisfiedBy(before):
      return .success(note: "already in requested state")

  # 2. Pre-dispatch unsupported (disabled / not settable / coercion) — also pre-dispatch
  if target.unsupported(intent):
      return .unsupported(domain: .unsupported | .coercion)

  # 3. Post-dispatch, reread failed to observe
  if after == nil or after.hasNoObservableFields:
      # did the whole window move in a way consistent with intent?
      if wholeWindowChangedConsistentWith(intent): return .success
      return .verifierAmbiguous(domain: .targeting)

  # 4. Post-dispatch, reread succeeded
  if intent.satisfiedBy(after) within tolerance:
      note any app_specific_semantics divergence
      return .success
  if anyRelevantFieldChanged(before, after) but not toward intent:
      return .effectNotVerified(domain: .verification)   # something happened, not what we asked
  # nothing changed at all
  if deliveryTier.isDroppable:
      return .effectNotVerified(domain: .transport)      # likely dropped, retry higher tier
  return .effectNotVerified(domain: .verification)        # AX said ok, nothing moved: liar
```

Steps 1 and 2 run **before** dispatch (they can skip it entirely); steps 3–4
run after the reread.

---

## 5. Pre-dispatch stale-target guard

### 5.1 We already have BCU's stateToken, by another name

BCU guards against acting on a stale target by comparing a supplied
`stateToken` against a live recapture and warning on mismatch
(`AXActionTargetResolver.stateTokenWarnings`,
`Resolver.swift:172-183`); its element resolution can also relocate a target and
report `refreshedTargetMatchStrategy`.

Our equivalent is stronger and already in place: **generation-tagged element
ids** (`e12@s3`). `resolveElement` (`Snapshot.swift:298-324`) re-resolves the
locator path against the live tree and enforces role+label identity, throwing a
loud, actionable stale error ("The UI has changed since that state was
captured — call get_app_state and use a fresh element id"). Text-entry roles
already relax the label check because their labels churn with content
(`elementIdentityMatches`, `Snapshot.swift:350-357`; see the macOS-API-gotchas
memory).

### 5.2 What changes: almost nothing, by design

The pre-dispatch guard stays exactly as is — a **hard throw** on a stale id is
the correct behavior and must not be softened into a classification. Acting on
the wrong element is worse than not acting. So:

- **Pre-dispatch stale id → keep throwing** (`isError: true`). Not an
  `ActionOutcome`. The id the agent passed no longer identifies a real control;
  there is nothing to verify.
- **Post-dispatch relocation → soft.** The distinction: before dispatch, a
  relocated/stale target means we might act on the wrong thing (dangerous, must
  fail). *After* dispatch, the action already happened; if the element then
  relocated (common — the action itself caused a relayout), that's expected and
  we re-resolve to read the after-state. Only here do we record
  `targetRelocated`/`refreshedTargetStrategy` and tolerate failure as
  `verifier_ambiguous`.

The one addition: record the pre-dispatch generation into
`verification.notes` (e.g. "target resolved from generation s3") so the outcome
is self-describing, and set `refreshedTargetStrategy = "locator-path"` on the
after-reread since that's the only strategy we use. No new token type, no new
guard — our generation tag *is* the token.

### 5.3 isError stays reserved for structural failure

`effect_not_verified` and `verifier_ambiguous` must **not** set `isError`.
Reasons:

1. **Backward compatibility.** Agents keying off `isError` today treat it as
   "the tool refused / crashed." A verified no-effect click is a different
   thing — the tool ran fine, the world just didn't change. Flipping `isError`
   would break every existing agent's control flow (§7).
2. **The effect might still have happened.** `verifier_ambiguous` explicitly
   means "can't prove it." Erroring on ambiguity would make the tool unusable on
   the many controls with unobservable AX state.
3. **The signal belongs in `_meta`.** Agents that want verifier-first behavior
   read `computer-use-mcp/outcome.classification`; agents that don't are
   unaffected. `isError` remains: thrown exception = true, everything else =
   false — unchanged from `Dispatch.swift:54`.

The human-readable text body *does* change: for non-success classifications,
`stateResult` prepends a sentence ("No confirming change was observed after this
click; the app may have ignored it.") so a human reading the transcript sees it
even without parsing `_meta`. This reuses the existing `droppedEventHint`
channel (`Perception.swift:322`), generalized.

---

## 6. Interaction with Wave-1 DeliveryOutcome telemetry

Wave-1 (task #1, in progress) is adding fallback-delivery telemetry —
`DeliveryOutcome { tier, fallbackReasons }` — capturing which delivery tier
actually landed the event and why we fell back down the ladder. It doesn't
exist in the tree yet; today `delivery_tier` is a lone string inside the focus
block (`FocusTelemetry.swift:77-79`).

**These are two halves of one story and must share one `_meta` block.** Delivery
telemetry answers *"how did we try to make it happen"*; the outcome contract
answers *"did it happen."* Proposed unified `_meta`:

```jsonc
"computer-use-mcp/focus":   { focus_changed, frontmost_before/after, ... }  // identity/focus only
"computer-use-mcp/delivery":{ tier, fallback_reasons: [...], ui_changed }   // Wave-1 owns; ui_changed moves here
"computer-use-mcp/outcome": { classification, failure_domain, summary, verification }  // this doc
```

Recommendation (an open question for the orchestrator, §9): **move
`delivery_tier` and `ui_changed` out of the focus block into a new
`computer-use-mcp/delivery` block** that Wave-1 owns, leaving `focus` to mean
strictly frontmost-app identity. The outcome block's `verification` then
*references* delivery for its `transport`-domain decision (a
`transport`-domain `effect_not_verified` is exactly "delivery landed at a
droppable tier AND outcome saw no change"). If Wave-1 ships first and keeps
`delivery_tier` in `focus`, this contract still works — the verifier reads the
tier wherever it lives via a single accessor. The coupling is: **the verifier
needs to know the final delivery tier to choose `transport` vs `verification`
domain.** Coordinate so that accessor exists.

Concretely, to keep the two workers unblocked: define a tiny shared read
`func finalDeliveryTier(_ result) -> InputTier?` that both blocks feed from, so
neither worker hard-codes the other's JSON path.

---

## 7. Backward compatibility

1. **`isError` unchanged.** Thrown → true; otherwise false (§5.3). No agent
   control flow keyed on `isError` changes behavior.
2. **`_meta` is additive.** `computer-use-mcp/outcome` is a new key. Agents that
   don't read it are unaffected; MCP `_meta` is explicitly a bag of optional
   metadata.
3. **Text body is additive-then-neutral.** For `success` the note is what it is
   today. For non-success we prepend one sentence — visible to humans, ignorable
   by machines. No existing sentence is removed or reworded (tests that assert
   note text stay green; new tests assert the added sentence).
4. **The focus block is preserved byte-for-byte** unless §6's `delivery` split
   is adopted, which is a coordinated Wave-1/Wave-2 change with its own tests.
5. **Read-only tools stay unverified.** `get_app_state`, `find`, `read_text`,
   `read_clipboard`, `list_apps`, `list_windows`, `wait_for` never produce an
   `outcome` block — there's no effect to verify. Only the `appScopedToolNames`
   mutating set (`ToolSpec.swift:30-34`) plus `open_app`/`open_url` opt in.

---

## 8. Rollout plan

Sequenced so each tool is a self-contained, independently shippable PR, and the
riskiest reduction logic (click) is proven first on the fixture.

1. **`Core/ActionOutcome.swift` + `stateResult` plumbing.** Land the types,
   `ActionVerifier`, `withActionOutcome`, and the optional `verifier:` param —
   with *no* tool wired yet. Pure addition, no behavior change. Unit-test the
   reducer in isolation (§9) with synthetic before/after records.
2. **`click`** (`ClickTool.swift`). The reference implementation and the hardest
   matrix (§4.1). Prove every row against the fixture's liar button, disabled
   button, pre-checked checkbox before moving on.
3. **`set_value`** — smallest delta; the already-satisfied and coercion cases
   are half-built (`TextTools.swift:143-183`). Formalize them into the contract.
4. **`type_text`** — reuse `typedTextWarning` as the predicate; wire the secure
   field → `verifier_ambiguous` path.
5. **`scroll`** — needs the extent detection; coordinate with scroll task #7's
   container ranking (share the container resolution).
6. **`manage_window`** — depends on window-verify task #6 for the settled frame;
   this contract consumes its clamp/settle signal.
7. **`click_menu_item`, `perform_secondary_action`, `drag`** — highest
   `verifier_ambiguous` rate; land last, accept ambiguity as the honest default.

**Stays unverified:** all read-only tools (§7.5); `press_key` with no target
element (global key — nothing to reread; may still get whole-window `ui_changed`
but no `outcome` block); `write_clipboard`/`read_clipboard`; skill record/replay
tools (`run_skill` verifies per-step through the tools it drives, not as a unit).
`batch` aggregates: it surfaces each sub-action's `outcome` in an array under its
own `_meta`, and the batch's own classification is `success` iff every sub-action
is `success`/`verifier_ambiguous` (no `effect_not_verified`).

---

## 9. Test plan

### 9.1 Deterministic unit tests (no UI, pure reducer)

The reducer (`ActionVerifier.reduce`) is a pure function of
`(before, after, family, intent, dispatchSucceeded, deliveryTier)`. Test it with
hand-built records — one test per matrix row in §4. These are fast, hermetic,
and the primary regression guard. Key cases that must be locked:

- checkbox already-checked → `success` (not `effect_not_verified`)
- liar button (dispatch ok, no change) → `effect_not_verified/verification`
- dropped background event (droppable tier, no change) →
  `effect_not_verified/transport`
- focused-field click (no visual change, `after.focused == true`) → `success`
- reread-failed (`after == nil`) with consistent window change → `success`
- reread-failed with no window change → `verifier_ambiguous/targeting`
- disabled control → `unsupported/unsupported`
- non-numeric into slider → `unsupported/coercion`
- slider snap-to-step → `success` + `app_specific_semantics` note
- scroll at extent → `success` (already-satisfied)

### 9.2 Truth-suite fixture (task #2, parallel worker)

The fixture app being built (task #2) has exactly the adversarial controls this
contract exists to catch. Map each to an end-to-end assertion:

| Fixture control | Tool | Asserted classification |
|---|---|---|
| **Liar button** (reports success, does nothing) | click | `effect_not_verified` / `verification` |
| **Disabled button** | click | `unsupported` / `unsupported` |
| **Pre-checked checkbox** (set to checked) | set_value / click | `success` (already-satisfied) |
| **Clamping window** (refuses frames past screen) | manage_window | `success` + `app_specific_semantics` |
| Honest button (opens a panel) | click | `success` |
| Real text field | type_text | `success`; then read-only field → `effect_not_verified` |

The fixture E2E suite is the proof that the reducer's classifications match
reality — the unit tests prove the logic, the fixture proves the *observations*
feeding it are correct (before/after capture reads the right fields).

### 9.3 Regression

Existing tool tests must stay green: assert `isError` never changes for any
current passing case, and that success-path note text is unchanged (§7.3).

---

## 10. Latency

The added cost per mutating call is: one before-capture (a few AX attribute
reads on a single element) + one after-reread of that same element. The
whole-window recapture in `stateResult` is **already paid today** — we're not
adding a tree walk, only reading ~4 attributes on one element twice.

Budget: target ≤25% median overhead on mutating calls. Levers:

1. **Reuse the existing final read.** The after-window capture is not new; the
   after-*target* fields are read from the element we already re-resolve. Net
   new work is the before-capture (~4 AX reads) + field diffs (in-memory).
2. **`include_state: false` fast path.** When the caller sets
   `screenshot: .noState`/`detail == .noState` (`Perception.swift:141`),
   `stateResult` returns early without any recapture. The verifier must honor
   this: with no after-read, emit `verifier_ambiguous` with a note "state
   verification skipped (include_state=false)" rather than paying for a reread.
   This keeps the fast path fast and honest.
3. **Skip before-capture for coordinate clicks** (no element) — nothing to read.
4. **Cap the value preview** at the existing truncation length so large text
   fields don't blow up the diff (reuse `readBackWarning`'s 200k guard,
   `TextTools.swift:54`).

Measure with the existing `Telemetry` timing (`Dispatch.swift:58`) across the
fixture suite: compare median mutating-call duration with the verifier on vs
off (a build flag during rollout). If a family exceeds budget, its before/after
field set is the thing to trim.

---

## Appendix: file-by-file change map

| File | Change |
|---|---|
| `Core/ActionOutcome.swift` | **new** — `ActionClassification`, `FailureDomain`, `ActionVerification`, `ActionOutcome`, `ActionVerifier` (capture + reduce), `.value` serializers, `withActionOutcome` |
| `Tools/Perception.swift` | `stateResult` gains `verifier:` param; runs after-reread; prepends non-success sentence; honors `noState` fast path |
| `Tools/ClickTool.swift` | build verifier pre-dispatch; already-satisfied + disabled pre-checks; pass to `stateResult` |
| `Tools/TextTools.swift` | set_value/type_text: formalize existing readback into the contract; coercion → `unsupported` |
| `Tools/InputTools.swift` | scroll: extent detection + verifier |
| `Tools/SystemTools.swift` | manage_window: consume settle/clamp signal from task #6 |
| `Tools/BatchTool.swift` | aggregate sub-outcomes |
| `Core/FocusTelemetry.swift` | (if §6 split adopted) move `delivery_tier`/`ui_changed` to new `delivery` block |
| `Tests/…` | reducer unit tests (§9.1); fixture E2E (§9.2); regression guards (§9.3) |
</content>
</invoke>
