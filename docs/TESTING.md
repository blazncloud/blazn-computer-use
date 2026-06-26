# Testing and Preflight

Use the lowest-risk tier that proves the change, then add stronger local checks
only when the change touches runtime macOS automation.

## Local Commands

```bash
swift build
swift test
.build/debug/computer-use-mcp version
.build/debug/computer-use-mcp help
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
| CLI smoke | `version`, `help` | Command dispatch and binary startup | Safe for CI; does not require Accessibility or Screen Recording. |
| Local MCP smoke | `serve` or `call ...` against a real app | Tool-contract or runtime changes | Requires explicit user approval because it can inspect or operate local apps. |
| Live demo | `python3 scripts/e2e_demo.py` | End-to-end stdio, app state, background input | Local-only; opens TextEdit/Finder and depends on TCC grants. Do not run on hosted CI. |

## CI Expectations

GitHub Actions should remain deterministic on hosted macOS runners:

- build the Swift package;
- run the pure unit suite;
- smoke-test the CLI with `version` and `help`;
- avoid live GUI, Accessibility, Screen Recording, clipboard, window-management,
  or input-delivery checks.

Do not add hosted-runner tests that depend on a logged-in desktop session, user
TCC grants, visible apps, or timing-sensitive GUI state. Put those checks in
local scripts and document the side effects instead.

## Release Preflight

Before tagging or publishing a binary, run the CI tier locally and then perform
an approved local live check for the changed surface:

1. `swift build`
2. `swift test`
3. `.build/debug/computer-use-mcp version`
4. `.build/debug/computer-use-mcp help`
5. `computer-use-mcp doctor` or `doctor --prompt` only when the user expects a
   TCC/permission check.
6. For runtime/input/capture changes, run an approved `serve`, `call`, or
   `scripts/e2e_demo.py` check and record the app, permission state, and result.

If live verification is skipped, state the exact blocker or approval gap in the
release notes or handoff.
