# Agent Guidelines

This repo exposes live macOS computer-use capabilities. Treat runtime changes as
safety-sensitive even when they look like ordinary Swift edits.

## Safety Boundaries

- Do not run live GUI, TCC, app-control, clipboard, or global-cursor demos unless
  the user explicitly approves that run.
- Default to non-mutating verification: `swift build`, `swift test`, and CLI
  help/version smoke checks.
- Treat `scripts/e2e_demo.py`, `doctor --prompt`, `call`, `serve` against real
  apps, and any test using Accessibility, Screen Recording, clipboard, window
  management, or input delivery as mutating/local-only.
- Never disable safety gates (`COMPUTER_USE_MCP_NO_SAFETY=1`), app leases, or
  daemon isolation to make a test pass unless the task is specifically about
  those controls and the final result verifies the safe default path too.

## Command Discipline

- Run each shell command as a separate tool call. Do not chain with `&&`, `||`,
  `;`, or pipes unless that shell behavior is the thing being tested.
- Prefer `rg`/`rg --files` for discovery.
- Do not push, publish, rewrite history, delete user data, or kill unrelated
  processes without explicit permission.

## Ownership Map

- `Sources/computer-use-mcp/Core/`: capture, AX, input, targeting, policy, and
  config. Runtime or safety changes here require focused unit coverage plus a
  local real-surface verification plan.
- `Sources/computer-use-mcp/Tools/`: MCP tool handlers and catalog. Keep schemas
  stable and verify CLI/MCP smoke behavior when changing contracts.
- `Sources/computer-use-mcp/Daemon/`: shared engine process, socket protocol,
  and app leases. Verify multi-session and daemon fallback assumptions before
  claiming concurrency safety.
- `Sources/computer-use-mcp/Overlay/`: visible agent cursor. Keep it optional
  for headless/CI paths.
- `Sources/computer-use-mcp/ToolKit/`: schema/tool-spec plumbing. Prefer small,
  backwards-compatible changes.
- `Tests/ComputerUseMCPTests/`: pure unit tests only. Do not add live GUI/TCC
  tests to the default suite.
- `scripts/`: local demos and manual preflight helpers. Document required user
  consent and side effects.
- `.github/workflows/`: hosted CI. Keep it deterministic and avoid live GUI/TCC
  requirements on hosted runners.

## Verification Expectations

- Docs-only changes: inspect the rendered Markdown structure and run the
  non-mutating build/test/CLI smoke path when practical.
- Tool schema, handler, or CLI changes: run `swift test`, then `swift build`,
  then `.build/debug/computer-use-mcp version` and
  `.build/debug/computer-use-mcp help`.
- Runtime, input, daemon, overlay, or safety-policy changes: run the unit/CLI
  path and either perform an approved local live verification or explicitly
  report why live verification was not run.
- Safety-policy changes must include tests for both the gated path and the
  confirmed/recovery path.
