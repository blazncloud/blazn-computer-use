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

The script performs a normal `swift build`, copies the debug executable into
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
