# Blazn Computer Use extension roadmap

Status: proposed

Fork: `blazncloud/blazn-computer-use`

Upstream: `minghinmatthewlam/computer-use-mcp`

Baseline: `82dd8093e44819c51537f489059e172777d7f1d7`

## Goal

Turn the macOS-first MCP server into a harness-neutral computer and browser
control substrate for Blazn agents while preserving the upstream project's
strongest invariant: an action is not successful until its intended effect is
independently observed.

Codex, Claude, Gemini, Open Interpreter, Agent TARS, Pydantic AI, and custom
Blazn runtimes must be clients of the same core rather than separate execution
implementations.

## Delivery rules

- Keep `main` releasable. Each milestone lands through small, independently
  reviewable PRs.
- Freeze public action, observation, outcome, session, and safety contracts
  before parallel backend work begins.
- Preserve upstream history and maintain a documented upstream-sync procedure.
- Treat focused unit tests, live GUI proof, browser proof, remote proof, and
  consumer activation as different evidence classes.
- Never call a process launch, posted event, AX return code, or browser click a
  success without a post-action oracle.
- Every supported mutation must define idempotency, retry, cancellation, and
  ambiguous-commit behavior.
- Release claims are generated from retained test artifacts, not prose alone.

## Shared acceptance suite

The first milestone checks in deterministic fixtures and a result schema used
by every later milestone.

### Browser tasks

- `B1-read`: navigate and return an exact challenge string.
- `B2-form`: populate text, select, checkbox, and submit controls; verify the
  server-side JSON state rather than a painted success banner.
- `B3-drift`: repeat B2 after labels, DOM order, and layout move.
- `B4-stale`: replace the form after observation; the old reference must fail
  stale, then a fresh observation must permit successful recovery.

### Desktop tasks

- `D1-observe`: identify stable control roles and labels without mutation.
- `D2-form`: populate and save fixture state with an independent file oracle.
- `D3-ambiguity`: refuse when two indistinguishable target windows exist.
- `D4-background`: complete D2 without changing the foreground application or
  physical cursor.

### Required result fields

Every trial records exact commit, OS, display geometry, backend, client,
provider/model when applicable, startup time, action latency, observation
bytes, schema bytes, retries, intervention count, action outcome, oracle
outcome, focus/cursor telemetry, and artifact paths.

A milestone is accepted only after three consecutive clean trials per supported
task plus the required fault campaigns. A retry does not erase the failed
attempt from the report.

## Milestone 0 — Fork qualification and contract baseline

Objective: make the fork reproducible before behavior diverges from upstream.

Deliverables:

- document `origin` and `upstream` remote conventions;
- add an upstream-sync script that fails on dirty state or unresolved history;
- import the shared browser fixture, desktop fixture contract, benchmark result
  schema, and artifact layout;
- retain the upstream 476-test suite and current live background evaluation;
- add a source/commit manifest and generated capability inventory;
- establish CI lanes for unit, build, protocol smoke, browser fixture, package,
  and self-hosted macOS live proof.

End-to-end acceptance:

1. A clean clone resolves the pinned upstream and builds without modifying
   tracked dependency files.
2. `swift test`, CLI version/help/health, and MCP initialize/tools-list pass.
3. The benchmark runner rejects a result missing its independent oracle.
4. A retained baseline report records 17 tools, MCP startup, schema bytes, and
   three clean D4 trials.
5. Upstream-sync dry-run proves no accidental force push or default-branch
   divergence.

Exit artifact: `artifacts/m0/<commit>/qualification.json`.

## Milestone 1 — Runtime-path and daemon hardening

Objective: eliminate the long-home daemon wedge discovered in the bake-off.

Deliverables:

- derive a short, per-user, collision-resistant runtime directory independent
  of home-path length;
- bind socket/lock/secret paths through one validated path type;
- enforce Unix-socket byte limits before process spawn;
- replace assertion/fatal paths with bounded structured startup errors;
- preserve daemon authentication, permissions, version handover, idempotency,
  and app-lease arbitration;
- add stale-lock and crashed-daemon recovery without in-process mutation
  fallback.

End-to-end acceptance:

1. Homes containing 200 ASCII characters, spaces, Unicode, and decomposed
   Unicode all complete MCP initialize and one read-only call.
2. Overlong inputs never spawn a wedged daemon and return a stable error code.
3. Two MCP clients share one daemon and cannot interleave mutations in one app.
4. Daemon version handover preserves no secret or socket from the old build.
5. D1-D4 pass three times under normal and long-home environments.

Fault campaigns: stale lock, occupied socket, killed daemon before/after
delivery, corrupt secret, partial runtime directory, screen lock, and concurrent
startup race.

Exit artifact: `artifacts/m1/<commit>/daemon-matrix.json`.

## Milestone 2 — Stable backend-neutral contracts

Objective: freeze the interface before browser and additional OS backends are
developed in parallel.

Deliverables:

- define versioned `Observation`, `TargetRef`, `ActionIntent`, `ActionReceipt`,
  `EffectEvidence`, `Outcome`, `Session`, and `BackendCapabilities` schemas;
- distinguish accessibility, DOM, visual-anchor, OCR, coordinate, API, and
  system-of-record evidence;
- encode stale generation, ambiguity, unsupported action, transport delivery,
  effect-not-verified, committed, refused, and unknown-commit outcomes;
- expose the core through Swift protocols plus JSON fixtures for non-Swift
  backends;
- make reference freshness and candidate uniqueness mandatory before mutation;
- define backend conformance tests independent of MCP transport.

End-to-end acceptance:

1. The macOS backend passes the new conformance suite with no behavior loss.
2. A fake backend proves every outcome transition, including unknown commit.
3. Old references are rejected after generation, window, process, scale, or
   backend changes.
4. JSON round trips are byte-bounded and compatible across Swift, TypeScript,
   and Python fixtures.
5. B4 and D3 have zero false accepts across 100 fault-injected trials.

Exit artifact: `artifacts/m2/<commit>/contract-conformance.json`.

## Milestone 3 — Browser backend

Objective: add a first-class browser surface without weakening desktop safety.

Deliverables:

- implement a browser backend behind the Milestone 2 contract using Playwright
  or Chrome DevTools Protocol;
- support isolated local profiles, attach-by-CDP, remote CDP, tabs, frames,
  downloads, console, network, screenshots, tracing, and accessibility trees;
- use DOM/accessibility references first and vision/coordinates only when the
  surface requires them;
- implement domain allow/deny rules before navigation and mutation;
- independently verify form submission and other consequential effects;
- never use `--no-sandbox`, disabled web security, or disabled site isolation
  as production defaults;
- record browser engine/version and profile identity without exporting cookies
  or credentials.

End-to-end acceptance:

1. B1-B4 pass three consecutive trials on Chromium.
2. B1-B3 pass on WebKit and Firefox where the selected driver supports them.
3. B4 rejects the old reference in 100/100 replacement trials before recovery.
4. A fake painted success with unchanged server state returns
   `effect_not_verified`.
5. A prompt-injection page cannot expand the domain or action policy.
6. Authenticated-profile tests prove session reuse without artifacting cookies.
7. Network, console, screenshot, trace, and outcome artifacts correlate by one
   operation ID.

Exit artifact: `artifacts/m3/<commit>/browser-matrix.json`.

## Milestone 4 — Capability discovery and context efficiency

Objective: remain portable without loading the full desktop/browser catalog
into every model turn.

Deliverables:

- split tools into perception, desktop action, browser action, session,
  artifact, safety, and administration capability groups;
- implement deferred discovery and explicit allowlists;
- preserve a compact compatibility catalog for MCP clients without tool search;
- offer task-scoped tool leases rather than permanent catalog expansion;
- publish schema and observation byte budgets in CI;
- keep the same canonical core available through MCP and JSON CLI adapters.

End-to-end acceptance:

1. Default discovery is below 8 KB while retaining health and perception.
2. B2 and D2 load only their required capability groups.
3. A client without deferred discovery completes B1 and D1 through the compact
   compatibility catalog.
4. Revoking a capability invalidates its lease before the next action.
5. Ten parallel sessions do not cross-contaminate capability state.

Exit artifact: `artifacts/m4/<commit>/context-budget.json`.

## Milestone 5 — Unified verification, safety, and human control

Objective: make consequential action policy backend-independent.

Deliverables:

- add action classes for read, reversible local mutation, external mutation,
  destructive action, credential/persistent-access change, legal acceptance,
  communication, and financial action;
- enforce application, domain, target, data-egress, and action policies inside
  the engine rather than relying on prompts;
- add protocol-native confirmation and human-takeover requests;
- add sensitive-field redaction for screenshots, trees, logs, traces, and
  errors;
- carry one idempotency key and one effect contract across retries;
- add independently verifiable system-of-record oracles where available;
- halt rather than guess on identity, target, or effect ambiguity.

End-to-end acceptance:

1. Every mutating B/D task has a gated and confirmed-path test.
2. Duplicate requests never duplicate committed effects.
3. Cancellation before delivery is safely retryable; cancellation after
   delivery returns unknown until reconciled.
4. Password, token, cookie, and private-field fixtures never appear in retained
   artifacts.
5. Domain/app deny rules cannot be bypassed with redirects, iframes, alternate
   URL encodings, confirmation flags, or prompt injection.
6. Human takeover pauses the app lease and resumes from a fresh observation.

Exit artifact: `artifacts/m5/<commit>/safety-campaign.json`.

## Milestone 6 — Remote transport and sandbox execution

Objective: operate isolated Blazn browser/desktop workers without coupling
agents to a local Mac process.

Deliverables:

- add authenticated MCP Streamable HTTP while retaining stdio;
- require TLS, origin validation, scoped identities, rate limits, and tenant
  isolation;
- make sessions explicit and resumable without hidden transport state;
- add remote browser and Linux desktop reference workers;
- support attended live view and takeover without sharing backend credentials;
- publish container/VM images by immutable digest with SBOM and provenance;
- expose health, capacity, placement, and cleanup as separate evidence.

End-to-end acceptance:

1. The same client task passes over stdio and Streamable HTTP with equivalent
   outcomes.
2. Cross-tenant session, artifact, secret, and operation-ID access is denied.
3. Network interruption resumes or reconciles without duplicating effects.
4. B1-B4 pass on the remote browser worker.
5. D1-D2 pass on the Linux reference desktop; unsupported background
   guarantees are reported honestly.
6. A worker is destroyed after the task and no credential-bearing state
   remains in artifacts or the next session.

Exit artifact: `artifacts/m6/<commit>/remote-isolation.json`.

## Milestone 7 — Blazn integration and durable orchestration

Objective: make the service a first-class Blazn capability while remaining
callable from other harnesses.

Deliverables:

- register capability, version, backend, platform, and capacity metadata with
  Blazn;
- add queue admission, cancellation, deadlines, retries, heartbeats, and
  consumer-visible progress;
- expose human-attention and unknown-commit states as durable workflow states;
- add signed capability manifests and exact-source/image pins;
- retain per-operation audit and artifact links in the Blazn task record;
- provide example clients for Codex, Claude, Gemini, and direct MCP.

End-to-end acceptance:

1. A Blazn task schedules to a qualified worker and completes B2 or D2.
2. Placement, source, image, backend, and exact commit are present in the
   retained record.
3. Worker loss during mutation produces reconciliation, not blind retry.
4. Human-attention resumes the same durable operation after fresh perception.
5. A non-Blazn MCP client completes the same task with the same core outcome.
6. Queue and worker cleanup are independently confirmed after completion.

Exit artifact: `artifacts/m7/<commit>/blazn-e2e.json`.

## Milestone 8 — Cross-platform backends and release qualification

Objective: graduate from a Mac fork to a portable, supportable release.

Deliverables:

- add Windows UI Automation and Linux AT-SPI backends behind the frozen
  contract;
- publish signed/notarized macOS artifacts and signed Windows artifacts;
- publish Linux packages and immutable worker images;
- implement update, rollback, compatibility, and migration policy;
- generate a capability matrix from current retained proofs;
- document upstream merges, license boundaries, security response, and release
  ownership.

End-to-end acceptance:

1. Platform-specific D tasks pass only where their guarantees are supported.
2. Unsupported capabilities fail closed during admission, not mid-action.
3. Clean-machine install, upgrade, rollback, and uninstall pass on each
   supported platform.
4. Release archives pass license, secret, SBOM, provenance, and malware gates.
5. Required CI and self-hosted proof run on the exact release commit.
6. A canary Blazn consumer completes its lifecycle before general activation.

Exit artifact: `artifacts/m8/<commit>/release-qualification.json`.

## Milestone dependency map

```text
M0 baseline
 └─ M1 runtime hardening
     └─ M2 contract freeze
         ├─ M3 browser backend
         ├─ M4 capability discovery
         └─ M5 verification and safety
             └─ M6 remote transport
                 └─ M7 Blazn integration
                     └─ M8 cross-platform release
```

M3, M4, and the non-overlapping parts of M5 may proceed in parallel only after
M2 schemas and conformance fixtures are frozen. Shared schema, package,
workflow, and release mutations remain serialized.

## Definition of complete

A milestone is complete only when:

- implementation and focused tests are merged;
- the exact merge commit passes required CI;
- retained end-to-end artifacts satisfy the milestone gates;
- an independent review finds no P0/P1 or acceptance-blocking P2 issue;
- documentation and capability claims match observed evidence;
- cleanup and rollback are proven;
- the next consumer or milestone is explicitly activated.

