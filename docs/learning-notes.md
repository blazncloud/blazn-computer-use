# computer-use-mcp Learning Notes

These are the canonical notes for understanding the product. They intentionally
describe each major flow once; later sections explain the underlying state,
concurrency, macOS frameworks, and secondary workflow features.

## One-sentence model

`computer-use-mcp` is an MCP stdio server that forwards tool calls to one shared
macOS automation daemon, which combines Accessibility semantics with screenshots,
performs guarded actions, verifies the observed result, and returns structured
evidence to the agent.

## Components and processes

```text
Agent / LLM
  │ MCP tool calls over stdio
  ▼
serve shim (one per MCP connection)
  │ DaemonClient + Unix-domain socket
  ▼
shared daemon (one per logged-in user)
  ├─ tool dispatch, policy, snapshots, AX, input, verification
  └─ AgentCursor actor
       │ small text commands over named FIFO
       ▼
     overlay helper (one optional AppKit process)
```

- **Serve shim:** publishes the MCP tool catalog and converts MCP calls/results
  to and from the daemon protocol. It does not itself automate applications on
  the normal daemon-backed path.
- **DaemonClient:** one Swift actor in each serve process. It owns one socket
  connection, assigns request IDs, stores the waiting continuation for each
  request, reads responses, and resumes the continuation with the matching
  response ID. Multiple RPCs can therefore be in flight on one connection.
- **Daemon:** the shared automation engine. It accepts connections, authenticates
  them, creates concurrent Swift tasks for requests, applies shared gates, and
  runs handlers.
- **Overlay helper:** optional cosmetic process that draws virtual cursors. It
  never performs the real action and never moves the physical pointer.

## Canonical key flows

### 1. Tool discovery and lazy daemon startup

1. The MCP host starts the binary in `serve` mode and communicates over stdio.
2. MCP initialization and `tools/list` expose the static catalog from
   `Tools/Catalog.swift`: tool names, descriptions, JSON input schemas, and MCP
   annotations.
3. Tool discovery does not require the daemon.
4. On the first actual tool call, `DaemonClient` tries the daemon Unix socket.
5. If nothing is listening, it starts a daemon candidate and retries for up to
   five seconds.
6. Concurrent candidates all attempt a non-blocking exclusive `flock` on
   `daemon.lock`. One keeps the lock for its lifetime; losers exit.
7. Clients whose candidates lost keep retrying the socket and connect to the
   winner.
8. Client and daemon authenticate using the local secret and perform a version
   handshake before normal calls are accepted.

`flock` is a kernel advisory lock attached to an open file descriptor. The
kernel automatically releases it when the owning process exits or crashes.
The lock coordinates daemon creation; clients do not acquire it for ordinary
socket connections.

### 2. Unix socket, sessions, file descriptors, and requests

A Unix-domain socket is a local kernel communication channel addressed by a
filesystem path. The bytes travel through kernel buffers, not through the
`daemon.sock` directory entry itself.

1. The daemon creates one listening socket during startup.
2. Each successful `accept` creates a new connected file descriptor in the
   daemon.
3. Each serve shim has its own connected file descriptor for its side of that
   connection.
4. A file descriptor is simply a small integer indexing an open kernel resource
   in that process. The client and daemon descriptor numbers need not match.
5. After authentication, the daemon assigns a logical session UUID and resume
   token. The socket FD identifies one connection, not the agent session.
6. A reconnect to the same daemon can present the resume token and recover the
   same logical session. A daemon restart creates a new incarnation and new
   session world.
7. Each call has a transport request ID plus an operation UUID. The request ID
   matches one response on one connection; the operation UUID provides mutation
   identity and deduplication across a safe reconnect/retry.
8. A write lock prevents concurrently finishing tasks from mixing their JSON
   response bytes on the same connection.
9. `DaemonClient` matches each response ID to its pending continuation. On
   timeout or disconnect, it fails the affected pending request or all requests.

The task registry is bookkeeping, not an execution queue: it tracks active
tasks so they can be cancelled or cleaned up. Swift's concurrency runtime
schedules the tasks; macOS ultimately schedules the worker threads.

### 3. `list_apps`: discover running GUI applications

1. Dispatch validates the tool call and invokes the `list_apps` handler.
2. The daemon calls the macOS `proc_listallpids` C API to obtain current process
   IDs. This is an operating-system API from `libproc`, not a shell command.
3. For each PID, AppKit attempts to create an `NSRunningApplication`.
4. Processes whose activation policy is `.prohibited` are removed. The
   user-facing list emphasizes `.regular` GUI applications.
5. The result contains names, bundle identifiers, PIDs, and basic running state.
6. The agent chooses the application identifier for a later tool call.

`NSRunningApplication` belongs to **AppKit**, not CoreGraphics. It describes a
running application: PID, name, bundle ID, activation policy, hidden/active
state, and executable information. It is not the Accessibility tree.

### 4. `get_app_state`: construct perception state

1. Resolve the caller's app string against fresh `NSRunningApplication` records.
2. Produce a `ResolvedApp` containing PID, name, and bundle ID.
3. Create its Accessibility root with `AXUIElementCreateApplication(pid)`.
4. Select one AX window using the optional requested title, otherwise the
   product's main/focused/window fallback rules.
5. ScreenCaptureKit finds and captures the corresponding visual window.
6. The tree builder recursively reads the live AX hierarchy for that window.
7. It records nested nodes containing ID, the live AX handle, semantic facts,
   screenshot-relative frame, parent/children, and model-facing state hints.
8. `SnapshotStore` commits the snapshot and calculates stable IDs/diffs against
   the previous compatible snapshot.
9. The MCP result returns the semantic outline and element IDs plus the
   screenshot unless state/image options exclude it.

ScreenCaptureKit returns pixels; it does not return the AX tree. AX returns
global frames in logical macOS points. The product computes the screenshot's
pixels-per-point scale so it can draw AX boxes on the screenshot and convert
visual coordinates back to global screen points.

### 5. A normal element-based click

Assume the agent chooses `e12@s3`, the Checkout button returned previously.

1. **Call and authentication:** the serve shim forwards the request to the
   daemon, which verifies that the socket connection completed its authenticated
   handshake.
2. **Operation and coordinator admission:** the daemon operation registry
   deduplicates the operation UUID. The per-app coordinator grants operation-
   scoped ownership, queues same-session work FIFO, and returns `APP_BUSY` to a
   different session rather than letting mutations interleave.
3. **Dispatch and shared safety:** dispatch resolves the catalog handler, rate
   limits/logs the call, then checks screen lock, recent human input, and URL
   policy. The handler subsequently applies confirmation and other
   operation-specific safety rules.
4. **Load identity:** use the PID plus element ID to load the captured node and
   its exact retained `AXUIElement` handle from the in-memory snapshot.
5. **Validate window:** require the retained AX window to remain valid, owned by
   the same live process, present in that application's current `AXWindows`, and
   matched to the captured `CGWindowID`.
6. **Validate target:** read the handle's role and stable semantic fingerprint,
   then require its `AXWindow` or bounded `AXParent` chain to reach the retained
   window. There is no locator-path replay or replacement search.
7. **Stale handling:** if the handle is invalid, changed, or detached, return a
   stale-element error. The agent must query fresh state and choose a current ID.
8. **Before evidence:** read target-local fields appropriate to the intent:
   value preview, selected/toggled state, focus, window title, and relevant
   fingerprints.
9. **Visual glide:** derive a point, normally from the live AX frame, and send a
   `move` command through the `AgentCursor` actor to the overlay FIFO. The actor
   serializes its FIFO descriptor/process state. It then waits a fixed 160 ms;
   there is no completion acknowledgement from the overlay.
10. **Plan one delivery:** inspect capabilities before mutation and choose one
    route. For click this is one pressable self/ancestor or one synthetic click;
    for text and scroll it is one supported attribute/action/input route.
11. **Deliver once:** an acknowledged AX call never falls through to another
    semantic action or synthetic input. Unsupported preflight capabilities may
    select another route because nothing was sent yet.
12. **Observer-assisted verification:** a short-lived observer is installed
    before dispatch. Reread immediately, after relevant notification wakes, and
    once at the one-second deadline. Notifications are hints; exact target state
    is proof.
13. **Pulse:** after delivery, send `pulse` to draw an expanding ring showing
    “the click happened.” It is feedback, not a pending indicator.
14. **Final recapture:** reselect the window, optionally recapture pixels,
    rebuild the AX tree, commit the new snapshot, and calculate a tree diff.
15. **Final target reread:** revalidate the exact retained handle and
    reread the fields required by the action intent.
16. **Outcome:** deterministic Swift rules return `success`, `unsupported`,
    `effect_not_verified`, or `verifier_ambiguous`, plus human-readable content,
    structured evidence, the new state/diff, and recovery guidance.

If no snapshot exists, an element-ID action fails with guidance to call
`get_app_state`. Coordinate-only tools can use their own documented path, but
they provide weaker target identity and verification.

## Why validate and reread after an action?

A current snapshot retains the exact live `AXUIElement`. Applications can
destroy and recreate AX objects during a relayout, so retention alone is not
proof that a target remains safe.

- **Validate** means read the retained handle's role and semantic fingerprint,
  check its PID, and prove it is still attached to the captured window.
- **Reread** means ask that live object for current fields such as `AXValue`,
  `AXSelected`, or `AXFocused`.

This answers two separate questions:

1. Does the intended control still exist and still match the saved identity?
2. Did its meaningful state actually change as requested?

For example, a checkbox click is stronger when the current checkbox can be
validated and `AXValue` changed from `0` to `1`. If the app replaced or removed
the target, the verifier reports ambiguity instead of claiming success.

## Main Accessibility APIs

| API | Purpose in this product |
|---|---|
| `AXUIElementCreateApplication(pid)` | Creates the AX root handle for one running application. |
| `AXUIElementCopyAttributeValue` | Reads one attribute, such as windows, children, role, title, value, position, size, focused state, or selected state. |
| `AXUIElementCopyAttributeNames` | Lists the attribute names exposed by an element. |
| `AXUIElementCopyActionNames` | Lists semantic actions the element advertises, such as `AXPress`. |
| `AXUIElementPerformAction` | Requests one advertised semantic action. |
| `AXUIElementIsAttributeSettable` | Checks whether an attribute such as `AXValue`, `AXSelected`, or `AXFocused` can be changed. |
| `AXUIElementSetAttributeValue` | Changes a settable attribute, for example text, focus, selection, or window position. |
| `AXUIElementCopyElementAtPosition` | AX hit-tests a global screen point to find the element under it; primarily useful for coordinate interpretation and teach mode. |
| `AXUIElementSetMessagingTimeout` | Bounds how long an unresponsive target application may block an AX query. |

The tree is formed by repeatedly reading attributes such as `AXWindows` and
`AXChildren`; there is no single “return the entire AX tree” call.

## Snapshot identity, storage, and cleanup

- Snapshots are keyed by **process identity plus window identity**.
- `SnapshotStore` holds:
  - one current in-memory snapshot per process/window;
  - per-PID generation counters;
  - ID→node and AX-handle→ID indexes.
- Generations are therefore per PID: app A may have `s3` while app B also has
  its own `s3`.
- Element IDs include generation, for example `e12@s3`. The app/PID supplied to
  the tool scopes which app's `s3` is meant.
- The same Core Foundation AX handle can retain its earlier ID across captures.
  Recreated handles become remove/add entries.
- Scoped or incomplete captures keep unobserved live nodes only in private
  lookup indexes; they do not add those nodes to the new model-facing tree.
- The `SnapshotStore` actor serializes generation allocation and cache updates.
- Snapshots are not written to disk. A daemon restart starts with fresh state.

## Cursor overlay: transport, animation, and locking

The precise model is:

```text
action handler
  → AgentCursor Swift actor
  → atomic line written to overlay.cmd named FIFO
  → singleton overlay helper reads FIFO
  → command dispatched to AppKit main thread
  → NSPanel + Core Animation draw session cursor/pulse
```

- `overlay.cmd` is a **named FIFO**, not a normal stored command file. Its
  directory entry names a kernel byte stream.
- Writes are tiny newline-delimited commands such as `move`, `pulse`, `ping`,
  `record`, and `drop`.
- FIFO means first-in, first-out at the byte-stream level. Small writes are
  atomic, and the helper parses complete lines.
- The overlay helper creates transparent, borderless, click-through `NSPanel`
  windows with animated `CALayer` content.
- It stores independent cursor state and visual layers by daemon session ID.
- The helper's AppKit main thread serializes mutation/drawing of those states.
- `AgentCursor` is one daemon-side actor protecting its local FIFO write
  descriptor and spawned-helper process state; it is not one actor per session.
- `overlay.lock` uses lifetime `flock` similarly to the daemon lock, but only to
  guarantee one helper process. It does **not** order commands or provide a
  per-session action lock.
- The animation duration is distance-based, approximately 120–320 ms. The
  daemon's fixed 160 ms wait can finish before or after the visual glide. There
  is currently no acknowledgement channel.
- A pulse is a 450 ms expanding/fading ring at the delivered action point.
- Overlay failures are intentionally best effort and never fail the real action.

## Concurrency and synchronization

### Swift actors

A Swift actor owns mutable state that may only be accessed through its
isolation. Calls from multiple tasks become queued **jobs** for the actor's
executor.

- Only one job executes actor-isolated synchronous code at a time.
- An actor method is not necessarily atomic from beginning to end.
- At `await`, it can suspend; another queued job may run and change actor state
  before the first method resumes. This is actor reentrancy.
- A read/check/write sequence with no intervening `await` is serialized as one
  uninterrupted actor job.

Relevant actors:

- `DaemonClient`: socket state, request ID allocation, pending continuations,
  timeouts, and reconnection.
- `SnapshotStore`: per-PID snapshot counters, cache/history, and persistence
  decisions.
- `AppMutationCoordinator`: app owner and same-session waiter queues.
- `DaemonOperationRegistry`: active/completed operation IDs, cancellation, and
  deduplicated results.
- `MetricsRecorder`: in-process metric aggregation before cross-process file
  persistence.
- `AgentCursor`: FIFO descriptor and helper-process connection state.

Actors serialize access to their own state. They do not automatically serialize
the entire external operation performed after the actor returns.

### Locks and their exact roles

| Primitive | Protects | Does not protect |
|---|---|---|
| `daemon.lock` lifetime `flock` | Singleton daemon election | Requests or app mutations |
| `overlay.lock` lifetime `flock` | Singleton overlay helper election | FIFO ordering or cursor sessions |
| ScreenCapture cross-process lock | Capture subsystem use across processes | AX tree creation |
| Metrics file `flock` | JSONL append + aggregate-summary update across processes | Tool execution or daemon coordination |
| Mutation sequencer `NSLock` | Same-session/app request order before concurrent tasks schedule | External application state |
| `RunningApplicationsCache` `NSLock` | One-second cached application list | Application actions |
| Daemon response `NSLock` | JSON writes on one socket connection | Handler execution |
| Recorder `NSLock` | Recorder event buffer/state shared with CG event-tap callback | Other sessions mutating the app |

### Per-app mutation coordination

The previous renewable lease was replaced with operation-scoped ownership:

```text
canonical app identity → {owning logical session, active operation, FIFO waiters}
```

- Same logical session and app: requests execute FIFO.
- Different logical session while owned: return `APP_BUSY` immediately.
- Different apps: continue concurrently.
- Safe reads remain outside the mutation coordinator.
- Ownership lasts until the active operation releases it; there is no expiry or
  heartbeat window that can lapse mid-operation.
- Disconnect cancels queued work. Active work uses cooperative cancellation and
  releases ownership from its completion path.

## Safety and dispatch

The shared path is:

```text
MCP catalog/schema boundary
  → daemon authentication/session
  → operation registry + per-app mutation coordinator
  → rate limit and shared dispatch preflights
  → screen-lock and recent-human-input checks
  → URL hard-deny policy where relevant
  → deterministic confirmation policy
  → handler-specific safety
  → action handler
```

- URL denies are local deterministic configuration/policy, not chosen by the
  LLM. Confirmation cannot override a hard deny.
- `confirm:true` is checked by deterministic Swift safety policy for operations
  classified as sensitive. Handler-specific checks supply context such as the
  target label, secure field, key chord, clipboard write, or window operation.
- Human interference uses CoreGraphics timing information for recent physical
  keyboard/mouse events. It is a dispatch-time gate, not continuous cancellation
  throughout every running handler.
- MCP annotations describe broad tool properties to callers, such as read-only,
  destructive, or idempotent hints. They guide clients but are not the product's
  enforcement boundary.

## macOS services: shortest useful map

| Framework/API | Normal macOS role | Use here |
|---|---|---|
| Accessibility / `ApplicationServices` | Assistive inspection and semantic control of UI | AX tree, roles/labels/state, frames, hit testing, semantic actions, verification |
| AppKit | Native apps, windows, screens, events, application lifecycle | `NSRunningApplication`, window/event metadata, overlay `NSPanel` UI |
| CoreGraphics | Screen geometry, images, low-level events, event taps | Synthetic mouse/keyboard/scroll, physical-input observation, recorder, coordinate geometry |
| `NSEvent` in AppKit | Higher-level event object with window-local metadata | Bridge a CG event through a specific window number before PID delivery |
| ScreenCaptureKit | Enumerate and capture shareable windows/displays | Screenshot pixels aligned with AX state |
| Vision | Image analysis and OCR | Optional recognition of text absent from AX |
| QuartzCore / Core Animation | GPU-backed layer composition and animation | Virtual cursor glide, pulse, opacity, and session labels |
| `libproc` | Low-level process enumeration/information | `proc_listallpids` for fresh PID discovery |
| Unix sockets / FIFO / `flock` | Kernel IPC and advisory locking | Client-daemon RPC, daemon-to-overlay commands, singleton election |
| SkyLight prototypes | Private window-server event routing | Guarded window/PID-targeted synthetic input support |

Preferred action hierarchy:

```text
semantic AX action
  → window-targeted synthesized CG event using NSEvent metadata
  → PID-targeted CG event
  → explicitly permitted global CG event
```

## Skills, teach mode, and replay

This is secondary to the core computer-use path:

1. Teach mode starts one daemon-wide recorder for a selected app.
2. A listen-only CoreGraphics event tap observes supported physical clicks,
   key-down events, and scroll events.
3. For clicks, AX hit testing maps the physical global point to a semantic
   element and captures a durable locator when possible.
4. Deterministic code coalesces events into draft skill steps. The recorder
   observes interaction, not user intent, so the draft needs review.
5. Skills persist as parameterized JSON under
   `~/Library/Application Support/computer-use-mcp/skills/`.
6. Replay resolves locators against fresh state and executes steps
   sequentially, stopping on the first failure with structured verdicts.

Skills store locators, roles, labels, parameters, and expectations rather than
ephemeral element/snapshot IDs. Snapshot IDs describe one transient UI
generation and would make a saved workflow brittle.

## Concise comparison with Codex Computer Use

Both implementations use the same basic architecture:

```text
MCP-facing client
  → shared native macOS automation service
  → screenshot + Accessibility state
  → AX action or synthesized input
  → updated state
```

Important differences:

- **Concurrency:** both designs serialize app mutations. Our daemon uses logical
  session/app FIFO with cross-session `APP_BUSY`; the inspected Codex service
  exposes its own per-app execution model and interruption semantics.
- **Human interruption:** Codex continuously monitors controlled sessions,
  invalidates state, and requires requery. We primarily check recent physical
  input at dispatch preflight.
- **Perception:** Codex keeps incremental Skyshot revisions and can rebuild and
  uniquely refetch a replacement after invalidation. We keep simpler current
  in-memory snapshots, validate exact retained AX handles, and fail stale rather
  than search for replacements.
- **Verification:** our explicit read-act-read reducer provides strong outcome
  classes. The inspected Codex bundle settles/refetches state, but a universal
  deterministic classifier was not proven.
- **Cursor:** ours is a separate singleton AppKit process receiving FIFO
  commands, with no completion acknowledgement. Codex's virtual cursor is
  integrated into its computer-use service.
- **Focus:** Codex includes a dedicated synthetic focus-enforcement layer. We
  prefer AX and targeted input, with guarded global delivery last.
- **Consent/packaging:** Codex uses a separately signed TCC-owning service,
  sender authorization, and app approval state. We primarily use one
  multipurpose binary, deterministic policy, and `confirm:true`.
- **Tools:** Codex exposes roughly nine focused primitives and leaves workflow
  orchestration to the agent. Our roughly thirty tools include browser `page`,
  find/wait, batching, and record/save/replay workflow features.

Highest-priority ideas to adopt:

1. Continuously monitor human input during mutations, invalidate state, and
   return `REQUERY_REQUIRED`.
2. Add overlay completion acknowledgements or integrate cursor timing.
3. Use AX notifications for incremental subtree invalidation while retaining
   persisted snapshots for cross-process recovery.
4. Add a trusted local approval UI for sensitive operations.
5. Consolidate handler-owned lifecycle steps into a central MutationExecutor
   while preserving deterministic action-specific verification.

## Production limitations worth remembering

- Per-app coordination is in-memory and resets with daemon replacement.
- Human input is checked at admission rather than continuously cancelling work.
- Targeted synthetic events can be silently ignored by an application.
- AX support varies across native apps, custom controls, and webpages.
- The overlay is cosmetic and has no action/animation acknowledgement protocol.
- Snapshot cleanup is opportunistic rather than driven by a background timer.
- Private SkyLight behavior is less stable than public AX/CoreGraphics APIs.
- Some handlers have stronger outcome verification coverage than others.

## Source map

- `Sources/computer-use-mcp/Serve.swift`
- `Sources/computer-use-mcp/Dispatch.swift`
- `Sources/computer-use-mcp/Daemon/DaemonClient.swift`
- `Sources/computer-use-mcp/Daemon/DaemonServer.swift`
- `Sources/computer-use-mcp/Daemon/DaemonCoordination.swift`
- `Sources/computer-use-mcp/Core/AppResolver.swift`
- `Sources/computer-use-mcp/Core/AX.swift`
- `Sources/computer-use-mcp/Core/TreeBuilder.swift`
- `Sources/computer-use-mcp/Core/Snapshot.swift`
- `Sources/computer-use-mcp/Core/Target.swift`
- `Sources/computer-use-mcp/Core/Input.swift`
- `Sources/computer-use-mcp/Core/ActionChains.swift`
- `Sources/computer-use-mcp/Core/ActionOutcome.swift`
- `Sources/computer-use-mcp/Core/ActionTransaction.swift`
- `Sources/computer-use-mcp/Core/MetricsRecorder.swift`
- `Sources/computer-use-mcp/Core/Screenshot.swift`
- `Sources/computer-use-mcp/Core/InterferenceGuard.swift`
- `Sources/computer-use-mcp/Overlay/AgentCursor.swift`
- `Sources/computer-use-mcp/Overlay/OverlayHelper.swift`
- `Sources/computer-use-mcp/Skills/Recorder.swift`
- `Sources/computer-use-mcp/Skills/SkillTools.swift`

Detailed visual guide:
[Computer Use MCP architecture guide](/Users/matthewlam/.codex/artifacts/reports/2026-07-25-computer-use-mcp-architecture-guide.html)

Codex comparison:
[Codex versus computer-use-mcp](/Users/matthewlam/.codex/artifacts/reports/2026-07-28-codex-vs-computer-use-mcp.html)

## Presenter quick glance: one full lifecycle

### 1. Agent discovers the MCP

```text
agent starts serve shim
→ MCP connects over stdio
→ MCP exposes available tools
→ model sees tool names + schemas
```

### 2. First tool call starts the daemon

```text
serve shim calls DaemonClient
→ client tries daemon.sock
→ no daemon: spawn candidates
→ candidates race for daemon flock
→ winner keeps lock for its lifetime
→ losers exit
→ every shim connects to winner
→ daemon accepts each connection
→ getpeereid verifies same macOS user
→ shim reads protected daemon.secret
→ shim sends hello + token + version
→ daemon compares token in constant time
→ mark connection authenticated
```

### 3. Model calls `list_apps`

```text
request crosses Unix socket
→ daemon receives request ID
→ dispatch finds list_apps handler
→ libproc scans current PIDs
→ AppKit creates NSRunningApplication records
→ keep controllable GUI apps
→ return name + bundle ID + PID
```

### 4. Model calls `get_app_state`

```text
model chooses app
→ resolve app to PID
→ create AX application proxy
→ read AXWindows
→ choose requested title
   or focused → main → first
→ capture window with ScreenCaptureKit
→ recursively read AXChildren
→ read role + label + value + state + frame
→ read supported AX actions
→ create treeText for the model
→ create locator elements for targeting
→ SnapshotStore installs the current in-memory generation
→ return tree + element IDs + screenshot
```

Snapshot reminder:

```text
treeText:
ID + role + label + frame
+ value/state + AX actions

CapturedNode:
ID + live AX handle + role/subrole/identifier/stable label + frame
+ parent + children
```

Large-tree reminder:

```text
normal limit: 500
hard cap: 5,000
partial: coverage was omitted
skeleton: shallow overview
scope: expand one container
```

### 5. Model calls `click`

```text
model passes app + element ID
→ serve shim forwards request
→ daemon authenticates the logical session
→ operation registry checks the operation UUID
→ per-app coordinator admits the mutation:
   same session: FIFO
   different session: APP_BUSY
→ dispatch finds click handler
→ shared preflights run:
   screen lock
   human interference
   URL policy
→ click-specific safety runs
→ resolve current app + PID
→ load current snapshot node by ID
→ validate retained AX handle and live semantic facts
→ verify owning PID + captured window attachment
→ stale mismatch: request fresh state
→ valid match: obtain live AXUIElement
```

### 6. Click is delivered

```text
capture target before-state
→ derive point from live AX frame
→ ask cursor overlay to glide
→ inspect supported AX actions
→ try semantic rungs in order:
   Press / Confirm / Open / Pick
   selection / child / ancestor
→ verify each fired rung
→ stop at first observed effect
```

If no semantic rung lands:

```text
window-targeted NSEvent bridge
→ optional SkyLight PID delivery
→ public PID CoreGraphics
→ guarded global CoreGraphics
```

### 7. Result is verified and returned

```text
API success alone is not trusted
→ reread target-local state
→ check window fingerprint if needed
→ reselect final live window
→ rebuild final AX tree
→ persist new snapshot
→ calculate tree diff
→ classify outcome:
   success
   unsupported
   effect_not_verified
   verifier_ambiguous
→ return evidence + fresh state over MCP
```

### 8. Limits to remember

```text
actors protect shared state
per-app coordinator protects mutation ownership
same-session operations run FIFO
different sessions fail fast with APP_BUSY

but:
no continuous human-input monitor
overlay has no completion acknowledgement
```

## Presentation proctor: production-readiness progression

Use this section as the concise presentation script. For every phase, explain:

```text
old behavior/problem
→ current design
→ why the change matters
→ trade-off or remaining limitation
```

### Recommended main presentation story

Lead with product capability, then introduce production pressures. The
time-limited lease implementation is optional Q&A history rather than part of
the main narrative.

```text
1. Single-agent computer use
   AX application/window/element model
   screenshot + semantic snapshot
   stable element IDs backed by validated live AX handles
   AX-first action delivery with CoreGraphics fallback
   read-act-read outcome verification

2. Shared multi-agent runtime
   one singleton daemon elected with lifetime flock
   many MCP serve shims and socket connections
   logical session UUID + resume token, independent of connection FD
   operation UUID + dedupe for retry-safe mutation identity
   operation-scoped per-app coordinator:
     same session/app → FIFO
     different session/owned app → APP_BUSY
     different apps and safe reads → concurrent

3. Production reliability
   exact process/window/snapshot lineage
   cooperative cancellation around the delivery boundary
   typed delivery/effect/commit evidence
   deterministic multi-session and failure-path tests
   privacy-safe operation, strategy, latency, and perception metrics

4. Measured next improvements
   use metrics to prioritize perception cost, stale targeting, delivery fallbacks,
   unverified outcomes, and queue latency
   continuous human-interference monitoring
   overlay completion acknowledgement
   central MutationExecutor for simpler lifecycle enforcement
```

Presentation language:

```text
Do say: operation-scoped per-app ownership/coordinator
Do not say: current per-app lease

Do say: same-session mutations queue FIFO
Do not imply: different sessions wait in the same queue

Do say: operation IDs make bounded reconnect retries idempotent
Do not imply: dedupe or sessions survive daemon replacement
```

### Phase 1. Request and identity

Current design:

```text
MCP request ID
  matches one request/response on one socket connection

logical session UUID + resume token
  preserve agent ownership across reconnects to the same daemon

operation UUID
  identifies one logical tool operation and deduplicates safe retries

daemon incarnation ID
  prevents uncertain mutations from being replayed after daemon replacement
```

Progression and reasoning:

```text
Before: connection FD implicitly represented the session
Problem: reconnecting changed the FD and lost logical ownership
Change: daemon-issued session UUID plus opaque resume token
Trade-off: sessions and resume state are in memory and do not survive daemon restart

Before: request IDs only correlated messages
Problem: a lost response made mutation retry ambiguous and potentially duplicate
Change: client-generated operation UUID plus daemon dedupe registry
Trade-off: completed mutation results consume bounded in-memory retention;
           retries across a new daemon incarnation fail closed
```

Proctor checkpoints:

- Who creates the request ID, session UUID, resume token, operation UUID, and
  daemon incarnation ID?
- Why is an FD a connection identity rather than a session identity?
- What survives a socket reconnect, and what does not survive a daemon restart?
- Why can a read retry more freely than a mutation?

### Phase 2. Per-app mutation coordination

```text
Before: renewable 10-second ownership lease; operations could outlive it and
        same-session mutations could interleave
Change: operation-scoped ownership held until completion
Current: same session + same app → FIFO
         different session + owned app → APP_BUSY
         different apps → concurrent
Trade-off: cross-session callers retry at the agent level instead of waiting in
           an opaque global queue
```

Lease/heartbeat alternative:

```text
heartbeat lease
  advantage: ownership eventually expires if the owner crashes or disappears
  risk: expiry can permit overlap while an old operation is still running;
        strong safety requires fencing tokens plus renewal/timer complexity

operation-scoped coordinator (current)
  advantage: ownership cannot expire in the middle of a live mutation;
             same-session operations have deterministic FIFO order
  risk: a stuck operation can hold the app until cooperative cancellation,
        disconnect cleanup, or daemon replacement releases it; the current
        120-second client RPC timeout stops waiting but is not a daemon-enforced
        execution deadline
```

The current single daemon can directly observe its tasks and connections, so
operation-scoped ownership is simpler than a distributed heartbeat protocol. A
lease plus fencing becomes more attractive if ownership spans multiple daemon
processes or remote workers.

### Phase 3. Gates and cancellation

```text
Shared gates: screen lock, human interference, confirmation, URL policy
Cancellation before delivery: stop with not_delivered/not_committed
Cancellation after delivery may have begun: continue observation and report an
honest committed/partial/unknown outcome rather than pretending rollback
Trade-off: cancellation is cooperative, not transactional rollback
```

### Phase 4. Target identity and live resolution

```text
Before: PID/title/frame and locator matching could redirect after process/window churn
Change: PID + bundle ID + process start time + exact CGWindowID lineage
Then: select exact live AX window → replay role/index locator → verify role/label
Trade-off: strict identity produces more stale-target errors, but avoids acting
           on a recycled process or same-title sibling window
```

### Phase 5. Intent and before evidence

```text
Read common AX evidence: value, selected, focused, relevant window fingerprint
Interpret by intent:
  text-field click → focus
  checkbox click → observed selection/value change
  generic button → target or window change, not business-success proof
Trade-off: generic activation remains effect_not_verified without a declared
           target-specific postcondition
```

### Phase 6. Delivery

```text
Preferred: semantic AX action/attribute
  AXUIElementCopyActionNames
  AXUIElementPerformAction
  AXUIElementIsAttributeSettable
  AXUIElementSetAttributeValue

Fallback: window-affined / SkyLight prototype / PID CoreGraphics;
          guarded global input only by explicit caller intent
Trade-off: synthetic posting can be dropped and therefore cannot itself prove effect
```

### Phase 7. Verification and commit

```text
quick per-rung check: reread current target; fingerprint window only if needed
final check: reselect exact window, rebuild state, replay locator, reread target

delivery: not_delivered / delivered / posted / unknown
effect:   verified / unverified / not_checked
commit:   not_committed / committed / partially_committed / unknown
```

Reasoning:

```text
Before: API success could be mistaken for application success
Change: separate transport evidence, observed effect, and durable-state claim
Trade-off: honest ambiguity is more verbose but prevents false success and
           unsafe automatic replay
```

### Phase 8. Response and observability

```text
persist snapshot + calculate diff
→ return human text plus structured outcome metadata
→ cache completed mutation result for operation dedupe
→ record privacy-safe operation/perception metrics
```

Metrics intentionally exclude labels, text values, URLs, screenshots, and AX
tree contents. One actor serializes calls inside a process; `metrics.lock` uses
`flock` because daemon, explicit no-daemon dispatch, and read-only fallback can
be separate processes writing the same JSONL and aggregate files.

Remaining production improvements to present honestly:

```text
continuous human-interference monitoring
overlay animation acknowledgement
daemon-exclusive metrics ingestion, if local dispatch paths are removed
a central MutationExecutor that enforces the lifecycle while action plans
provide only resolve/capture/deliver/verify behavior
```
