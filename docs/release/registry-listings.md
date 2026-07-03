# MCP registry listing (DRAFT)

Draft copy for listing `computer-use-mcp` in MCP server registries/directories.
**Not submitted anywhere.** Review and update version/URLs before any submission.
Keep this file in sync with the README when capabilities change.

---

## Identity

- **Name:** computer-use-mcp
- **Slug / id:** `computer-use-mcp`
- **Homepage / repo:** https://github.com/minghinmatthewlam/computer-use-mcp
- **License:** MIT
- **Platform:** macOS 14+
- **Language:** Swift 6
- **Transport:** stdio
- **Launch:** `computer-use-mcp serve`

## One-liner (≤ 100 chars)

> Background-safe macOS computer use over MCP — drive occluded apps without stealing your cursor.

## Short description (≤ 300 chars)

> An open, agent-agnostic MCP server that lets any client see and operate the apps
> on your Mac — in the background, without hijacking the cursor or stealing focus.
> Accessibility-first with pixel fallback, verified action outcomes, teach/replay
> skills, a visible agent cursor, and multi-session safety.

## Long description

> `computer-use-mcp` exposes macOS computer use as a standard MCP server: a single
> signed Swift binary any compliant client (Claude Code, Cursor, Codex CLI, Gemini
> CLI, or your own agent) can drive over stdio.
>
> It is accessibility-first for precision, with an automatic pixel-coordinate
> fallback for apps with poor accessibility trees; the agent's own vision provides
> the grounding, so there is no bundled ML model. A layered input ladder (AX action
> → per-window event → per-pid event, with an opt-in global-cursor fallback)
> delivers actions to the target app without moving the real cursor or stealing
> focus, so you keep working while the agent works.
>
> Every mutating action re-reads its target and reports whether the effect actually
> occurred (not just whether the call returned). Tasks can be taught once — by the
> agent or by user demonstration — and replayed at engine speed as durable,
> self-healing skills. A shared engine daemon with per-app leases keeps concurrent
> agents from colliding, a visible self-drawn cursor lets you watch what the agent
> does, and server-side safety gates (destructive-action confirmation, browser URL
> policy, human-interference yield, screen-lock pause) run independent of the
> calling agent.

## Categories / tags

`computer-use`, `macos`, `automation`, `accessibility`, `desktop`, `gui`, `agent`,
`skills`, `screen-capture`

## Tools (surface)

- **Perceive:** `get_app_state`, `find`, `list_apps`, `list_windows`, `read_text`,
  `wait_for`
- **Act:** `click`, `type_text`, `press_key`, `scroll`, `drag`, `set_value`,
  `select_text`, `perform_secondary_action`, `click_menu_item`, `batch`
- **System:** `open_app`, `open_url`, `manage_window`, `read_clipboard`,
  `write_clipboard`
- **Skills:** `save_skill`, `run_skill`, `list_skills`, `get_skill`,
  `delete_skill`, `record_skill_start`, `record_skill_stop`

## Config snippet (generic MCP client)

```json
{
  "mcpServers": {
    "computer-use": { "command": "computer-use-mcp", "args": ["serve"] }
  }
}
```

## Permissions / notes

- Requires **Accessibility** and **Screen Recording** grants (Input Monitoring is
  not required). macOS attributes grants to the launching host or, for a notarized
  build, to the app-bundle identity.
- macOS only; runs while the Mac is unlocked.

## Target registries and per-registry notes

These are the three registries to target. **Do not submit any of them without the
maintainer's explicit approval** — this file is draft copy only.

### 1. `modelcontextprotocol/servers` (official community list)

- Submission is a PR to the GitHub repo adding an entry to the community-servers
  README list (alphabetical), not a form.
- Format is a one-line bullet: name (linked to this repo) + the short one-liner
  above. Keep it to a single sentence.
- Draft bullet:
  > **[computer-use-mcp](https://github.com/minghinmatthewlam/computer-use-mcp)** —
  > Background-safe macOS computer use: drive occluded apps over MCP without
  > stealing your cursor or focus.

### 2. PulseMCP (pulsemcp.com)

- Directory listing; submit via their "add a server" flow. Uses the name,
  repo/homepage URL, the short description, and category tags.
- Use the **short description** and the **categories/tags** from this doc.
- Highlight the macOS-only requirement and the Accessibility/Screen Recording
  permission note so users aren't surprised.

### 3. mcp.so

- Directory listing; submit via their add-server flow. Uses name, repo URL,
  description, and tags; often auto-pulls the README, so keep the README's first
  paragraph and tool list accurate.
- Reuse the **long description** and the **tools surface** from this doc.

## Pre-submission checklist

- [ ] Maintainer has explicitly approved submitting to each registry.
- [ ] First GitHub release is published (or the listing links to source install).
- [ ] Version and URLs updated to the released tag.
- [ ] README and this draft agree on the tool surface and capabilities.
- [ ] License, homepage, and contact fields verified.
- [ ] macOS-only + TCC permission requirements are stated in each listing.
