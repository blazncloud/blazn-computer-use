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

Thanks for having me. Today I’m going to talk about Computer Use MCP, a
project I built over the last several months.

The project gives agent harnesses an agent-agnostic way to use local computer use on Macs.
I initially built it to solve my own problem of having local computer use available for any coding agent harness I use. As I developed it further and tweeted about building this idea out, I got feedback from similar users and developers who were looking for local computer use for all of the agent harnesses they use, and continued to iterate to make computer use more productionized across reliability, concurrency handling, and performance.

---

## Agenda

### Visible slide

1. Background
2. Core Function
3. Key Decisions
4. Testing
5. Takeaways & Next Steps

### Draft speaker notes

I’ll start with why I think computer use matters and why I decided to build computer-use-mcp, show the current product and architecture, and
then go into a few deep dives: perception and targeting, one complete
mutation in steps, and multi-agent concurrency. I’ll finish with how I built an evaluation framework to complete the loop of benchmarking the computer use implementation, and using measurements
as evidence to drive further improvements. Ending with results, learnings and next priorities.

---

## Slide 2 — Why computer use?

### Visible slide

**Why computer use?**

- A feedback loop at the user surface
- Existing software becomes an agent interface
- Professional workflows become automatable

### Draft speaker notes

One of the most important concepts of developing with agents is a feedback loop,
giving agents the tools access to verify and check its output, then continue to adjust
for next steps and improvements.

My initial use case
was asking my agents to use computer use to test out their changes especially on the frontend, and
complete that feedback loop.

For example while building Pi-GUI, a codex app
for the Pi agent, computer use let the agent open the running product, click through the threads and go through the same
workflow as a user, inspect the results or issues, and continue iterating.

I then started applying computer use for work outside of coding, and realized how useful computer use
is for automating other parts of my life, which allows me to focus more time on my interests and priorities.
Now when I want to configure different app settings, Codex helps me configure those settings. Or when I need to
complete any errands like receipt expensing or visa applications, computer use helps me complete.

The issue was that I use agent harnesses other than Codex, like Claude Code, Cursor, and Devin, but none of them had local computer use that also worked in the background. That's when I decided to build my own agent-agnostic  version.

I think the longer-term opportunity is much broader than software development. Most non-coding
professional work still happens through desktop applications. If agents
can operate those interfaces reliably, non-technical users can automate work
across finance, accounting, operations and many
other existing systems.

My personal belief is that, as model reasoning and computer-use speed improve,
agents will eventually perform this work faster than humans can
operate the computer manually. The missing pieces are making the capability
dependable and creating an interface that fully showcases the capabilities of computer use.

---

## Slide 3 — Demo

### Visible slide

**Demo**

Two agents · Two applications · One shared computer-use layer

### Draft speaker notes

Here is where my computer use currently stands.

In this recording, I start two different agent harnesses. One opens System
Settings and inspects the machine’s storage configuration. The other opens Notes
and drafts a message. I continue working in my foreground application while both
agents operate different apps in the background.

Each agent has its own overlay cursor, so I can see which session is acting and
where without giving either one control of my real pointer.

The important result is not the individual clicks. It is that different agent
harnesses use one common interface, and work on separate applications concurrently in the background.

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

The current architecture starts off with the MCP compatible agent harnesses at the top layer. Each harness launches a thin MCP server
process and communicates through standard IO. The MCP server defines the agent-facing
contract but does not own the independent computer-use engine, most similar to a proxy.

The MCP server forwards requests over a local Unix socket to the shared daemon instance, which is the central coordination service. It owns tool dispatch, snapshots of different app's state in tree like structures, and per-application lease ownerships so that each application only has one agent mutating it at one time.

Each snapshot preserves the state of an application and window in an accessibility tree structure, representing the structure of the app's elements, stable
IDs for each element, and locator paths that save the traversal path from the root of the app to each individual element.

Below the daemon are the macOS services that perform the operations on the computer. AppKit, Apple's native GUI framework, helps identify running GUI
applications. The Accessibility APIs expose app elements and element accessibility actions, like clicking a button or setting the text value of a text box.
ScreenCaptureKit captures the screenshot for the selected window. Core Graphics provides a fallback
coordinate-based input path when an application does not expose enough useful
accessibility behavior. Basically sending mouse and keystroke events at specific coordinates.

Alongside the runtime, I built OpenBench, an evaluation framework that helps me
identify performance bottlenecks, use deterministic checks to measure whether
tasks actually completed, and compare implementation variants across repeatable
tasks.

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

The model starts by calling the `get_app_state` tool and passes the application it wants to
inspect.

The daemon first calls `libproc` to find all the available process IDs and resolves the passed-in application name
to its corresponding process ID and `NSRunningApplication`. It then creates a proxy reference to that application through `AXUIElementCreateApplication` with the app's process
ID, which allows us to look into the application's windows and elements.

Starting from the application root, the system reads accessibility attributes to find the
available windows.
And a snapshot is initialized for this app recording the process ID, bundle identifier, process start time, and
window ID. Together these identify the exact process and window the snapshot came
from.

ScreenCaptureKit is then used to capture a screenshot of that window, which later gets returned to the LLM for visual context and reference.

Next, the daemon constructs the Accessibility tree. Starting from the selected
window, it reads each element's `AXChildren` attribute and recursively visits
those children. For every visited element it reads fields such as role, label,
value, and saves them for the snapshot as well.

As it walks from the selected window root, each
element also records the traversal path used to reach it.

In this example, the checkbox is represented by the path `AXGroup zero, then
AXCheckBox zero`, where the traversal path indicates the index among siblings within the same
role.

The model receives the text representation of the AX tree and screenshot to provide the context for deciding the next
actions.

The persisted snapshot serves a different purpose. Its element entry keeps
the ID, role, label and tree traversal path, where the traversal paths are mainly used to relocate
the same element in future states.

The snapshot persists paths instead of the direct AX element because AX elements are
references to the underlying AX node of the application. Applications
frequently destroy and recreate their accessibility nodes during rerendering.
which would make the snapshot invalid if we used AX elements.

Before a mutating operation, the daemon finds the element's path in the latest snapshot, and replays that path against the current
live window, obtaining a fresh ax element reference, and checks its role and label. If the element at that path
doesn't have the same role and label as the one saved in the snapshot, the operation fails with a stale error instead of
clicking an outdated target, telling the LLM it needs to re-query `get_app_state` for the app's new state.

<!-- There are two important trade-offs in this design.

First, AX actions are more stable and reliable for background use than
relying on Core Graphics events with pixel coordinates. Core Graphics events are still valuable
for applications with poor AX labels, but they are not the
primary choice of operating computer use.  -->

The tradeoff with this design is that traversal paths make snapshots more reusable across app rerenders, as opposed to
using AX element references. The downside is when
app's do not change state we still need to walk through the path to find the element.

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

Now, walking through a full mutation tool call, suppose the model finished calling `get_app_state`,
which returned the app's AX tree and element IDs. It then decides to call the click tool
on a checkbox element with ID `e1`.

The first phase is to resolve the live element. The daemon loads the snapshot
entry, reselects its recorded window, and replays the locator path against the
live Accessibility tree. If the resulting element no longer has the expected
role and label, it fails with a stale-element error before delivering input.
The model must then call `get_app_state` again to get the application's latest
state before choosing another target.

If instead the live element still matches the snapshot element, the operation continues and goes to shared
mutation gates. These include per-app ownership leases, meaning each app works with one session, checking whether the screen is locked, recent human
interference with this app, and confirmation requirements for risky
actions.

The handler then captures the before state for this specific action. In this example the
live role is a checkbox, so we save its current value of 0 indicating the checkbox is unchecked.

For delivery, the click handler calls the AX action API that tells us which ax actions are supported by this checkbox,
like pressing or confirming the checkbox. The handler sees that the checkbox supports the press action and asks the checkbox
to perform that operation.

The AX api call acks and tells us the delivery of the api call, but the handler still needs to reread the live
checkbox element for evidence. If its value changed from zero to one, the operation has
direct evidence that the expected effect occurred. It then stops the delivery chain
instead of trying another click strategy.

Verification depends on the control: focus for a text field, selected state for
a toggle, and value for text. If AX delivery cannot produce evidence, the
handler can fall back to coordinate-based Core Graphics input and verify through
the same evidence.

After delivery, the final verification path reselects the window, captures the
resulting application state, and commits a new snapshot. The snapshot store calculates a diff of what was
added, changed, or removed from the previous snapshot.
And this diff is returned along with the selected delivery option and evidence of expected outcome back to the LLM.

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

I started off with the core perception and delivery lifecycle we just went over, and it worked well for a single agent session,
but when I started running computer use across multiple agents and different harnesses I started running into concurrency issues that forced an architecture change.
With independent MCP processes, two
agents can try to perform mutating operations on the same app and cause race conditions.

Retries introduced another form of ambiguity. If an agent clicked a send button, but lost
the response, blindly repeating the request could send the message twice.

I moved the computer-use core and shared state behind a daemon. The
MCP servers became small forwarding proxies. This created one service to manage
application ownership, track sessions and operation IDs, preserve
snapshots, and deduplicate retries.

The trade-off with daemon centralization adds lifecycle and recovery complexity. The benefit is
that all agents now operate against one source of coordination truth, preventing racing mutation operations
while providing session and operation idempotency.

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

The daemon mainly provides three guarantees: only one coordinating daemon process,
one agent session per application, and saving session and operation attempts.

Each MCP proxy first tries to connect to the daemon's known Unix socket. If no
daemon is listening, it launches a candidate. Competing candidates race for a
lifetime-held `flock`; the winner holds it until the daemon exits, preserving a
single coordination authority.

The daemon tracks a stable session identity, and each operation has a unique ID.
The operation registry records terminal results, so retrying the same operation
returns the previous result instead of repeating a side effect.

Now that each session and operation has a durable identity, the main
concurrency problem is app-level ownership, which was designed using a Swift actor as coordinator. For each
application process id, the coordinator tracks the owner session, the active operation,
and a FIFO queue of waiting operations from that same owner.

If the same session submits another operation to the same app, it waits in the
queue. When the active operation finishes, the coordinator resumes the next one in the queue,
and they complete serialized.

I chose to fail cross-session requests explicitly. If another session targets
an app that already has an owner, it receives an `APP_BUSY` error rather than
waiting in the queue. By the time the first session finishes, the second
session's perception may be stale. Failing fast forces that agent to observe the
current application state again before acting.

The central guarantee is therefore one mutating operation at a time per
app, and ordering of operations from one session.

Another design considered was a heartbeat lease approach, but a correct implementation would need lease renewal,
and fencing, and still needs a queue for operation ordering. The swift actor coordinator approach was much simpler
while still providing the correctness guarantees needed.

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

Now that the system was more reliable for multi-agent and concurrent handling, the
next question was how to measure and evaluate performance, identify the
main bottlenecks and priorities for improvement, and determine whether implementation changes
actually produced the targeted improvements.

The daemon emits structured operation and perception metrics: including latency of operation execution,
AX-tree generation latency, and response size bytes.
A metrics recorder helps collect and persist these metrics so that we can
use measurements to answer questions such as: Is time being spent on
traversing and generating the Accessibility tree, or delivering input? How often do AX
calls succeed before Core Graphics fallback is needed? How large are the responses sent back to the LLM,
and how does that affect the agent's context window?

Other than tracking live metrics to see how our implementation was doing in terms of latency and context,
I wanted benchmarks that helped me evaluate how different implementations performed in terms of correctness and ability to complete different tasks.
 That would allow me to explore alternative implementations or features and A/B test them across my benchmarks to ensure there is no degradation in task completion rate.

That gap led me to learn and build from scratch my evals framework called OpenBench, which allows me
to benchmark my computer use across tasks and different implementation variants. The evals help create a
repeatable loop: starting off with a baseline implementation, I'd run the computer use through
task sets, and collect artifacts for each run including whether the agent successfully completed the task,
end-to-end wall time, token spend, and agent trajectories. Then I'd evaluate a bottleneck to improve, make corresponding implementation changes,
and rerun the task set against this new implementation to compare the results from the baseline.

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

OpenBench is composed of a few key components to perform benchmarks. First, the task contracts,
each task pins the instruction prompt sent to the agent for the task, harness and model selections, computer-use
build versions, task environment setup for applications, and independent checker scripts that determines completion of task.

OpenBench's computer-use task set uses a ComputerUseFixture for its evals. The fixture covers
different computer use test cases, including
happy paths like a checkbox and a counter button, as well as edge cases including a text field that forces
the fallback Core Graphics path through coordinates, and a button that never changes state.
Whenever any of these controls are operated on, they write and persist the state change
to a fixture-owned json file throughout the benchmark task.

After the agent marks task completion, the checker reads that JSON file directly and compares it with the expected
state, and doesn't read the agent's response to judge for correctness.
The checker script then outputs a 1 for success, anything else is considered a failure, but the checker script can also have partial credit.

OpenBench preserves three complementary evidence streams. An MCP collector
proxy records ordered computer-use tool calls, arguments, matched responses,
latency, and response sizes. A token proxy records model requests, timing, and
token usage. An ATIF adapter converts each agent harness's event stream into one
normalized trajectory of tool calls, results, and reported usage.

Together these streams explain how the agent behaved and where time, calls, and
tokens went. The deterministic fixture checker remains the independent measure
of whether the task completed correctly.

---

## Slide 11 — Measured Improvement: Diff vs. Full State

### Visible slide

**Measured improvements: diff state vs. full state**

- Correctness: unchanged — 12/12 verified in both modes
- Model-visible state: **74.3% smaller**
- Complete response: **38.9% smaller**
- MCP latency: unchanged

### Draft speaker notes

An example of using benchmarks was implementing snapshot diffs to return to the LLM after a mutating operation. Previously I would regenerate the full
accessibility tree after each operation to return to the LLM. I wanted to test whether returning a snapshot diff, comparing new snapshot and old snapshot,
would reduce model context bloat without changing correctness.

I ran A/B test trials where the full tree implementation was the baseline,
and a second implementation returned snapshot diffs. Each trial used
the same computer-use fixture, ran through the same tasks, and passed the same
deterministic checker for success.

The MCP collector showed that accessibility tree text fell from 2,142 bytes to 551 bytes,
a 74.3 percent reduction. Median complete response size fell from 4,429 bytes
to 2,704 bytes, a 38.9 percent reduction.

and MCP latency stayed the same because both implementations still rewalk the full AX tree.

This is just one example of a computer use eval, and we'd need to scale this up to many different tasks
across different types of apps and actions. But it demonstrates the ability of OpenBench to help close the feedback loop
so that I can continue to evaluate and prioritize improvements to Computer Use MCP.

---

## Slide 12 — Learnings and next steps

### Visible slide

**Learnings and next steps**

**Lessons**
1. Simple systems are easier to maintain and extend
2. Agent concurrency requires identity and ordering
3. Improvements require deterministic evaluation

**Next**
Broader benchmarks · Incremental AX · Windows

### Draft speaker notes

The project evolved through three distinct problems: first, reliable computer use in the background with one agent;
second, concurrency handling to be reliable and safe across multiple
agents; third, creating an eval framework to close the feedback loop and evaluate performance.

The first lesson is that simpler systems are easier to maintain and extend.
Computer use can accumulate fallback paths and concurrency states quickly, so I
optimized for one understandable execution path and only add complexity when
observed failures justify it.

The second lesson is to ship early and dogfood the product. The single-agent
implementation let me validate the core capability quickly. Using it across
multiple real agent sessions then exposed the concurrency problems that led to
stable identity, the shared daemon, and per-application ordering. Real usage
showed me what to build next instead of designing every distributed-system
mechanism upfront.

The third lesson is that evaluations require deliberate task design and
deterministic checks. Internal metrics explain how the system behaved, but the
fixture's resulting state determines whether the task actually succeeded.

There's still a lot of work I'm planning on improving for computer-use-mcp. My first priority is a broader OpenBench coverage across more applications
and control types.

The second is more efficient perception. Today, a fresh state response rebuilds
the full AX tree. Similar to how I think Codex handles it, I would build a monitor through AX observer notifications
that helps me invalidate parts of my snapshot that have changes in state.

The third is expanding platform support. Right now computer-use-mcp is focused on Mac surfaces,
but there's also browser use and other operating systems like Windows.
The core principles like snapshot trees, concurrency handling, verification, and metrics layers can be built as platform
neutral interfaces, while each platform will have specific implementation details like DOM and
Windows UI handling.

The result today is a working multi-agent computer-use mcp and, equally
important, becnhmarks to help to make it more reliable and
efficient from measured evidence rather than intuition.
