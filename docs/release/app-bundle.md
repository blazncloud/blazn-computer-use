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
the bundle identity. `scripts/preflight.py --build-app` only verifies that the
bundle can be produced; the current smoke and eval scripts still execute
`.build/debug/computer-use-mcp` directly. Keep future bundle-executed TCC checks
separate from the default preflight so development preflight stays fast and
reproducible.
