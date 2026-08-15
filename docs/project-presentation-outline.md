# computer-use-mcp Project Presentation Outline

> Working presentation notes, not the final script.
>
> Current-source baseline: local `main` at `1c6e96e` (2026-08-08,
> `Propagate daemon connection cancellation`). Reverify implementation claims
> if the branch changes. The presentation uses a logical product/design
> evolution rather than a commit-by-commit history. Historical details may be
> reconstructed from the architecture and the author's recollection, but should
> not be presented as measured incidents or exact chronology when they are not.

## Preparation workflow and depth boundary

1. Define every slide's purpose and most important points before drafting any
   speaker language.
2. Proctor one architecture phase at a time at presentation depth.
3. Correct only material mental-model or design-story mistakes.
4. After all slides are understood and outlined, draft the presentation in the
   presenter's natural voice.
5. Revisit implementation internals only where they strengthen the draft or are
   likely interviewer follow-ups.

Keep the first pass focused on product problem, architecture, reliability, and
trade-offs. File-descriptor numbering, accept/reader-thread mechanics,
`NSCondition`, and actor reentrancy belong in optional follow-up notes rather
than the main presentation.

## Presentation contract

- Interview format: 45-minute technical deep dive with required slides.
- Talk target: 25-30 minutes, leaving 15-20 minutes for discussion.
- Audience: engineers familiar with computer use, likely from the Codex
  computer-use team.
- Deck limit: no more than 12 slides; the first draft uses all 12 so OpenBench
  has a complete measurement-gap → evaluation-design → measured-result arc.
- Narrative: show the current system early, then use prior designs only where
  they explain an important current decision or trade-off.
- Central thesis: a solo macOS computer-use project evolved from a useful
  agent capability into a multi-agent, transaction-oriented, measurable system.

## Story spine

1. **Why computer use:** extend coding agents beyond code and APIs into
   professional workflows, in a future with multiple agent harnesses.
2. **What exists today:** demonstrate multiple agents operating different apps
   in the background, then show the current architecture.
3. **How the core works:** semantic perception and durable targeting, followed
   by evidence-based action delivery and verification.
4. **How it became multi-agent:** centralize coordination in a daemon, introduce
   logical session/operation identity, and serialize app mutations.
5. **How it becomes production-ready:** expose honest outcomes, measure the
   system through OpenBench, make a controlled improvement, and rerun the same
   evaluation.

## Technical depth contract

The main presentation has exactly three technical deep dives:

1. **Perception and live targeting:** AX hierarchy construction,
   ScreenCaptureKit context, snapshots, retained AX handles, and stale target
   detection.
2. **One evidence-backed mutation:** follow one concrete click from the
   model-selected element through live resolution, before evidence, semantic AX
   delivery, guarded Core Graphics fallback, observed effect, snapshot commit,
   and diff response.
3. **Multi-agent correctness:** singleton daemon election with `flock`, logical
   session and operation identity, idempotent retries, and per-app FIFO mutation
   coordination.

Slides 5–6 form one continuous example rather than two disconnected subsystem
tours. Slides 7–8 explain why the working single-agent path had to evolve for
multiple agents. Metrics and OpenBench prove the design; they are not a fourth
architecture deep dive.

## Slide sequence and timing

1. **Project introduction** (0.5 min) — solo ownership, duration, and thesis.
2. **Why computer use?** (1.5 min) — feedback loops, product gap, and future
   professional-work vision.
3. **Product demo** (1 min) — multiple harnesses, different apps, background
   actions, and distinct overlay cursors.
4. **Current system architecture** (2 min) — MCP shims, shared daemon,
   snapshots, app coordination, macOS services, target apps, and OpenBench.
5. **Deep dive: perception and durable targeting** (4 min) — AX APIs,
   ScreenCaptureKit, tree construction, in-memory snapshots, element IDs, and
   retained AX handles.
6. **Deep dive: one mutation end to end** (4.5 min) — resolve, gate, capture,
   AX-first delivery, Core Graphics fallback, verification, snapshot commit,
   and diff response.
7. **Why the action pipeline needed one coordinator** (2.5 min) — connect the
   current architecture back to the multi-agent failure that required a daemon
   and singleton election.
8. **Deep dive: multi-agent correctness** (5 min) — `flock`, logical sessions,
   operation IDs, idempotency, app-scoped ownership, FIFO ordering, and the
   queue-versus-heartbeat trade-off.
9. **Why operational metrics were not enough** (1.5 min) — metrics exposed cost
   and failure modes but could not independently judge task success.
10. **OpenBench computer-use evaluation** (2.5 min) — deterministic fixture
    tasks, exact-call ledgers, external checkers, and controlled variants.
11. **Evidence-driven improvement loop** (3 min) — baseline, hypothesis,
    matched A/B, measured result, limitation, and next experiment.
12. **Learnings and next steps** (1.5 min) — broader evals, incremental AX
    perception, and Windows support.

The quantitative close should come from the OpenBench before/after cases rather
than GitHub popularity or adoption proxies that do not strengthen the technical
story.

The opening demo is presenter-owned. It should show a real workflow, ideally in
45-60 seconds, with multiple agent harnesses operating different apps in the
background. The deterministic fixture appears later as evaluation evidence,
not as the opening product demo.

## First bullet draft — authoritative slide content

These headings match the agreed presentation structure. Each slide has a simple
title, its narrative job, and the concrete points to cover in the first spoken
draft.

### Slide 1 — Project introduction

**Slide title:** Computer Use MCP

**Job:** Establish the project context and technical thesis in under 30 seconds.

- Solo project built end to end over several months.
- The project gives local agent harnesses a common MCP interface for observing
  and operating macOS applications.
- Thesis for the talk: I evolved one useful agent-control loop into a shared,
  coordinated, and measurable multi-agent system.

### Slide 2 — Why computer use?

**Slide title:** Why computer use?

**Job:** Explain both the immediate motivation and the longer-term product
vision without turning the opening into a market lecture.

- My initial motivation was software feedback: an agent should be able to run
  the product it built, interact with it like a user, observe the result, and
  continue iterating rather than stopping after code generation or internal
  tests.
- The larger opportunity is professional work. Most of it still lives behind
  normal desktop interfaces, so computer use can automate workflows across
  settings, productivity apps, finance, operations, support, and other existing
  software without requiring every user to become technical or learn APIs.
- My firsthand product gap: the harnesses I used—such as Devin, Cursor, Claude
  Code, and Pi—either lacked local computer use entirely or exposed something
  too limited or unreliable for my daily workflows. This is a scoped personal
  observation, not a universal market claim.
- I expect a multi-harness future: users will choose different agents and
  models for different tasks, but all of them need a reliable way to observe
  and operate the local computer.
- Personal vision: as model reasoning and computer-use speed improve, agents
  will perform an increasing amount of professional work faster than humans can
  operate the computer manually. Spreading awareness and making the interface
  dependable is especially important for non-technical users who have barely
  used agents—and often have not encountered computer use at all.

### Slide 3 — Product demo

**Slide title:** Demo

**Job:** Prove the product outcome before explaining implementation.

- Show a 45–60 second recorded workflow with two agent harnesses operating two
  different applications while I continue working in the foreground.
- Make the per-session overlay cursors visually obvious so the audience can see
  which agent is acting and where.
- Show useful work rather than isolated button clicks: for example, one agent
  inspects system settings while another drafts content in Notes.
- Narration stays outcome-focused: one common interface, background-friendly
  interaction, multiple agents, and visible accountability.
- Do not explain daemon election, snapshots, or transport during the demo; the
  next slide reveals the system behind it.

### Slide 4 — Current system architecture

**Slide title:** Current system architecture

**Job:** Give the audience a complete map of the current system before zooming
into its three hardest parts.

- **Agent layer:** Claude Code, Cursor, Devin, Pi, or another MCP-capable harness
  discovers the same tool contract.
- **MCP edge:** each harness launches a small stdio serve shim that forwards
  requests rather than owning independent automation state.
- **Shared daemon:** one per-user engine owns dispatch, safety gates, app
  resolution, perception, action delivery, verification, logical sessions,
  operation deduplication, and per-app mutation coordination.
- **Snapshot subsystem:** `SnapshotStore` keeps one current in-memory state per
  process/window, including window lineage, semantic elements, live AX handles,
  frames, stable IDs, generations, and tree diffs.
- **Platform layer:** AppKit and `NSRunningApplication` resolve GUI apps;
  Accessibility supplies semantic hierarchy and actions; ScreenCaptureKit
  supplies aligned pixels; Core Graphics supplies guarded synthetic input when
  semantic actions are insufficient.
- **Visible UX:** a separate optional overlay process renders per-session agent
  cursors; it is explanatory UX, not the source of input correctness.
- **Evidence boundary:** structured metrics describe internal behavior, while
  OpenBench tasks and deterministic checkers judge the externally observable
  result.
- Diagram emphasis: several harnesses converge on one daemon; snapshots and the
  app coordinator live inside that shared authority; target apps and OpenBench
  sit on opposite sides as execution surface and independent evidence surface.

### Slide 5 — Deep dive 1: perception and durable targeting

**Slide title:** How the agent understands the computer

**Job:** Explain concretely how the LLM sees the computer and how a temporary
macOS object becomes a target that can be used in a later call.

- A `get_app_state(app, window?)` request first resolves the GUI app to a PID
  and `NSRunningApplication`, then creates an accessibility proxy with
  `AXUIElementCreateApplication(pid)`.
- Window selection reads accessibility attributes such as `AXWindows`,
  `AXFocusedWindow`, and `AXMainWindow`. The snapshot records a stronger lineage
  for later mutation safety: PID, bundle ID, process start time, and the selected
  `CGWindowID`. This prevents a reused PID, restarted app, or replacement window
  from inheriting an old target silently.
- ScreenCaptureKit captures that exact window. AX frames are reported in global
  points, so the system aligns them with the captured image's pixels using the
  window origin and pixels-per-point scale.
- Tree construction recursively reads `AXChildren` with
  `AXUIElementCopyAttributeValue`. For each visited node it reads role,
  title/description, value, focus, selection, position, size, and supported
  actions.
- “Useful” is a deterministic shaping rule, not a model decision. The builder
  omits only structural noise from the returned outline: unlabeled, value-less,
  unfocused `AXGroup` wrappers whose only actions are generic navigation actions.
  It still retains those wrappers as nodes in the internal tree so parent and
  window attachment remain available even when the model-facing text omits them.
- `AXUIElementCopyActionNames` returns the semantic actions one live element
  supports, such as `AXPress`, `AXConfirm`, or `AXShowMenu`.
- The model receives a compact hierarchical tree text plus an optional
  screenshot. The in-memory snapshot contains each element ID, exact live AX
  handle, semantic fingerprint, pixel frame, parent, and children.
- `SnapshotStore` allocates a generation per PID. Core Foundation equality and
  hashing map each surviving AX handle to its earlier ID; recreated handles are
  explicit removals and additions. Screenshot scale is not part of identity.
- `SnapshotStore` is a Swift actor. Concurrent daemon tasks must enter it
  serially when allocating generations or replacing a current process/window
  snapshot, preventing two captures from racing on the same snapshot ID. A
  daemon restart intentionally starts with no snapshots.
- Use one small construction example on the slide or in the narration:

  ```text
  Live AX hierarchy
  AXWindow "Settings"
    AXGroup <unlabeled structural wrapper>
      AXCheckBox "Email alerts" value=0 actions=[AXPress]

  Tree returned to the LLM
  e0@s1 AXWindow "Settings" (0,0,900,700)
    e1@s1 AXCheckBox "Email alerts" (40,90,180,24) value="0" actions=[AXPress]

  Daemon snapshot entry for e1@s1
  role=AXCheckBox
  label="Email alerts"
  frame=[40,90,180,24]
  handle=<AXUIElement>; parent=<AXGroup handle>
  ```

- Explain the representation split explicitly: tree text and screenshot are the
  model-facing observation; structured snapshot entries and lineage are the
  runtime's durable metadata for future resolution.
- Design choices to articulate:
  - AX semantics provide more stable identity and better background behavior
    than pixel-only automation.
  - Screenshots cover visual or poorly labelled surfaces, but pixels are not
    the primary identity for semantic controls.
  - Locator replay plus fail-stale behavior is safer than acting on a retained
    handle after the application relayouts.
  - Full live reconstruction is easy to reason about, but repeated AX traversal
    is a measurable latency and context-cost target.

### Slide 6 — Deep dive 2: one click end to end

**Slide title:** One click, end to end

**Job:** Use one concrete element click to connect targeting, delivery,
verification, and the state returned to the model.

- Use the checkbox from Slide 5 as the concrete example. The LLM selects
  `e1@s1`, representing **Email alerts**, and calls `click(app, element_id)`.
- **Resolve:** the daemon resolves the current app/PID, loads the snapshot that
  contains that element ID, reselects the captured live window, and checks its
  process/window lineage.
- **Validate:** it reads `AXRole` on the exact retained handle, compares role,
  subrole, optional identifier, and stable label, checks the owning PID, and
  proves attachment to the captured window with `AXWindow` or a bounded
  `AXParent` walk. A failure returns stale before input; the model must perceive
  again instead of the runtime guessing at a replacement.
- **Gate:** before delivery, shared policy checks app ownership, screen-lock,
  recent human interference, confirmation requirements, and browser URL rules
  where applicable.
- **Capture before:** because the live role is `AXCheckBox`, the handler reads
  the current value/selection with `AXUIElementCopyAttributeValue`. The clear
  before condition is unchecked, represented by value `0`.
- **Semantic delivery:** `AXUIElementCopyActionNames` shows that the checkbox
  supports `AXPress`. The handler calls `AXUIElementPerformAction(AXPress)` and
  then rereads the same live target's value.
- **Clear evidence:** if the AX call returns success and the checkbox changes
  from `0` to `1`, the runtime has both delivery evidence and the expected
  effect evidence. This is the clearest happy-path example; generic buttons may
  require broader window evidence because the runtime does not know the
  application's business meaning.
- **Synthetic fallback:** if semantic delivery cannot produce the effect, the
  resolved AX frame supplies a global point, normally its center. The input
  layer constructs Core Graphics mouse-down/up events and attempts its guarded
  window/PID/global delivery path. Posting an event is not proof that the app
  applied it, so verification still uses live AX evidence.
- **Final verification:** reselect the window, rebuild the final state, reread
  the retained target where possible, and classify the result using the
  action family's evidence contract.
- **Commit and return:** preserve compatible IDs, compute the successor diff,
  and return an unchanged notice, compact diff, or full tree according to the
  response policy. This state becomes the basis for the model's next decision.
- The lifecycle to say aloud is:
  `resolve → gate → capture before → deliver → observe → verify → commit`.
- Design choices to articulate:
  - Prefer direct AX semantics; keep coordinate input as a guarded compatibility
    path for sparse or custom accessibility surfaces.
  - Fail stale rather than searching for a similar replacement or clicking
    whatever now occupies an old coordinate.
  - Use quick evidence to decide whether to continue the delivery ladder, then
    final state capture to create an authoritative successor snapshot.

### Slide 7 — Why one shared coordinator became necessary

**Slide title:** Scaling from one agent to many

**Job:** Explain the architectural evolution without confusing the audience by
jumping from the current system back to a disconnected historical diagram.

- Transition explicitly from Slide 6: “Everything in that mutation pipeline is
  state-dependent. It assumes the app does not change underneath it.”
- The useful single-agent path encouraged me to run more agent sessions and
  harnesses concurrently. Independent MCP server processes could then perceive
  the same app, prepare mutations against the same state, and interleave them.
- Example failure: Agent A resolves a button; Agent B changes the window; Agent
  A acts or retries against state that no longer reflects its original intent.
  For non-idempotent actions such as Send, a lost response can also make a blind
  retry dangerous.
- Reuse the Slide 4 architecture visually, but highlight the daemon and app
  coordinator instead of introducing a new unrelated diagram. Briefly show the
  “before” as several independent MCP executors, then animate or call out their
  convergence into the one current daemon.
- The daemon is therefore not just a background service. It is the single
  authority for shared snapshots, sessions, operations, policies, and
  application ownership.
- Design trade-off: centralization adds lifecycle and recovery complexity, but
  it removes competing sources of truth and creates one place to enforce
  ordering and idempotency.

### Slide 8 — Deep dive 3: multi-agent correctness

**Slide title:** Multi-agent concurrency and idempotency

**Job:** Go deepest on concurrency, idempotency, and the design alternatives.

- **Singleton process:** every serve shim first tries the known daemon socket.
  If none exists, multiple candidates may race to start. A lifetime-held kernel
  `flock` elects exactly one daemon; losers exit and their shims reconnect to the
  winner.
- `flock` solves process-level uniqueness only. It does not serialize mutations
  inside the surviving daemon.
- **Logical session identity:** the daemon gives each agent connection a logical
  session that can survive socket reconnection. Transport file descriptors are
  deliberately not used as product identity.
- **Operation identity:** each logical mutation has an operation UUID. The
  operation registry deduplicates retries and records the terminal response.
- Idempotency example: operation `O1` clicks **Send**, but its response is lost.
  Retrying `O1` returns the recorded result instead of clicking Send again. A
  genuinely new send receives `O2`; an ambiguous retry after daemon replacement
  fails closed rather than blindly repeating the mutation.
- **App-scoped ownership—the lease concept:** the current design replaces the
  earlier fixed-duration lease with operation-scoped ownership managed by a
  Swift actor plus a same-owner FIFO queue. Ownership lasts until the active
  mutation reaches completion; it cannot expire after an arbitrary ten seconds
  while a valid operation is still running.
- Same session + same app: later mutations wait and run sequentially, so each
  operation resolves against the state produced by the prior one.
- Different session + owned app: fail fast with `APP_BUSY`, letting that agent
  wait, perceive fresh state, and retry explicitly rather than sitting in an
  opaque cross-session queue.
- Different applications: execute concurrently.
- **Queue versus heartbeat lease:** the queue directly solves ordering and
  cannot expire during a legitimate long operation. A heartbeat lease helps
  reclaim crashed ownership but needs renewal, fencing tokens, expiry-race
  handling, and protection from zombie operations. They solve different
  problems and can be combined later if stuck-owner recovery justifies the
  complexity.
- Keep the main emphasis on the achieved invariant: one mutation at a time per
  app, deterministic same-session ordering, explicit cross-session conflict,
  and no fixed-duration expiry in the middle of a legitimate operation. Leave
  stuck-call recovery for Q&A.

### Slide 9 — Why metrics were not enough

**Slide title:** From metrics to evals

**Job:** Create the need for OpenBench from the production-hardening work rather
than presenting evaluation as an unrelated second project.

- Once multi-agent execution was relatively reliable, the next problem was
  prioritization: which perception and response policies actually improved task
  completion, latency, and model context?
- The daemon's structured metrics capture internal behavior such as queue wait,
  execution time, delivery tier, verification outcome, perception latency,
  element counts, response bytes, stale targets, and classified errors.
- These metrics are useful for debugging and bottleneck discovery, but the MCP
  cannot independently know whether an arbitrary end-to-end user task was
  completed correctly.
- Log success is also not enough for controlled comparison: different prompts,
  tool sequences, app state, or model behavior can confound the result.
- This created the evaluation requirement: repeatable computer-use tasks with
  externally checked truth, preserved tool-call evidence, and controlled
  implementation or policy variants.
- Building OpenBench from the ground up was how I learned and enforced those
  measurement contracts rather than relying on ad hoc demo success.

### Slide 10 — OpenBench computer-use evaluation

**Slide title:** OpenBench computer-use evals

**Job:** Explain the parts of OpenBench needed to trust the evidence without
turning the presentation into a deep dive on the framework itself.

- Each task defines a known starting state, concise agent instruction, allowed
  MCP surface, deterministic fixture application, timeout, and external checker.
- The fixture exposes predictable controls and independent truth so the checker
  can judge the final result without trusting the model or the MCP's own
  success message.
- OpenBench preserves an exact MCP call ledger and captures task success,
  response bytes, input tokens, wall time, MCP latency, and the MCP's structured
  action/perception metrics.
- For an A/B, keep the task, fixture, model, prompt, required calls, checker, and
  binary identity fixed; change one response policy or implementation variable.
- Alternate arms in AB/BA order and repeat runs so warm state or run order does
  not systematically favor one variant.
- Narrow policies can use one pinned binary with an experiment setting assigned
  by OpenBench and hidden from the agent. Larger architectural changes should
  use separately built, hashed, immutable binaries tied to source commits.
- The important boundary: operational `metrics.jsonl` explains the engine;
  OpenBench's sealed trial evidence supports comparative claims.

### Slide 11 — Evidence-driven improvement loop

**Slide title:** Measured improvements

**Job:** Show one honest, concrete loop from observation to experiment to the
next architectural priority.

- Observation: mutating tools repeatedly returned regenerated UI state to the
  model. I hypothesized that compact diffs would reduce context while preserving
  the same internal verification and task correctness.
- Controlled tool-level experiment: three `auto/diff` and three forced-`full`
  trials; four identical mutations per trial; same complete 26-element tree and
  deterministic checker.
- Verified result:
  - 12/12 mutations verified in each mode; checker passed 3/3 per arm.
  - Median model-visible state text fell from 2,142 B to 551 B: **74.3% less**.
  - Median complete response fell from 4,429 B to 2,704 B: **38.9% less**.
  - Median MCP latency stayed effectively flat: 390 ms versus 388 ms.
- Interpretation: diff responses materially reduce context, but they do not
  avoid the expensive AX work because both arms still regenerate the complete
  tree.
- Supporting but intentionally qualified agent-level prototype: suppressing
  redundant post-action state preserved 5/5 task success while reducing MCP
  response bytes 74%, uncached input tokens 49%, and wall time 27%; because the
  prompt and verification behavior also changed, this supports the hypothesis
  but is not a clean diff-versus-full causal result.
- Next controlled experiment: regenerate and verify the full state internally
  in both arms, but compare returning automatic diff/full state against
  returning only a compact verified action outcome. Then measure checker
  success, verified-effect rate, response bytes, input tokens, and wall time.
- Presentation lesson: the first experiment ruled out “diff encoding will make
  perception faster” and redirected optimization toward response policy first,
  then incremental or scoped perception.
- Evidence artifact:
  `/Users/matthewlam/dev/openbench/results/computer-use-state-ab/state-response-small-tree-direct-ab.json`.

### Slide 12 — Learnings and next steps

**Slide title:** Learnings and next steps

**Job:** Resolve the opening vision with honest current impact and a short,
ordered roadmap.

- The core progression is from a useful AX-based control loop to shared
  multi-agent coordination and then to a repeatable measurement loop.
- Priority 1—**broader OpenBench coverage:** add more control types, apps,
  concurrency conflicts, background-delivery cases, and implementation-level
  variants so changes are chosen from evidence rather than intuition.
- Priority 2—**incremental perception:** use `AXObserver` notifications to
  invalidate and refetch affected windows or subtrees, while retaining a full
  rebuild whenever freshness cannot be proven. Evaluate latency, context, and
  correctness against the existing path.
- Priority 3—**Windows support:** preserve platform-neutral transactions,
  coordination, identity, verification, and metrics while implementing Windows
  adapters with UI Automation and Windows-native capture/input. Treat
  background/foreground guarantees as a platform design problem, not a simple
  API rename.
- Secondary Q&A limitations: continuous human-interruption monitoring, bounded
  recovery from stuck platform calls, action-specific settling, and overlay
  completion acknowledgement.
- Closing lesson: reliable computer use is not just input generation; it is
  state identity, serialized side effects, observable outcomes, and an
  evaluation loop that tells you what to improve next.

## Scope guardrails for the first spoken draft

- Keep the main story on this implementation. Use Codex only as a brief design
  reference or a Q&A comparison.
- Keep Windows API details on Slide 11 or in backup; the main point is the
  platform seam and different foreground/background guarantees.
- Keep individual AX function names, file descriptors, socket threads, and
  overlay transport mechanics in speaker backup unless asked.
- Keep daemon authentication, detailed cancellation states, and exhaustive
  action-fallback mechanics in speaker backup unless asked.
- Keep removed workflow-convenience features outside the core presentation.
- Treat the 12-slide bullet draft above as authoritative. The phase notes below
  are implementation/Q&A backup and must not silently add new main-slide scope.
- Do not add another deep dive before writing the first speaking draft.

## Opening context notes — accepted direction

- This was a completely solo project built over several months. Exact dates are
  not important; ownership is: product direction, architecture, implementation,
  macOS integration, testing, and evaluation.
- The first motivation was the need for an agent feedback loop at the actual
  user surface. Computer use lets an agent inspect and exercise the product it
  built, rather than stopping after code generation or internal tests.
- Pi GUI is the concrete product-development example: an agent can operate the
  running application like a user, verify workflows, and continue iterating.
- The second motivation was delegating lower-priority computer work in the
  background without interrupting the user's primary task: app troubleshooting,
  system settings, and routine professional workflows.
- The product gap should be scoped to lived experience: the agent harnesses the
  presenter used did not provide a comparable local, background-safe computer-
  use surface. Avoid an unsupported universal claim about every harness.
- The future vision is intentionally strong and personal: as model reasoning
  and computer-use speed improve, agents will outperform humans at many computer
  workflows. Present this as the thesis motivating the work, then support it
  with observed capability trends and the project's feedback/verification model.
- The opening demo will show multiple harnesses operating different apps in the
  background, each with its own overlay cursor, while the presenter continues a
  foreground conversation with the primary agent.

## Phase 1 — Problem and design goal

- Give an LLM a semantic, safety-conscious way to operate existing macOS apps.
- Prefer Accessibility (AX) semantics over coordinate-only automation.
- Preserve a visual screenshot for context, but do not make pixels the primary
  control identity.
- Treat "the API accepted the action" and "the app visibly changed" as separate
  facts.

**Why this design:** semantic actions are more background-friendly and robust to
layout changes than raw screen coordinates, while screenshots cover sparse or
custom accessibility surfaces.

## Phase 2 — Perception and durable targeting

- Resolve the requested GUI app and exact window.
- Capture the window and recursively read its live AX hierarchy.
- Save snapshot nodes with role, subrole, optional identifier, stable label,
  frame, parent/children, and the exact live `AXUIElement` handle.
- Give the agent element IDs that map to those daemon-owned live nodes.
- Before mutation, prove the handle is live, semantically unchanged, owned by
  the same PID, and still attached to the captured window.
- Fail stale instead of searching for a similar replacement.

**Trade-off:** exact handles survive movement and reordering without structural
guessing, but a framework that recreates an AX object invalidates its old ID and
requires a fresh snapshot/model turn.

## Phase 3 — One mutation as an evidence lifecycle

```text
resolve → gate → capture before → deliver → observe after → verify → commit
```

- **Resolve:** map app, window, snapshot, and element ID to one live target.
- **Gate:** apply screen-lock, human-interference, confirmation, URL, and policy
  checks before delivery.
- **Capture:** record intent-relevant target/window evidence.
- **Deliver:** prefer supported AX actions or attribute writes; use guarded
  synthetic input only when needed.
- **Verify:** reread the target and, where needed, compare window-level AX state.
- **Commit:** replace the current in-memory snapshot and return a structured outcome.

**Important distinction:** delivery success is not application success. The
result separately reports what was delivered and what effect was observed.

### Act 1 proctor notes: `get_app_state` → click

- `get_app_state` passes through the shared dispatch funnel, but screen-lock and
  human-interference refusals are mutation-specific; read-only perception remains
  available while the screen is locked.
- App resolution scans current PIDs, creates `NSRunningApplication` records to
  match name/bundle ID, and then creates an AX application proxy for the chosen
  PID.
- Tree text is the model-readable outline. Structured snapshot nodes contain
  ID, the live AX handle, semantic fingerprint, frame, parent, and children;
  values, focus, selection, and available AX actions are rendered into tree text.
  Only current process/window snapshots stay in daemon memory.
- Snapshot generations are per PID (`s1`, `s2`, ...). Fresh emitted elements are
  `e0@sN`, `e1@sN`, etc.; the same Core Foundation AX handle can retain an older
  ID in a newer snapshot. Element strings are therefore app/PID-scoped,
  not globally unique by themselves.
- Mutation resolution selects the current process/window lineage and validates
  the retained handle's liveness, semantic fingerprint, PID, and window
  attachment. Dynamic value/focus/selection are evidence rather than identity.
  A mismatch fails stale before before-state capture or delivery.
- A click chain stops at the first rung with an **observed effect**, not merely
  the first AX call that returns success. It rereads cheap target-local evidence
  first and computes a window AX fingerprint only when the target appears inert.
  A fired-but-unverified rung is recorded and the chain continues.
- A generic button can prove an observed target/window change, but not the
  button's business outcome. No observable effect remains `effect_not_verified`.
- Explicit `get_app_state` returns full tree text. Action results may return an
  unchanged notice, a compact diff, or a full tree while persisting the committed
  snapshot for later target resolution.
- Quick rung verification chooses whether to continue the delivery chain. Final
  verification reselects the window, commits a new snapshot/diff, re-resolves the
  target, applies the family-specific outcome reducer, and produces authoritative
  delivery/effect metadata.
- Synthetic CoreGraphics posting has no trustworthy success acknowledgement; it
  is judged by the same final AX target/tree evidence. A compact diff is returned
  when changed/added/removed entries are at most half the resulting element count,
  not when its byte size is half the snapshot.

## Phase 4 — Shared daemon and multi-session identity

### Narrative transition from Phase 1

- Phase 1 made macOS computer use useful day-to-day from agents that did not
  already provide a comparable native computer-use surface.
- As usage expanded to multiple simultaneous agent sessions, independently
  executing MCP server processes could target the same app and interleave
  state-dependent operations.
- The product symptom was lower correctness, extra recovery/model turns, and
  longer end-to-end completion time.
- The architectural response was to move shared automation state and
  arbitration behind one per-user daemon while reducing each MCP server to a
  forwarding shim.

- MCP serve shims communicate with one shared per-user automation daemon.
- A daemon `flock` elects one winner; losing candidates connect to that winner.
- File descriptors identify socket connections, not durable agent sessions.
- A daemon-issued logical session UUID and resume token preserve ownership across
  reconnects to the same daemon.
- A client-created operation UUID identifies one logical tool operation.
- The daemon deduplicates safe retries so a lost response does not automatically
  repeat a mutation.
- Daemon incarnation identity makes ambiguous mutation retries fail closed after
  daemon replacement.

**Why:** connection identity is too fragile for ownership and idempotency once
multiple clients, reconnects, and concurrent requests exist.

### Initial logical-session handshake

```text
accept socket → same-UID peer check → hello(auth token, optional resume token)
→ establish/resume logical session → bind connection authorization to session
→ reply(session UUID, resume token, daemon incarnation, capabilities)
```

- The session registry is synchronized and maps opaque resume tokens to
  daemon-generated session UUIDs plus active-connection counts.
- A new connection without a recognized resume token receives a new UUID and
  cryptographically random resume token.
- The serve-side `DaemonClient` retains the resume token, incarnation ID, and
  negotiated capabilities in memory. It does not need to retain or resend the
  session UUID.
- Later tool requests carry request ID + operation UUID. The daemon reads the
  logical session from the authorization object already bound to that socket
  connection, rather than trusting a caller-supplied session ID.

Authentication has two checks:

1. `getpeereid` asks the kernel which macOS user owns the connecting socket and
   requires the daemon's user.
2. `hello` must include the random bearer token read from the owner-only
   `daemon.secret`; the daemon compares it in constant time.

Threading model:

```text
one accept thread on listening FD
→ one accepted connection FD + reader thread + authorization object per shim
→ concurrent Swift tasks for requests read from that connection
```

`DaemonSessionRegistry` is currently a lock-protected synchronous class, not an
actor. Its `NSCondition` both protects token/session/count mappings and lets a
reconnect wait until cleanup of its prior final connection completes.

## Phase 5 — Per-app mutation coordinator

Current behavior:

- Same session + same app: execute mutations FIFO.
- Different session + currently owned app: return `APP_BUSY`.
- Different apps: run concurrently.
- Ownership is operation-scoped and released when the active operation finishes.
- The actor coordinates permission; it does not execute the UI operation inside
  the actor. Completion hands ownership to the next same-session waiter.
- The queue stores operation identity plus a suspended continuation, not an
  executable closure. There is no drain loop: `release` promotes one FIFO waiter
  and resumes its already-created Swift request task.

**Why a queue:** two mutations against the same UI are order-dependent. A second
operation must resolve against the state produced by the first instead of
interleaving with it.

**Why cross-session fail-fast:** another session cannot see the owning session's
intent and may have prepared its operation against stale state. Returning
`APP_BUSY` lets that agent wait, perceive fresh state, and retry explicitly
instead of disappearing into an opaque daemon queue.

### Design trade-off: operation queue versus heartbeat lease

**Operation-scoped queue — current choice**

- Simple inside one daemon that directly owns the tasks and connections.
- Cannot expire in the middle of a legitimate long mutation.
- Gives deterministic same-session ordering.
- A truly stuck operation can retain ownership until cooperative cancellation,
  disconnect cleanup, or daemon replacement.

**Heartbeat lease — credible alternative**

- Helps reclaim ownership when a worker crashes or disappears.
- Must bind ownership to `sessionID + operationID`.
- Needs an unforgeable lease token/fencing generation.
- Renewal must stop on completion, cancellation, disconnect, or deadline.
- Every future delivery must verify the fencing token so an expired worker
  cannot resume and mutate.
- A separate heartbeat can accidentally keep renewing while the real operation
  is stalled; leases also cannot retract an OS event already in flight.

**Presentation conclusion:** the queue solves serialization; a heartbeat lease
solves owner-liveness recovery. They address different problems and can be
combined, but combining them adds renewal, fencing, expiry-race, and testing
complexity.

## Phase 6 — Cancellation and stuck operations

- Caller cancellation sends `cancel(operationID)` to the daemon.
- Queued work can be removed before it starts.
- Running work is cancelled cooperatively at safe boundaries.
- Before delivery, cancellation can stop without side effects.
- After delivery may have begun, continue observation and report an honest
  committed, partial, or unknown result rather than claiming rollback.
- The client RPC wait defaults to 120 seconds, but that timeout currently stops
  the caller waiting; it is not a universal daemon-enforced execution deadline.

**Remaining improvement:** add an operation deadline that requests cancellation,
records the phase and outcome, and does not blindly terminate input after
delivery may already have occurred.

**Core trade-off:** retaining ownership until a known terminal state prioritizes
correctness but can reduce availability when a handler is stuck. Force-releasing
on timeout improves liveness but can permit a cancelled "zombie" operation to
resume and overlap with the next owner. Safe deadlines therefore require
cooperative checkpoints and bounded platform calls, not only a timer.

Queue-compatible recovery ladder:

```text
operation deadline → cooperative cancellation → bounded verification/cleanup
→ release at a known terminal state
→ if the in-process task still cannot stop, drain/restart the daemon rather than
  admit a second owner beside a possible zombie operation
```

Daemon replacement is disruptive but terminates the old process definitively;
the new incarnation then fails ambiguous mutation replay closed and requires
fresh perception.

## Phase 7 — Verification, metrics, and tests

Current recorder:

- Mutation events: tool/app, attempted and final delivery strategy, effect
  outcome, queue latency, and execution latency.
- Perception events: total elapsed time, elements visited/returned, partial or
  diff result, and response context bytes.
- Each event is attached to MCP response `_meta`, appended to rotating
  `metrics.jsonl`, and merged into `metrics-summary.json`.
- A daemon-owned `MetricsRecorder` actor buffers events and serializes writes to
  the operational cache. The supported runtime is daemon-only; the removed
  in-process fallback and metrics file lock are not part of the presentation.

Benchmark evidence follows a stricter path:

```text
MCP response metrics in _meta
→ OpenBench validates the schema
→ exact call is preserved in the trial's sealed MCP ledger
→ deterministic checker judges the external result
→ report aggregates comparable trials
```

The rotating daemon cache is useful operational telemetry, but it is not the
source of truth for benchmark claims because it is not independently attributed
and sealed per trial.

Current evaluation focus:

- Explicit `APP_BUSY`, stale-target, cancellation, timeout, and error reason
  counters.
- Perception phase breakdown: window/capture time versus AX traversal/build time.
- Offline p50/p95/p99 latency and verified-effect rate grouped by tool, app, AX
  role, and delivery route.
- Actual response encoding and complete response bytes, so automatic
  unchanged/diff/full responses can be compared with forced full state.
- Keep metrics privacy-safe: no labels, text values, URLs, screenshots, or AX
  tree contents.
- Use deterministic unit tests and the fixture app for repeatable behavior;
  reserve live GUI/TCC checks for explicitly approved local verification.

The intended presentation result is one or two concrete improvement loops:

```text
baseline → identify bottleneck → change one controlled variable
→ rerun matched trials → preserve task correctness → report measured delta
```

The leading performance case is automatic state responses versus forced full
state. The leading reliability case is background delivery with independently
verified app state and unchanged foreground focus. Insert final numbers only
after the OpenBench run is complete.

**Why:** production hardening needs evidence about which delivery and perception
paths fail, not more fallbacks added from intuition.

## Phase 8 — Honest remaining limitations

- **Perception is rebuilt, not maintained incrementally.** The system preserves
  snapshot identity, lineage, and compact diffs, but a fresh state response
  still walks the live AX hierarchy and rebuilds the tree. This favors a simple,
  trustworthy source of truth at the cost of perception latency and repeated
  work. A next step is a revisioned per-window cache: consume AX notifications,
  invalidate or update affected subtrees, refetch invalid elements, and perform
  a full rebuild whenever the cache cannot prove it is current.
- **The implementation is macOS-specific.** A portable design should keep the
  transaction, session, verification, and metrics layers platform-neutral while
  placing perception, capture, and input behind platform adapters. A Windows
  backend would likely map AX to UI Automation, ScreenCaptureKit to Windows
  Graphics Capture, and Core Graphics input to UIA patterns or `SendInput`.
  Unlike macOS background operation, current Windows computer use generally
  owns the active desktop and foreground input, so this is not merely an API
  port; it requires a different focus, safety, and testing model.
- No continuous human-interference monitor throughout the complete mutation.
- No acknowledgement that the separate overlay animation finished before input.
- No hard daemon-enforced deadline for every stuck handler.
- Synthetic background input may be accepted by the OS but dropped by the app.
- Accessibility quality still depends on what the target app exposes.
- Delivery notifications are advisory and application support varies. The
  implementation therefore rereads exact target state immediately, after wakes,
  and at a bounded deadline; an unverified acknowledgement is never retried
  automatically.

## Quick script checklist

- Start with the product vision and a brief real multi-agent workflow demo.
- Show the current architecture early, but explain prior architectures only
  when they motivate a current decision.
- Explain the happy path using one concrete operation.
- State why AX is preferred and why live, validated snapshots exist.
- Explain `resolve → gate → deliver → verify → commit`.
- Then introduce the multi-agent problems: identity, retries, and interleaving.
- Explain the per-app queue before discussing leases.
- Use heartbeat leases as an explicit design alternative, not as the same thing
  as serialization.
- Separate confirmed current behavior from future improvements.
- Close with OpenBench showing how reliability and performance are improved
  from evidence rather than intuition.
- Frame the perception cache as a deliberate next optimization: preserve the
  current full-rebuild path as the correctness fallback until notification-led
  invalidation is proven reliable across apps.
- Present Windows as a platform-architecture extension, not a claim that the
  current macOS engine can simply be recompiled for Windows.
- Describe 43 stars and the Pi extension fork as early external validation, not
  large-scale adoption.

## Source anchors to re-check while drafting the script

- `Sources/computer-use-mcp/Serve.swift`
- `Sources/computer-use-mcp/Dispatch.swift`
- `Sources/computer-use-mcp/Daemon/DaemonClient.swift`
- `Sources/computer-use-mcp/Daemon/DaemonServer.swift`
- `Sources/computer-use-mcp/Daemon/DaemonCoordination.swift`
- `Sources/computer-use-mcp/Core/ActionTransaction.swift`
- `Sources/computer-use-mcp/Core/Snapshot.swift`
- `Sources/computer-use-mcp/Core/Target.swift`
- `Sources/computer-use-mcp/Core/TreeBuilder.swift`
- `Sources/computer-use-mcp/Core/MetricsRecorder.swift`
- `Sources/computer-use-mcp/Tools/ClickTool.swift`
