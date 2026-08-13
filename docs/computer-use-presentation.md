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

Thanks for having me. Today I’m going to talk about Computer Use MCP, an
agent-agnostic computer-use system designed to work with any MCP-compatible
agent harness.

It started as a single-agent implementation and evolved into a multi-agent
system with reliable targeting, concurrency control, and an evaluation
framework for measuring and improving performance.

---

## Agenda

### Visible slide

1. Background
2. Core Function
3. Key Decisions
4. Testing
5. Takeaways & Next Steps

### Draft speaker notes

I’ll start with why computer use matters, then show a product demo and
architecture overview. From there, I’ll explain how the
system understands application state and completes a verified operation, how it
evolved to support multiple agents reliably, and how I built an eval framework
to measure correctness and performance and drive improvements. I’ll finish with
a concrete result, lessons, and next priorities.

---

## Slide 2 — Why computer use?

### Visible slide

**Why computer use?**

- A feedback loop at the user surface
- Existing software becomes an agent interface
- Professional workflows become automatable

### Draft speaker notes

Looking back just one year, software engineering has changed dramatically
because models have become deeply integrated throughout the developer workflow.
We have not seen the same magnitude of change across most other professional
work.

I do not think that is only a limitation of the models. There is also an
interface gap: agents often cannot fully observe or operate the applications
where that work happens.

Computer use helps bridge that gap. It gives agents access to the same
applications people already use, with the potential to change other forms of
work in the same way agents have begun changing software engineering.

For developers, computer use also closes an important feedback loop. While
developing Pi-GUI—a Codex-style desktop app for the Pi agent—I could let the
agent launch the application, navigate through real workflows, inspect the
result, and continue improving its own changes through the same surface a user
sees.

The broader opportunity is to bring that execution and feedback loop to
professional workflows outside software engineering—from finance and accounting
to operations and administrative work.

Codex demonstrated reliable computer use, but other agent
harnesses—including Claude Code, Cursor, and Devin—did not offer comparable
local computer use that could operate reliably in the background. Computer Use
MCP addresses that gap through one interface designed to work across different
agents and models.

---

## Slide 3 — Demo

### Visible slide

**Demo**

Two agents · Two applications · One shared computer-use layer

### Draft speaker notes

This demo shows two agent harnesses using Computer Use in the background
alongside my main Codex session, which represents me continuing to work on my
primary task.

On the top left, Claude Code uses Computer Use to interact with and test Pi-GUI,
a Codex-style desktop app for the Pi agent. It clicks through different threads
and navigates side tabs including Settings and Extensions.

On the bottom left, a Cursor agent uses Computer Use to edit two text items and
set a text value to “hello world.”

On the right, my main Codex session remains in focus while the other two agents
continue working. Their operations stay completely in the background: they do
not take focus or control of my real pointer, so I can continue working on my
main task.

The important result is not the individual clicks. It is that independent agent
harnesses can share one computer-use system, work concurrently across different
applications, and stay out of the user’s way.

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
  └─ app mutation coordination
      ↓
macOS AX · ScreenCaptureKit · Core Graphics
      ↓
Target applications

OpenBench → metrics + independent task evidence
```

### Draft speaker notes

The current architecture starts off with the MCP compatible agent harnesses at the top layer. Each harness launches a thin MCP server process and communicates through standard IO. The MCP server defines the agent-facing contract but does not own the independent computer-use engine, most similar to a proxy.

The requests go through the server over a local Unix socket to the shared daemon instance, which is the central coordination service. It owns tool dispatch, finding the right tool and handler, snapshots of different app's state in tree like structures, and per-application lease ownerships so that each application only has one agent mutating it at one time.

Each snapshot preserves the state of an application and window in an accessibility tree structure, representing the structure of the app's elements, stable IDs for each element, and locator paths that save the traversal path from the root of the app to each individual element.

Below the daemon are the macOS services that perform the operations on the computer. AppKit, Apple's native GUI framework, helps identify running GUI applications. The Accessibility APIs expose app elements and element accessibility actions, like clicking a button or setting the text value of a text box. ScreenCaptureKit captures the screenshot for the selected window. Core Graphics provides a fallback coordinate-based input path when an application does not expose enough useful accessibility behavior. Basically sending mouse and keystroke events at specific coordinates.

Finally, the architecture includes an evaluation layer through OpenBench, the
eval framework I built for Computer Use MCP. It combines daemon runtime metrics
with repeatable computer-use tasks to measure correctness, identify performance
bottlenecks, and compare implementation variants.

---

## Slide 5 — Perception: AX Tree → Durable Target

### Visible slide

**How the agent understands the computer**

```text
Live AX hierarchy
AXWindow "Settings"
  AXGroup
    AXCheckBox "Email alerts" value=0 actions=[AXPress]

Model-facing tree
e0@s1 AXWindow "Settings"
  e1@s1 AXCheckBox "Email alerts" value="0" actions=[AXPress]

Persisted snapshot element
e1@s1 · AXCheckBox · "Email alerts"
AXGroup[0] → AXCheckBox[0] · frame=[48,120,160,24]
```

### Draft speaker notes

A core part of computer use is providing the LLM an understanding of the app's state.

The model starts by calling the get_app_state tool and passes the application it wants to inspect.

The daemon first calls libproc to find all the available process IDs and resolves the passed-in application name to its corresponding process ID and NSRunningApplication. It then creates a proxy reference to that application through AXUIElementCreateApplication with the app's process ID, which allows us to look into the application's windows and elements.

After we have the application root, the system reads accessibility attributes to find the available windows. And a snapshot is initialized for this app recording the process ID, bundle identifier, process start time, and window ID. Together these identify the exact process and window the snapshot came from.

ScreenCaptureKit is then used to capture a screenshot of that window, which later gets returned to the LLM for visual context and reference.

Next, the daemon constructs the Accessibility tree. Starting from the selected window, it reads each element's AXChildren attribute and recursively visits those children. For every visited element it reads fields such as role, label, value, and saves them for the snapshot as well.

As it walks from the selected window root, each element also records the traversal path used to reach it.

In this example, the checkbox is represented by the path AXGroup zero, then AXCheckBox zero, where the traversal path indicates the index among siblings within the same role.

The model receives the text representation of the AX tree and screenshot to provide the context for deciding the next actions.

The persisted snapshot serves a different purpose. Its element entry keeps the ID, role, label and tree traversal path, so that we can use the paths to relocate the same element in future states.

Before a mutating operation, the daemon finds the element's path in the latest snapshot, and replays that path against the current live window, obtaining a fresh ax element reference, and checks its role and label. If the element at that path doesn't have the same role and label as the one saved in the snapshot, the operation fails with a stale error, telling the LLM it needs to re-query get_app_state for the app's new state.

The tradeoff with this design is I prioritized reliable snapshot reuse over the speed of caching live AX handles, since snapshot reuse helps prevent addiitonal agent turns and token use from having stale app states. AX handles are temporary references that can become invalid when an application rebuilds its accessibility hierarchy. A locator instead can be saved and replayed to acquire the current AX element. With The trade-off of walking the locator path when the app hasn't changed.

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

Now, walking through a full mutation tool call, after the model called get_app_state for the app's AX tree and element IDs. It then decides to call the click tool on a checkbox element with ID e1.

The first step is to find the specified live element. The daemon loads the app’s latest snapshot from the snapshot store, and reselects the window on the live app.

It then uses the element’s saved traversal path and reapplies that path from the current live window. Starting at the live window, it finds the first AXGroup, and then the first AXCheckBox inside that group. Lastly it checks that the resulting element is still the expected element by comparing its role and label with the saved snapshot element.

If that path now points to a different element, the system returns a stale element error instead of operating, failing fast rather than continuing with the operation since the LLM's request was with stale state. The model then has to call get_app_state again to get the app’s latest state before its intended operation.

If instead the live element still matches the snapshot element, the operation continues and goes to shared mutation gates. These include per-app ownership leases, meaning each app works with one session, checking whether the screen is locked, recent user interference with this app, and confirmation requirements for risky actions.

The handler then captures the before state of this element before operating. In this example the live role is a checkbox, so we save its current value of 0 indicating the checkbox is unchecked.

For delivery, the click handler calls the AX action API that tells us which ax actions are supported by this checkbox, like pressing or confirming the checkbox. The handler sees that the checkbox supports the press action and asks the checkbox to perform that operation.

Even if the api call succeeds, the handler still needs to reread the live checkbox element for expected result. If its value changed from zero to one, the operation has direct evidence that the expected effect occurred. It then stops the delivery chain instead of trying another click strategy.

If none of the accessibility actions records the required evidence, the system moves to a coordinate fallback approach. The handler finds the accessibility element's center coordinates and constructs Core Graphics mouse-down and mouse-up events and sends them to the target applicaiton.

This fallback is secondary to AX action attempts and is especially helpful with applications that expose little accessibility information.

After delivery, the final verification path reselects the window, captures the resulting application state, and commits a new snapshot. The snapshot store calculates a diff of what was added, changed, or removed from the previous snapshot. And this diff is returned along with the selected delivery option and evidence of expected outcome back to the LLM.

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

The original perception and action loop worked reliably for one agent. As I
began using Computer Use MCP across multiple agent harnesses, independent agents
were now sharing mutable application state, which introduced a different class
of reliability problems.

With separate MCP runtimes, two agents could mutate the same application
concurrently. Retries created another ambiguity: if an agent clicked Send but
lost the response, blindly repeating the request could send the message twice.

Those conflicts required a shared coordination layer. I moved the computer-use
core and shared state behind one daemon. The daemon coordinates
application ownership and operation ordering, tracks sessions and operation
IDs, preserves snapshots, and deduplicates retries.

The trade-off is that daemon centralization adds lifecycle and recovery
complexity. The benefit is one source of coordination truth that prevents
racing operations and provides stable session identity and operation
idempotency.

---

## Slide 8 — Multi-agent concurrency and idempotency

### Visible slide

**Multi-agent concurrency and idempotency**

```text
The daemon: lifetime-held flock

Per app:
  current owner session
  active operation
  same-owner FIFO queue

Retry safety:
  session identity + operation UUID + recorded result
```

### Draft speaker notes

The daemon mainly provides three guarantees: only one coordinating daemon process across all agent sessions, one agent session per application, and saving session and operation attempts.

Every MCP proxy first tries to connect to the daemon's Unix socket. If no daemon exists, each MCP server spawns a daemon candidate racing to acquire a kernel advisory lock with flock.

The winning candidate acquires the advisory lock, becomes the single daemon, and holds the lock for its lifetime. On initial connections with the daemon, it assigns a unique session id for that new connection.

Each operation also has a unique ID generated by the MCP server and sent to the daemon during the request. The daemon has an operation registry acting as an idempotency store and records each request. If the client retries the same operation ID because a response was lost, the daemon can return the recorded result rather than repeating the operation.

The daemon also handles the main concurrency problem of app-level ownership, which was designed using a Swift actor as coordinator. For each application process id, the coordinator tracks the owner session, the active operation, and a FIFO queue of waiting operations from that same owner.

If the owner session submits another operation to the app, it waits in the queue, and gets completed in order.  If a non owner session tries to mutate an application that has an existing lease, it receives an APP_BUSY error and fails that operation.

We fail cross session requests explicitly here, because sessions do not have context on each other, and their operations might conflict

Another design considered was a heartbeat lease approach, but a correct implementation would need lease renewal, and fencing, and still needs a queue for operation ordering. The swift actor coordinator approach was much simpler while still providing the correctness guarantees needed.

---

## Slide 9 — From metrics to evals

### Visible slide

**From metrics to evals**

```text
Runtime telemetry → Where did time go?
OpenBench evaluation → Did the task succeed?

Known start → Agent run → External truth → Matched comparison
```

### Draft speaker notes

After multi-agent execution was reliable, the next question was how to measure
and evaluate performance, identify the main bottlenecks and priorities for
improvement, and know whether changes actually improved the system.

The daemon emits metrics including operation latency, AX-tree generation
latency, delivery and verification outcomes, and response size. These
measurements show where time and context are going, how often AX actions succeed
before Core Graphics fallback is needed, and which paths are producing errors.

But runtime metrics cannot independently tell me whether agents can complete
tasks correctly. To close that gap, I built an eval framework called OpenBench
as the evaluation layer for Computer Use MCP. It runs repeatable tasks, verifies
the resulting application state independently, and compares correctness,
latency, context, and token usage across implementation variants.

Together, runtime metrics and OpenBench create a repeatable improvement loop:
establish a baseline, identify a bottleneck, change one implementation variable,
and rerun the same tasks to measure whether correctness and performance actually
improved.

---

## Slide 10 — OpenBench computer-use evals

### Visible slide

**OpenBench computer-use evals**

```text
Task contract
instruction · harness/model · MCP build · timeout
             ↓
Codex + computer-use-mcp
       ↙               ↘
ComputerUseFixture     Evidence collectors
fixture-owned JSON     MCP ledger · token proxy · ATIF
       ↘               ↙
Deterministic checker
             ↓
correctness · latency · context · tokens
```

Matched A/B: hold the task constant; change one implementation variable

### Draft speaker notes

OpenBench is composed of a few key components. First, the task contracts, each task pins the instruction prompt sent to the agent for the task, harness and model selections, computer-use build versions, task environment setup for applications, and independent checker scripts that determines completion of task.

OpenBench's computer-use task set uses a ComputerUseFixture for its evals. The fixture covers different computer use test cases, including happy paths like a checkbox and a counter button, as well as edge cases including a text field that forces the fallback Core Graphics path through coordinates, and a button that never changes state. Whenever any of these controls are operated on, they write and persist the state change to a fixture-owned json file throughout the benchmark task.

After the agent marks task completion, the checker reads that JSON file directly and compares it with the expected state, and doesn't read the agent's response to judge for correctness.

OpenBench also preserves three complementary evidence streams. A MCP proxy sits in front of computer-use-mcp and records tool calls, arguments, latency, and response sizes. A token proxy sits between the agent harness and LLM providers and records model requests, timing, and token usage. Finally, an ATIF (Agent Trajectory Format) adapter normalizes each harness's event stream into a common trajectory of messages, tool calls, results, and reported usage.

Together, these evidence streams give me an end-to-end view of how the agent completed the task—which tools it called, where it spent time and tokens, and where it struggled. That lets me diagnose failures, identify bottlenecks, and make targeted product improvements.

---

## Slide 11 — Measured Improvement: Diff vs. Full State

### Visible slide

**Measured improvements: diff state vs. full state**

- Correctness: unchanged — 12/12 verified in both modes
- Model-visible state: **74.3% smaller**
- Complete response: **38.9% smaller**
- MCP latency: unchanged

### Draft speaker notes

One measured optimization was returning snapshot diffs after a mutating
operation. The previous implementation regenerated and returned the full
Accessibility tree after every operation. The hypothesis was that returning
only what changed would reduce model context without reducing task correctness.

I ran matched A/B trials where the full-tree implementation was the baseline
and the second implementation returned snapshot diffs. Each trial used the same
fixture, tasks, agent configuration, and deterministic checker.

The MCP proxy measured Accessibility tree text falling from 2,142 bytes to 551
bytes, a 74.3 percent reduction. Both implementations completed the same 12
verified mutations.

This demonstrates the improvement loop: identify a suspected bottleneck, change
one implementation variable, preserve correctness, and measure the resulting
impact. The next step is expanding that evidence across more applications,
controls, and workflows.

---

## Slide 12 — Learnings and next steps

### Visible slide

**Learnings and next steps**

**Lessons**
1. Simple systems are easier to maintain and extend
2. Metrics make performance actionable
3. Ship iteratively and dogfood the product

**Next**
Broader benchmarks · Incremental AX · Windows

### Draft speaker notes

This product evolved through three stages: reliable background computer use
with one agent, safe and ordered execution across multiple agents, and an
evaluation layer that makes performance measurable.

Three lessons stood out.

Simpler systems are easier to maintain and extend. Computer use can quickly
accumulate fallback paths, so I optimized for one clean execution path and added
complexity only when observed failures justified it.

Metrics make performance actionable. Runtime metrics show where latency and
context are going, while the evaluation layer connects those measurements to
task correctness and validates whether changes improve the system.

Finally, ship iteratively and dogfood the product. Real usage and feedback
exposed the next problems to solve instead of requiring every distributed-systems
mechanism to be designed upfront.

The next stage expands the product in three directions.

Evaluation coverage needs to grow across more applications, controls, and
multi-agent cases.

Perception can become more efficient. Today, the system rebuilds the full AX
tree. AX observer notifications could invalidate changed parts of a snapshot
and refetch only those elements, while falling back to a full rebuild whenever
freshness is uncertain.

Platform support can expand beyond macOS. The core contracts for snapshots,
coordination, verification, and measurement can remain platform-neutral while
browser and Windows implementations provide their own perception and input
layers.

Overall, Computer Use MCP evolved from a single-agent control loop into a
multi-agent runtime with durable targeting, ordered mutations, retry safety, and
a measurement loop for improving correctness and performance.
