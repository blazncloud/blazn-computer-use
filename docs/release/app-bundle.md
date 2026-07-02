# Local App Bundle

`scripts/build_app_bundle.py` creates a local `.app` wrapper around the Swift
CLI binary:

```bash
python3 scripts/build_app_bundle.py
```

The default output is:

```text
.build/app-bundle/Computer Use MCP.app
```

The wrapper is intended for local productionization testing and future
distribution work. It gives macOS a stable bundle id
(`dev.computer-use-mcp.app` by default) that can be used for manual
Accessibility, Screen Recording, and Apple Events attribution checks.

The script performs a `swift build` (debug by default; pass
`--configuration release` for the runtime bundle), copies the executable into
`Contents/MacOS`, writes `Info.plist`, and ad-hoc signs the bundle. Override the
identity only when deliberately testing a different TCC attribution path:

```bash
python3 scripts/build_app_bundle.py --app-name "Computer Use MCP Dev" --bundle-id dev.computer-use-mcp.dev
```

This is not notarization, packaging, or runtime proof that the MCP checks used
the bundle identity for live TCC prompts. For non-live runtime proof, use:

```bash
python3 scripts/preflight.py --use-app-bundle
```

That mode builds the wrapper and runs CLI/dry-run checks through
`Contents/MacOS/computer-use-mcp`. `--build-app` remains build-only. Keep live
bundle-executed TCC checks separate from hosted CI so development preflight
stays fast and reproducible.

## Deploying the installed runtime bundle

The production runtime is the installed copy at
`~/Applications/Computer Use MCP.app` (ad-hoc signed; holds the TCC grants).
Instead of the manual three-command loop (`swift build -c release`,
`build_app_bundle.py`, `ditto`), use the deploy script:

```bash
python3 scripts/deploy_app_bundle.py
```

It builds release (failing loudly on build errors), reuses the bundle build
above with `--configuration release`, installs via `ditto` into
`~/Applications` (override with `--dest DIR` or
`COMPUTER_USE_MCP_INSTALL_DIR`), then runs
`Contents/MacOS/computer-use-mcp call list_apps '{}'` against the installed
copy so the daemon hands over to the fresh binary. The handover step is a
warning, not a failure, on headless machines. The script prints a compact JSON
report with per-step status and the installed binary mtime.

To catch a stale installed bundle (new tools missing from sessions because the
installed copy predates them):

```bash
python3 scripts/deploy_app_bundle.py --check
```

This compares the installed executable's mtime against the newest mtime under
`Sources/` and `.build/release/computer-use-mcp`, and exits nonzero when the
installed bundle is older than the current source/build.
