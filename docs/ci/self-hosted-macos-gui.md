# Self-Hosted macOS GUI CI

Hosted GitHub Actions runners must stay deterministic: they should build, run
unit tests, and exercise CLI-only diagnostics. Live computer-use checks need a
logged-in desktop session, Accessibility grants, Screen Recording grants, and
stable app identity, so they belong on a separately managed self-hosted Mac.

## Runner Contract

- Runner labels: `self-hosted`, `macOS`, `computer-use-gui`.
- The runner is a dedicated Mac with an unlocked desktop session.
- The runner executes this repository from a clean checkout and never stores
  unrelated user data in test target apps.
- The test host grants Accessibility and Screen Recording only to the stable
  app bundle or runner process used for the job.
- The job runs one workflow at a time. Do not run parallel GUI jobs on the same
  desktop session.

## Recommended Lane

```bash
python3 scripts/preflight.py --build-app --live-background --output /tmp/computer-use-mcp-gui-preflight.json
```

Add the real-app matrix only for release candidates or compatibility work:

```bash
python3 scripts/preflight.py --build-app --live-background --live-real-app --output /tmp/computer-use-mcp-gui-preflight.json
```

The fixture eval is the deterministic source of truth for background-control
regressions. `--build-app` currently proves only that the local `.app` wrapper
can be produced; the live checks still execute `.build/debug/computer-use-mcp`.
Real-app checks are compatibility smoke tests because Finder, TextEdit, and
macOS timing can change outside this repository.

## Workflow Shape

```yaml
jobs:
  gui-preflight:
    runs-on: [self-hosted, macOS, computer-use-gui]
    concurrency:
      group: computer-use-gui
      cancel-in-progress: false
    steps:
      - uses: actions/checkout@v4
      - run: python3 scripts/preflight.py --build-app --live-background --output gui-preflight.json
      - uses: actions/upload-artifact@v4
        with:
          name: gui-preflight
          path: gui-preflight.json
```

Keep this lane out of hosted CI. If it fails, record the macOS version, TCC
state, frontmost app before and after, and whether the failure reproduced with
`python3 scripts/live_background_eval.py --live` outside Actions.
