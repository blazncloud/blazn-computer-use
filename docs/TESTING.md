# Testing and Preflight

Use the lowest-risk tier that proves the change, then add stronger local checks
only when the change touches runtime macOS automation.

Use [Modality Contract](architecture/modality-contract.md) as the contract-level
source of truth for observation, dispatch, coordinate, permission, and recovery
behavior when deciding which tier proves a change.
Use [Background Control Contract](architecture/background-control-contract.md)
for focus, cursor, and background-control invariants.

## Local Commands

```bash
swift build
swift test
.build/debug/computer-use-mcp version
.build/debug/computer-use-mcp help
.build/debug/computer-use-mcp health_report --json
python3 scripts/preflight.py
python3 scripts/preflight.py --use-app-bundle
```

If the sandbox blocks Swift's module cache, keep cache output inside the
worktree:

```bash
env CLANG_MODULE_CACHE_PATH=.build/module-cache swift test
```

## Testing Tiers

| Tier | Command or surface | Use for | Notes |
| --- | --- | --- | --- |
| Unit | `swift test` | Pure logic: keymaps, coordinates, tree shaping, safety policy | Must stay free of live GUI, TCC, clipboard, and input side effects. |
| Build | `swift build` | Compile/package sanity | Required before CLI smoke checks. |
| CLI smoke | `version`, `help`, `health_report --json` | Command dispatch, binary startup, and non-mutating identity diagnostics | Safe for CI; default `health_report` reports missing permissions and skips capture probing instead of prompting. |
| Release preflight | `python3 scripts/preflight.py` | Single JSON report for helper tests, build, unit, CLI smoke, health report, and dry-run eval gates | Safe for CI unless live flags are passed. |
| App-bundle runtime | `python3 scripts/preflight.py --use-app-bundle` | Build the `.app` wrapper and run non-live CLI/dry-run checks through its executable | Local/self-hosted; useful for stable-identity preflight without live GUI mutation. |
| Local MCP smoke | `serve` or `call ...` against a real app | Tool-contract or runtime changes | Requires explicit user approval because it can inspect or operate local apps. |
| Deterministic background eval | `python3 scripts/live_background_eval.py --live` | Background mutation while the current frontmost app is preserved | Local/self-hosted only; builds and launches the fixture app in the background. |
| Real-app matrix | `python3 scripts/real_app_smoke.py --live` | Read-only Finder compatibility plus TextEdit background stdio behavior | Local/self-hosted only; opens real apps and depends on TCC grants. |
| Live demo | `python3 scripts/e2e_demo.py --live` | End-to-end stdio, app state, background input | Local-only; launches TextEdit without activation and fails if frontmost focus changes. Do not run on hosted CI. |

## CI Expectations

GitHub Actions should remain deterministic on hosted macOS runners:

- build the Swift package;
- run the pure unit suite;
- smoke-test the CLI with `version`, `help`, and `health_report --json`;
- run `python3 scripts/preflight.py` when a single artifacted report is useful;
- avoid live GUI, Accessibility, Screen Recording, clipboard, window-management,
  or input-delivery checks.

Do not add hosted-runner tests that depend on a logged-in desktop session, user
TCC grants, visible apps, or timing-sensitive GUI state. Put those checks in
local scripts and document the side effects instead.

## Release Preflight

Before tagging or publishing a binary, run the CI tier locally and then perform
an approved local live check for the changed surface:

1. `python3 scripts/preflight.py --use-app-bundle --output /tmp/computer-use-mcp-preflight.json`
2. `computer-use-mcp doctor`, `health_report --probe-capture`, or
   `doctor --prompt` only when the user expects a local TCC/capture check or
   prompt.
3. For background-control changes, run an approved
   `python3 scripts/live_background_eval.py --live` and record the focus result.
4. For runtime/input/capture changes, run an approved `serve`, `call`, or
   `scripts/e2e_demo.py` check and record the app, permission state, and result.
5. For compatibility-sensitive changes, run an approved
   `python3 scripts/real_app_smoke.py --live` and record the target apps and
   TCC state.

If live verification is skipped, state the exact blocker or approval gap in the
release notes or handoff.
Use `--use-app-bundle` when the release preflight should exercise non-live CLI
and dry-run checks through `.build/app-bundle/Computer Use MCP.app/Contents/MacOS/computer-use-mcp`.
Use `--build-app` only when you want to build the wrapper without switching the
runtime binary for the rest of preflight.
