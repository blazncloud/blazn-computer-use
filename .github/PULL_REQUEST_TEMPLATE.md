<!--
  Thanks for contributing! Keep each PR to one logical change (see CONTRIBUTING.md).
  This project drives live macOS automation — treat runtime changes as
  safety-sensitive even when they look like ordinary Swift edits.
-->

## What changed

<!-- One or two sentences on the change and the why. -->

## Type of change

- [ ] Bug fix
- [ ] New feature / capability
- [ ] Docs only
- [ ] Refactor / internal (no behavior change)
- [ ] Safety-policy change

## Verification

<!-- Match the verification to what you changed (CONTRIBUTING.md / AGENTS.md). -->

- [ ] `swift build`
- [ ] `swift test`
- [ ] CLI smoke: `version`, `help`, `health_report --json`
- [ ] Local live verification (describe app + result), **or** explain below why it was not run:

<!-- If live verification was skipped for a runtime/input/daemon/overlay change, state the blocker. -->

## Checklist

- [ ] One logical change; commits are granular and messages explain the *why*.
- [ ] Tool schemas stay backwards-compatible (or the break is called out).
- [ ] Safety-policy changes include tests for **both** the gated and the confirmed/recovery path.
- [ ] No default safety gate, app lease, or daemon isolation was disabled to make a test pass.
- [ ] No live GUI/TCC/input checks added to the default suite or hosted CI.
- [ ] Relevant docs updated (README / CHANGELOG / contracts under `docs/`).
