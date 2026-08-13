# Computer Use MCP Project Presentation

## Speaker Script Draft V1

This is the first complete spoken draft based on
`docs/project-presentation-outline.md`. It targets approximately 25–30 minutes
across 12 slides, leaving the rest of the 45-minute interview for discussion.

The demo narration is a placeholder until the final recording is ready. Current
implementation claims are based on local `main` at `1c6e96e`. Benchmark claims
are intentionally separated into clean causal evidence and qualified supporting
evidence.

---

## Slide 1 — Computer Use MCP

### Visible slide

**Computer Use MCP**

Local macOS computer use for agent harnesses

Matthew Lam

### Draft speaker notes

Thanks for having me. Today I’m going to talk about Computer Use MCP, a solo
project I built over the last several months.

The project gives local coding-agent harnesses a shared way to observe and
operate macOS applications. I initially built it to make one agent useful on my
own computer. As I used it more, the harder problem became coordinating several
agents safely and then measuring whether changes actually improved reliability
and performance.

I’ll start with why I think computer use matters, show the current product, and
then go into three technical areas: perception and targeting, one complete
mutation, and multi-agent concurrency. I’ll finish with how I built an evaluation
loop around the system and what the first experiments taught me.

---

## Slide 2 — Why computer use?

### Visible slide

**Why computer use?**

- A feedback loop at the user surface
- Existing software becomes an agent interface
- Professional workflows become automatable

### Draft speaker notes

I became interested in computer use because agents need a feedback loop.

An agent can write code and run internal tests, but that still does not prove the
product works from the user’s perspective. When I was building a desktop app,
computer use let the agent open the running product, click through the same
workflow as a user, inspect the result, and continue iterating. It gave the agent
feedback from the surface it was actually building.

I also found it useful for work that was not directly related to coding. An
agent could inspect settings, diagnose an application problem, or complete a
routine workflow while I kept working on something else.

The harnesses I was using—including Devin, Cursor, Claude Code, and Pi—either
did not expose local computer use or had something too limited or unreliable for
the workflows I wanted. At the same time, I was increasingly using several
harnesses and models because each was useful for different tasks.

The longer-term opportunity is much broader than software development. Most
professional work still happens through normal desktop applications. If agents
can operate those interfaces reliably, non-technical users can automate work
across productivity software, finance, operations, customer support, and many
other existing systems without learning APIs or becoming programmers.

My personal belief is that, as model reasoning and computer-use speed improve,
agents will perform an increasing amount of this work faster than humans can
operate the computer manually. The missing pieces are making the capability
dependable and making more people aware that it is possible.

---

## Slide 3 — Demo

### Visible slide

**Demo**

Two agents · Two applications · One shared computer-use layer

### Draft speaker notes

Before I explain the architecture, I want to show what the current product looks
like.

In this recording, I start two different agent harnesses. One opens System
Settings and inspects the machine’s storage configuration. The other opens Notes
and drafts a message. I continue working in my foreground application while both
agents operate different apps in the background.

Each agent has its own overlay cursor, so I can see which session is acting and
where without giving either one control of my real pointer.

The important result is not the individual clicks. It is that different agent
harnesses use one common interface, work on separate applications concurrently,
and make their activity understandable without taking over my primary task.

The rest of the presentation explains the system behind that workflow.

---

## Slide 4 — Current system architecture

### Visible slide

**Current system architecture**

```text
Agent harnesses
      ↓ MCP over stdio
Serve shims
      ↓ Unix socket
Shared daemon
  ├─ dispatch and safety
  ├─ snapshots and targeting
  ├─ app mutation coordinator
  ├─ sessions and operation identity
  └─ metrics
      ↓
macOS AX · ScreenCaptureKit · Core Graphics
      ↓
Target applications

OpenBench → independent task evidence
```

### Draft speaker notes

This is the current system at a high level.

At the top are MCP-capable agent harnesses. Each harness launches a small server
process that communicates through standard input and output. I call that process
the serve shim because it implements the MCP-facing contract but does not own an
independent automation engine.

The shims forward requests over a local Unix socket to one shared daemon. The
daemon is the central coordination boundary. It owns tool dispatch, safety
checks, application resolution, perception, input delivery, verification,
logical sessions, operation deduplication, and per-application mutation
ordering.

Snapshots are also inside that shared boundary. For each target process, the
snapshot store preserves the current semantic state and a bounded history. A
snapshot includes the application and window identity, a generation, stable
element IDs, frames, and locator paths that can be replayed against the live
application later.

Below the daemon are the macOS services. AppKit helps identify running GUI
applications. The Accessibility APIs expose semantic elements and actions.
ScreenCaptureKit captures the selected window. Core Graphics provides a guarded
coordinate-based input path when an application does not expose enough useful
accessibility behavior.

The cursor overlay is a separate optional process. It gives each agent session
a visible cursor, but it is cosmetic; it does not decide whether an action is
correct.

Finally, OpenBench sits outside the automation engine. Internal metrics can
describe what the daemon attempted, but OpenBench provides independent evidence
about whether the overall task completed and how different variants compare.

I’m going to zoom into the perception path first, because every later
correctness guarantee depends on knowing exactly which live application,
window, and element the model is acting on.

---

## Slide 5 — Perception: AX Tree → Durable Target

### Visible slide

**How the agent understands the computer**

```text
Live AX hierarchy
AXWindow "Settings"
  AXGroup <structural wrapper>
    AXCheckBox "Email alerts" value=0 actions=[AXPress]

Model-facing tree
e0@s1 AXWindow "Settings"
  e1@s1 AXCheckBox "Email alerts" value="0" actions=[AXPress]

Persisted locator
AXGroup[0] → AXCheckBox[0]
```

### Draft speaker notes

When the model calls `get_app_state`, it passes the application it wants to
inspect and can optionally identify a particular window.

The daemon first resolves that application to a current process ID and an
`NSRunningApplication`. It then creates an accessibility application proxy by
calling `AXUIElementCreateApplication` with that process ID.

From the application root, the system reads accessibility attributes for the
available windows. It prefers the requested window when one was specified;
otherwise it can use the focused or main window. The selected window is not
identified only by its title. The snapshot also records the process ID, bundle
identifier, process start time, and Core Graphics window ID. That prevents an
old snapshot from silently applying to a restarted process or a replacement
window that happens to have the same title.

ScreenCaptureKit captures that exact window for visual context. Accessibility
frames use global screen points, while the screenshot is made of pixels. The
system records the window origin and pixels-per-point scale so each semantic
element can be aligned with the corresponding box in the image.

Next, it constructs the accessibility tree. Starting from the selected window,
it repeatedly calls `AXUIElementCopyAttributeValue` for `AXChildren`. For each
visited element, it reads facts such as role, label, value, focus, selection,
position, and size. It separately calls `AXUIElementCopyActionNames` to learn
which semantic actions the element supports.

The traversal is deterministic. It does not ask the model which nodes are
useful. It emits almost every element, but removes obvious structural noise from
the model-facing outline. In this example, the empty `AXGroup` has no label, no
value, no focus, and no meaningful action, so it is not useful to show the model
as its own line.

The group is still part of the real application hierarchy, so it remains in the
locator. The checkbox is represented by the path `AXGroup zero, then
AXCheckBox zero`, where each number is the index among siblings with the same
role.

The model receives a compact hierarchical text representation and, when
requested, the screenshot. The text contains information useful for reasoning,
including the element ID, role, label, frame, current value, focus or selection,
and supported actions.

The persisted snapshot has a different job. Its structured element entry keeps
the ID, role, stable label, screenshot-relative frame, and locator path required
to reacquire that element later. It does not retain the live `AXUIElement`
pointer because those handles can become invalid when the application relayouts.

The snapshot store is a Swift actor. It maintains the latest snapshot, the next
generation counter, and up to 32 recent snapshots for each process. When two
daemon tasks try to capture the same application concurrently, only one can
execute the actor-isolated capture at a time. That prevents them from allocating
the same generation or racing while updating history and stable IDs.

During capture, the snapshot store first allocates a generation such as `s1` and
passes that generation into the tree builder. The builder can then create IDs
such as `e1@s1`. The store compares the new state with a compatible prior
snapshot. If an element still occupies the same locator with the same identity,
its ID can survive into the successor state. The store also computes the added,
changed, and removed elements.

There are two important trade-offs in this design.

First, AX semantics are more stable and more background-friendly than treating
the screen as an image and clicking pixels. The screenshot is still valuable
for visual context and for interfaces with poor labels, but it is not the
primary identity for a semantic control.

Second, reconstructing current state is simple to reason about because the live
application remains the source of truth. The cost is that walking a large AX
tree repeatedly can be one of the most expensive parts of the operation. I’ll
return to that trade-off when I discuss the evaluation results.

Now I’ll continue with the same checkbox and show what happens when the model
tries to click it.

---

## Slide 6 — One click, end to end

### Visible slide

**One click, end to end**

```text
Resolve → Gate → Capture before → Deliver → Observe → Verify → Commit
```

```text
Target: Email alerts
Before: value=0
Action: AXPress
After: value=1
Result: verified effect + successor snapshot
```

### Draft speaker notes

The model has received the tree and chooses `e1@s1`, the Email alerts checkbox.
It calls the click tool with the application and that element ID.

The first phase is resolve. The daemon resolves the current application process
and loads the snapshot containing `e1@s1`. It reselects the exact live window
using the stored process and window lineage rather than trusting only a title.

It then walks the saved locator against the current accessibility hierarchy. It
starts at the live window, finds the first `AXGroup`, and then finds the first
`AXCheckBox` inside that group. It checks that the resulting element still has
the expected role and stable label.

If that path now points to a different control, the system returns a stale
element error before sending input. The model has to call `get_app_state` again
and choose from current state. I preferred failing stale over clicking whatever
happened to replace the old target.

After resolution, the operation passes through the shared mutation gates. These
include per-app ownership, screen-lock state, recent physical interference,
confirmation requirements for risky operations, and browser URL policy where it
applies.

The handler then captures the before state needed for this action. Because the
live role is `AXCheckBox`, the clearest evidence is its current value or selected
state. In this example the value is zero, meaning unchecked.

For delivery, the click handler reads the actions supported by the live element.
The checkbox exposes `AXPress`, so the handler calls
`AXUIElementPerformAction` with that action.

An accessibility API returning success tells us the call was accepted, but the
useful evidence is what happened afterward. After a short settling period, the
handler rereads the live checkbox. If its value changed from zero to one, the
operation has direct evidence that the expected effect occurred. It stops the
delivery chain instead of trying another click strategy.

Different control roles require different evidence. A text-entry click can be
verified by focus. A toggle has a requested selected state. A text mutation can
compare the resulting value. A generic button is less specific because the
runtime does not know the application’s business meaning. In that case it can
observe a target or window-level AX change, but it should not claim more than the
evidence supports.

If the semantic actions cannot produce the requested effect, the system has a
coordinate fallback. The live AX element provides a global frame, and the input
layer normally uses its center point. It constructs Core Graphics mouse-down and
mouse-up events and attempts the permitted window-targeted, process-targeted, or
guarded global path.

This fallback helps with custom controls and applications that expose sparse
accessibility behavior. It is less reliable than a direct semantic action: the
event can be posted to a process without the application actually applying it.
The system therefore verifies the result through the same live AX evidence
rather than treating event posting as success.

After delivery, the final verification path reselects the window and captures
the resulting application state. It re-resolves the acted target when possible,
classifies the observed outcome, and commits one successor snapshot. Compatible
elements keep stable IDs, and the snapshot store calculates what was added,
changed, or removed.

The response can then return an unchanged notice, a compact diff, or the full
tree depending on the state-response policy. That result becomes the model’s
next observation.

The lifecycle I use to reason about a mutation is: resolve, gate, capture the
before state, deliver, observe, verify, and commit. Each phase has a clear job,
and the live application—not a stale pointer or an old screenshot—remains the
source of truth.

This works cleanly when one agent is controlling an application. The next
problem appeared when I started using the same state-dependent pipeline from
several agent sessions at once.

---

## Slide 7 — Single → Multi-Agent Architecture

### Visible slide

**Scaling from one agent to many**

```text
Before
Agent A → independent MCP executor → App
Agent B → independent MCP executor → App

Current
Agent A ─┐
         ├→ shared daemon → app coordinator → App
Agent B ─┘
```

### Draft speaker notes

Everything in the mutation flow I just described is state-dependent. The model
perceives an application, chooses an element from that state, and expects the
application not to change unpredictably before delivery and verification.

The first version was useful enough that I started running it from more agent
sessions and more harnesses. With independent MCP executor processes, two
agents could perceive the same app and prepare operations against the same
starting state.

For example, Agent A could resolve the Send button in a compose window. Before
Agent A acted, Agent B could change or close that window. Agent A’s operation
would now be based on state that no longer reflected its intent. Even if target
resolution failed stale, there was no single authority coordinating ownership,
snapshot history, and the order of writes.

Retries introduced another form of ambiguity. If an agent clicked Send but lost
the response, blindly repeating the request could send the message twice.

I moved the automation engine and shared state behind one per-user daemon. The
MCP servers became small forwarding shims. This created one place to arbitrate
application ownership, assign logical sessions and operation IDs, preserve
snapshots, apply policy, and deduplicate retries.

That is the daemon shown in the current architecture slide. I showed the final
system first so the audience had a complete map. The historical change explains
why that central process is a correctness boundary rather than just a deployment
detail.

Centralization adds daemon lifecycle and recovery complexity. The benefit is
that all agents now operate against one source of coordination truth. The next
slide covers how that process is elected and how it orders mutations.

---

## Slide 8 — Multi-agent concurrency and idempotency

### Visible slide

**Multi-agent concurrency and idempotency**

```text
One daemon: lifetime-held flock

Per app:
  current owner session
  active operation
  same-owner FIFO queue

Retry safety:
  session identity + operation UUID + recorded result
```

### Draft speaker notes

There are two separate concurrency problems here: making sure there is one
coordinator process, and then ordering operations inside that process.

Every serve shim first tries to connect to a known Unix socket. If no daemon is
available, several shims can race to start daemon candidates. Each candidate
tries to acquire the same kernel advisory lock with `flock`.

Only one process can hold the lock. The winner keeps the file descriptor and the
lock for its complete lifetime. Losing candidates exit, and the shims that
started them retry the socket connection and attach to the winner. This gives me
one coordination authority without requiring a permanently installed service
manager.

The daemon lock does not serialize application operations. It only guarantees
that there is one process responsible for doing so.

Inside the daemon, logical session identity is separate from the socket
connection. A file descriptor identifies one current transport connection, but
connections can drop and be recreated. The daemon issues a logical session and
supports resuming that session across a reconnect so application ownership is
not tied to an incidental socket number.

Each mutation also receives a unique operation UUID. The operation registry
records whether that logical request is running or has reached a terminal
result. If the client retries the same operation because a response was lost,
the daemon can return the recorded result rather than repeating the side effect.

For example, operation O1 clicks Send and completes, but its response never
reaches the client. Retrying O1 does not click Send again. A genuinely new send
uses a new operation ID. If the daemon has been replaced and cannot prove the
old result, an ambiguous mutation retry fails closed instead of being replayed
blindly.

The remaining problem is app-level ownership. The earlier design used a
fixed-duration lease. A session could own an application for ten seconds, and
new operations from the same session renewed the expiration.

The weakness was that the lease duration and the operation lifetime were not
the same thing. A legitimate mutation could take longer than ten seconds. If
the lease expired while that operation was still active, another session could
acquire the app and overlap with it. Heartbeating can extend the lease, but it
adds renewal, fencing, expiry-race, and liveness state without directly solving
same-session ordering.

The current design uses operation-scoped ownership in a Swift actor. For each
application PID, the coordinator tracks the owner session, the active operation,
and a FIFO queue of waiting operations from that same owner.

If the same session submits another mutation to the same app, it waits in the
queue. When the active mutation finishes, the coordinator resumes the next one.
That means the second operation resolves its target against the state produced
by the first instead of interleaving with it.

If another session tries to mutate the owned application, it receives
`APP_BUSY`. I chose to fail cross-session requests explicitly rather than keep
them in an opaque queue. The second agent does not know the first agent’s intent,
and its operation may already be based on stale perception. Failing fast lets it
wait, inspect fresh state, and decide whether retrying still makes sense.

Operations against different applications can still run concurrently. The
serialization boundary is one target app, not the whole computer.

The central guarantee is therefore straightforward: one mutation at a time per
application, deterministic ordering for one session, an explicit conflict for a
different session, and no arbitrary expiration in the middle of a legitimate
operation.

An operation-scoped queue and a heartbeat lease solve different problems. The
queue solves ordering. A well-designed heartbeat lease can help recover
ownership after a worker disappears, but it requires fencing so an expired
worker cannot later resume and mutate. I chose the simpler queue because the
single daemon already owns the tasks and because serialization was the immediate
correctness problem.

At this point the system was much more reliable for my multi-agent usage. The
next question was how to decide which improvements mattered rather than adding
more mechanisms based only on intuition.

---

## Slide 9 — From metrics to evals

### Visible slide

**From metrics to evals**

```text
Runtime metrics explain the engine
External checks judge the task
```

### Draft speaker notes

The daemon records structured metrics for each operation: queue wait, execution
time, perception latency, element count, response size, delivery route,
verification outcome, stale targets, and classified errors.

Those metrics answered questions such as: Is time being spent waiting for an
app, traversing Accessibility, or delivering input? How often does semantic AX
succeed before Core Graphics is needed? How much UI state are we returning to
the model?

But operational metrics could not answer the most important question by
themselves: did the agent complete the user’s task correctly? A handler can
report that an event was delivered while the application drops it, or the agent
can perform the wrong valid action. Logs from unrelated runs also cannot support
a fair comparison when prompts, initial state, or tool sequences differ.

That gap led me to build computer-use evaluations in OpenBench. I wanted a
repeatable loop: establish a known starting state, run one task, preserve the
exact evidence, check external truth, change one variable, and run it again.

The distinction is important. Runtime metrics explain what happened inside the
engine. An evaluation determines whether the complete system produced the
right externally observable result.

---

## Slide 10 — OpenBench computer-use evals

### Visible slide

**OpenBench computer-use evals**

```text
Known start → agent run → exact call ledger → external checker
```

Matched A/B: fix task, model, prompt, fixture, checker, and binary

### Draft speaker notes

Each computer-use task defines a known application state, a concise agent
instruction, the permitted MCP surface, a timeout, and an independent checker.
I use a deterministic AppKit fixture containing controls whose behavior and
final values are known in advance.

The checker reads that final truth directly. It does not trust the model’s claim
or the MCP’s own success response. OpenBench also preserves the exact MCP call
ledger and collects task success, response bytes, input tokens, wall time, MCP
latency, and the structured engine metrics.

For an A/B comparison, I keep the task, fixture, model, prompt, required calls,
checker, and binary identity fixed. I change one policy, alternate the arms in
AB/BA order, and repeat the trials. This reduces the chance that warm state or
run order explains the result.

For a narrow response policy, one pinned binary can receive a hidden experiment
setting from OpenBench. For a larger architecture change, I would instead use
separately built, hashed binaries tied to source commits.

The trust boundary is therefore explicit: daemon metrics are diagnostic;
OpenBench’s preserved call record and external checker are the evidence used
for comparative claims.

---

## Slide 11 — Measured Improvement: Diff vs. Full State

### Visible slide

**Measured improvements: diff state vs. full state**

- Correctness: unchanged — 12/12 verified in both modes
- Model-visible state: **74.3% smaller**
- Complete response: **38.9% smaller**
- MCP latency: unchanged

### Draft speaker notes

One recurring cost was regenerated UI state returned after every mutation. I
hypothesized that returning a compact snapshot diff would reduce model context
without changing internal verification or correctness.

I ran three automatic-diff trials and three forced-full trials. Each trial used
the same complete 26-element tree, four identical mutations, and the same
deterministic checker.

Both modes verified all 12 mutations, and the checker passed all three trials
in each arm. Median model-visible state text fell from 2,142 bytes to 551 bytes,
a 74.3 percent reduction. Median complete response size fell from 4,429 bytes
to 2,704 bytes, a 38.9 percent reduction.

MCP latency did not improve: the medians were 390 and 388 milliseconds. That
negative result was useful. Both variants still reconstructed the full AX tree
for verification; only the response encoding changed. Diffs reduced context,
not perception work.

I also ran an agent-level prototype that suppressed redundant post-action state.
It preserved five out of five task successes while reducing response bytes by
74 percent, uncached input tokens by 49 percent, and wall time by 27 percent.
That run changed the prompt and verification behavior too, so I treat it as
supporting evidence rather than a clean causal comparison.

The next controlled experiment keeps full internal regeneration and
verification in both arms, but compares returning automatic state against only
a compact verified outcome. More broadly, this result redirected the next
performance work toward response policy and incremental perception rather than
assuming a smaller serialization would make AX traversal faster.

---

## Slide 12 — Learnings and next steps

### Visible slide

**Learnings and next steps**

1. Broader OpenBench coverage
2. Incremental AX perception
3. Windows support

Reliable computer use = identity + serialization + evidence + evaluation

### Draft speaker notes

The project evolved through three distinct problems: first, build a useful
macOS control loop; second, make shared side effects safe across multiple
agents; third, create a measurement loop that can tell me what to improve.

My main architectural lesson is that reliable computer use is not primarily
about generating mouse and keyboard input. It depends on preserving state
identity, resolving a fresh live target, serializing side effects, separating
delivery from observed outcomes, and retaining evidence when requests are
retried.

My first next priority is broader OpenBench coverage: more control types,
applications, concurrent conflicts, background-delivery cases, and controlled
implementation variants.

The second is incremental perception. Today, a fresh state response rebuilds
the AX tree. I would use `AXObserver` notifications to invalidate and refetch
affected windows or subtrees, while retaining a full rebuild whenever freshness
cannot be proven. The existing evaluation gives me the baseline needed to test
that change safely.

The third is Windows support. The transaction, coordination, verification, and
metrics layers can remain platform-neutral, while macOS AX, ScreenCaptureKit,
and Core Graphics receive Windows adapters based on UI Automation, Windows
Graphics Capture, and native input APIs. Background operation and focus safety
must be designed and evaluated for Windows rather than assumed to match macOS.

The result today is a working multi-agent computer-use system and, equally
important, a disciplined path for deciding how to make it more reliable and
efficient from measured evidence rather than intuition.
