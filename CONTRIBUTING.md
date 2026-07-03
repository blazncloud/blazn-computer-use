# Contributing to computer-use-mcp

Thanks for your interest. This is a macOS computer-use MCP server built in Swift,
and it drives **live system automation** (Accessibility, Screen Recording, input
delivery). Treat runtime changes as safety-sensitive even when they look like
ordinary Swift edits — see [AGENTS.md](AGENTS.md) for the full safety boundaries
and ownership map that both human and agent contributors follow.

## Requirements

- macOS 14 or newer
- Swift 6 toolchain (Xcode 16+)
- Accessibility and Screen Recording granted to your terminal/IDE for any live
  local verification (not needed for the default build/test path)

## Build and test

```bash
swift build          # compile the package
swift test           # pure unit suite — must stay free of live GUI/TCC side effects
```

If a sandbox blocks Swift's module cache, keep the cache inside the worktree:

```bash
env CLANG_MODULE_CACHE_PATH=.build/module-cache swift test
```

CLI smoke checks after a build:

```bash
.build/debug/computer-use-mcp version
.build/debug/computer-use-mcp help
.build/debug/computer-use-mcp health_report --json
```

The full testing model — unit, build, CLI smoke, release preflight, and the
local-only live GUI tiers — is documented in [docs/TESTING.md](docs/TESTING.md).
**Do not add live GUI, TCC, clipboard, window-management, or input-delivery
checks to the default suite or to hosted CI.** Those belong in the local scripts
under `scripts/` with their side effects documented.

## Verification expectations

Match the verification to what you changed (from [AGENTS.md](AGENTS.md)):

- **Docs-only changes:** inspect the rendered Markdown and run the non-mutating
  build/test/CLI smoke path when practical.
- **Tool schema, handler, or CLI changes:** run `swift test`, then `swift build`,
  then `version` and `help`. Keep tool schemas backwards-compatible.
- **Runtime, input, daemon, overlay, or safety-policy changes:** run the unit/CLI
  path and either perform an approved local live verification or explicitly report
  in the PR why live verification was not run.
- **Safety-policy changes** must include tests for **both** the gated path and the
  confirmed/recovery path. Never disable safety gates, app leases, or daemon
  isolation to make a test pass.

## Pull request conventions

- Branch off `main`; keep each PR to one logical change so the diff is easy to
  review.
- **Granular, focused commits.** One concern per commit; write a message that
  explains the *why*, not just the *what*.
- Never push directly to `main`, rewrite published history, or submit anything to
  external registries as part of a PR.
- Fill in the [pull request template](.github/PULL_REQUEST_TEMPLATE.md): what
  changed, how you verified it, and — for runtime changes — whether live
  verification ran or why it was skipped.
- If your change touches the observation/dispatch contract, keep
  [docs/architecture/modality-contract.md](docs/architecture/modality-contract.md)
  and the outcome contract in sync.

## Repository layout

- `Sources/computer-use-mcp/` — the engine and MCP tool layer (`Core/`, `Tools/`,
  `Daemon/`, `Overlay/`, `ToolKit/`; see [AGENTS.md](AGENTS.md) for the per-dir
  ownership map).
- `Sources/ComputerUseFixture/` — deterministic GUI fixture app for the
  end-to-end "truth suite" (see [docs/fixture-app.md](docs/fixture-app.md)).
- `Tests/ComputerUseMCPTests/` — pure unit tests only.
- `scripts/` — local demos, preflight, and release helpers (side effects
  documented in each).
- `docs/` — architecture contracts, testing, research, and release docs.
- `plans/` — design and planning notes for in-flight work (background-control
  productionization, the productionization wave). These are working documents that
  capture intent and sequencing; they are not part of the shipped product and may
  lag the code.
- [`AGENTS.md`](AGENTS.md) — operating guidelines for both human and AI-agent
  contributors: safety boundaries, command discipline, the ownership map, and
  per-change verification expectations. Read it before your first change.

## Reporting security issues

Do **not** open a public issue for a vulnerability. See [SECURITY.md](SECURITY.md)
for the private disclosure process.
</content>
