# Codex App Bundle Comparison

Read-only snapshot taken from `/Applications/Codex.app` on this machine.

## Observed App Identity

- Bundle id: `com.openai.codex`
- Version: `26.623.70822` (`CFBundleVersion` `4559`)
- Executable: `/Applications/Codex.app/Contents/MacOS/Codex`
- Resources include `app.asar`, `codex`, `rg`, and `codex_chronicle`.
- Signing team: `2DC432GLL2`
- Hardened runtime: enabled
- Sandbox entitlement: false
- Apple Events automation entitlement: true
- Application group includes `2DC432GLL2.com.openai.sky.CUAService`

## Production Lessons For This MCP

- Stable TCC identity matters. A signed app bundle gives macOS one durable
  responsible process for Accessibility, Screen Recording, and Apple Events.
- The production launcher should be bundle-first, not terminal-host-first.
- Helper/daemon boundaries should be observable through diagnostics without
  printing secrets.
- Background-control claims need runtime proof, not source inference. The
  deterministic fixture eval should be the baseline; real-app smoke checks
  should compare behavior against Codex only as an input, not as the product
  definition.

## Follow-Up Comparison Checklist

- Re-run these read-only identity probes after Codex upgrades:

```bash
/usr/libexec/PlistBuddy -c Print:CFBundleIdentifier /Applications/Codex.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c Print:CFBundleShortVersionString /Applications/Codex.app/Contents/Info.plist
codesign -dv /Applications/Codex.app
codesign -d --entitlements :- /Applications/Codex.app
find /Applications/Codex.app/Contents -maxdepth 2 -type f
```

- Inspect helper launch relationships and parent process attribution while
  Codex computer-use is active.
- Compare frontmost-app behavior for observe, AX value set, AX press, menu
  action, and global cursor fallback.
- Compare diagnostics: responsible bundle id, TCC attribution, helper process
  names, and recovery path when capture is wedged.
- Keep binary inspection read-only. Do not copy proprietary strings or code into
  this repo.
