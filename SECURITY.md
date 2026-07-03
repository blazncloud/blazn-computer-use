# Security Policy

`computer-use-mcp` is a macOS server that lets an AI agent **observe and operate
the apps on your Mac**. That is a powerful capability, so the security model and
disclosure process matter. This document describes what the binary is trusted
with, the threat model, and how to report a vulnerability privately.

## Reporting a vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Report privately to **minghinmatthew.lam@gmail.com**. Include a description, the
affected version (`computer-use-mcp version`), reproduction steps, and impact.

We aim to acknowledge reports within a few business days and will coordinate a fix
and disclosure timeline with you. Please give us reasonable time to release a fix
before any public disclosure.

## Supported versions

This project is pre-1.0. Security fixes land on `main` and in the latest tagged
release. Older tags are not maintained — upgrade to the latest release for fixes.

| Version | Supported |
| --- | --- |
| `main` / latest release | Yes |
| Older tags | No |

## What the binary is trusted with (TCC permissions)

macOS gates system automation behind TCC (Transparency, Consent, and Control).
This server requires two grants and deliberately avoids a third:

- **Accessibility** — required. Reads the accessibility tree of other apps to
  perceive UI, and posts accessibility actions and synthetic events to drive them.
  This is the permission that makes background control possible.
- **Screen Recording** — required. Captures screenshots via ScreenCaptureKit,
  including windows on inactive Spaces, so the agent (and you) can see app state.
- **Input Monitoring** — *not* required and not requested. The server delivers
  input via accessibility actions and per-window/per-pid event posting, not by
  tapping the global input stream.

macOS attributes these grants to the **responsible host process** that launches
the server (your terminal, IDE, or MCP client) — or, for a notarized build, to the
signed app bundle's stable identity. A different host needs its own grants. Inspect
the current attribution with `computer-use-mcp health_report --json`.

## Threat model summary

The server is designed around one core assumption: **it does not fully trust the
calling agent.** Safety gates are enforced server-side, not delegated to the model.

**In scope (defended):**

- **Destructive actions.** Irreversible button clicks (Delete, Erase, Reset, …) and
  typing into secure password fields require an explicit `"confirm": true` retry.
  Apps on a confirmation list gate every action.
- **Browser navigation risk.** Before acting in a known browser the server reads the
  page URL and applies a policy: `url_deny` patterns block outright (confirm does
  not override); `url_confirm` patterns and built-in payment-page defaults require
  per-action confirmation.
- **Interfering with the human.** When real hardware input was seen recently and the
  agent targets the app you're working in (or uses the global cursor), the call
  returns a recoverable error instead of fighting you for focus.
- **Screen-lock exposure.** While the screen is locked, mutating tools pause with a
  recoverable error and resume on unlock.
- **Session collisions.** Concurrent agents funnel through one shared engine daemon;
  short per-app leases keep two sessions from interleaving actions in the same app.
- **Daemon trust.** The daemon authenticates clients over its unix socket with a
  local secret; `health_report` never prints secret contents.

**Out of scope / your responsibility:**

- **The agent you point at it.** This server executes the actions an MCP client
  asks for, subject to the gates above. Anything you grant the agent, the agent can
  attempt — run it only with agents and tasks you trust.
- **`no_safety` and other override flags.** `COMPUTER_USE_MCP_NO_SAFETY=1`,
  `no_app_lease`, and `no_interference_yield` disable protections by design. Using
  them is an explicit choice; don't enable them for untrusted agents.
- **What the host process can already do.** The grants are attributed to the
  launching host; this server does not escalate beyond what that host holds.
- **Physical/local access** to an unlocked machine.

## Hardening recommendations

- Run with the default safety gates enabled; only relax them for trusted,
  supervised automation.
- For redistribution, codesign with a Developer ID and notarize so TCC grants
  attach to a stable identity rather than an arbitrary terminal
  (see [docs/release/permissions.md](docs/release/permissions.md)).
- Use `computer-use-mcp health_report --json` to audit which process holds the
  grants and where the daemon socket/secret live.
</content>
