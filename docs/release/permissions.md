# Permissions and App Identity

`computer-use-mcp` needs Accessibility and Screen Recording. In development,
macOS may attribute those TCC grants to the responsible host process that
launches the CLI, such as Terminal, an IDE, or an MCP client. That is useful for
local iteration, but it is not a production install story because a different
host app needs its own grants.

## Non-Mutating Diagnostic

Run:

```bash
computer-use-mcp health_report --json
```

The report includes:

- binary version and executable path;
- bundle identifier if the current launch has one;
- current and parent process identity;
- Accessibility and Screen Recording status;
- capture-service status, which is skipped by default and probed only when
  `--probe-capture` is passed;
- daemon runtime, socket, lock, log, and secret paths with existence booleans;
- a recommended next action.

The default report does not prompt for permissions, start the daemon, run
ScreenCaptureKit, or print daemon secret contents.

When you need capture-service health, run:

```bash
computer-use-mcp health_report --json --probe-capture
```

That opt-in probe is bounded and reuses the same cross-process ScreenCaptureKit
lock as screenshots, so it may create or touch the local diagnostic lock file.

Use `computer-use-mcp doctor --prompt` only when you intentionally want macOS to
show permission prompts for the current responsible host.

## Target Release Shape

Production distribution should move from an ad hoc CLI launched by whichever
terminal or agent is present to a stable app-bundle identity:

1. Build a `.app` wrapper that launches the server/daemon from a stable bundle
   identifier.
2. Sign the bundle with a Developer ID Application certificate.
3. Notarize and staple the app before distribution.
4. Install into a stable location such as `/Applications`.
5. Ask users to grant Accessibility and Screen Recording to that app identity.
6. Verify with `health_report --json --probe-capture` and record the executable
   path, bundle id, signing/notarization status, permissions, and
   capture-service status.

Terminal or IDE grants are still valid for local development, but release notes
and support instructions should treat them as development-only attribution.
