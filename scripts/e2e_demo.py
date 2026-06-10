#!/usr/bin/env python3
"""End-to-end demo: drive a real macOS app through the actual MCP stdio
transport, in the background, and verify each step from returned state.

This is the integration path any MCP client (Claude Code, Cursor, …) uses:
spawn `computer-use-mcp serve`, speak JSON-RPC over stdio, call tools.
"""
import json, re, subprocess, sys, time, threading

BIN = ".build/debug/computer-use-mcp"


class MCP:
    def __init__(self):
        self.p = subprocess.Popen(
            [BIN, "serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, bufsize=1,
        )
        self._id = 0

    def _send(self, method, params=None, notify=False):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        if not notify:
            self._id += 1
            msg["id"] = self._id
        self.p.stdin.write(json.dumps(msg) + "\n")
        self.p.stdin.flush()
        if notify:
            return None
        while True:
            line = self.p.stdout.readline()
            if not line:
                raise RuntimeError("server closed")
            resp = json.loads(line)
            if resp.get("id") == self._id:
                return resp

    def initialize(self):
        r = self._send("initialize", {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "e2e-demo", "version": "1"},
        })
        self._send("notifications/initialized", {}, notify=True)
        return r["result"]["serverInfo"]

    def call(self, name, args):
        r = self._send("tools/call", {"name": name, "arguments": args})
        result = r["result"]
        text = "\n".join(c["text"] for c in result.get("content", []) if c["type"] == "text")
        return text, result.get("isError", False)

    def close(self):
        self.p.terminate()


def textarea_value(state):
    m = re.search(r'AXTextArea[^\n]*value="([^"]*)"', state)
    return m.group(1) if m else None


def find(state, pattern):
    m = re.search(pattern, state)
    return m.group(1) if m else None


def main():
    # Put a DIFFERENT app in front so the whole demo runs against a background app.
    subprocess.run(["open", "-a", "TextEdit"]); time.sleep(1.5)
    subprocess.run(["osascript", "-e", 'tell application "Finder" to activate']); time.sleep(1.0)
    frontmost = subprocess.run(
        ["osascript", "-e", 'tell application "System Events" to name of first process whose frontmost is true'],
        capture_output=True, text=True).stdout.strip()

    mcp = MCP()
    passed, failed = [], []
    try:
        info = mcp.initialize()
        print(f"connected: {info['name']} {info['version']}  (frontmost app: {frontmost})\n")

        # 1. Perceive.
        state, err = mcp.call("get_app_state", {"app": "TextEdit"})
        assert not err, state

        # If the Open panel is showing, start a new document.
        nd = find(state, r'(e\d+@s\d+) AXButton "New Document"')
        if nd:
            state, _ = mcp.call("click", {"app": "TextEdit", "element_id": nd})

        ta = find(state, r'(e\d+@s\d+) AXTextArea')
        assert ta, "no text area:\n" + state[:800]

        # 2. Clear any prior text (confirm: the safety policy gates clearing
        # non-empty content), then type a paragraph.
        mcp.call("set_value", {"app": "TextEdit", "element_id": ta, "value": "", "confirm": True})
        state, _ = mcp.call("get_app_state", {"app": "TextEdit"})
        ta = find(state, r'(e\d+@s\d+) AXTextArea')
        paragraph = "Computer use, for any agent. This MCP server let a background agent write this line."
        state, err = mcp.call("type_text", {"app": "TextEdit", "element_id": ta, "text": paragraph})
        assert not err, state
        got = textarea_value(state)
        (passed if got == paragraph else failed).append(f"type paragraph (got: {got!r})")

        # 3. Select a phrase.
        ta = find(state, r'(e\d+@s\d+) AXTextArea')
        state, err = mcp.call("select_text", {"app": "TextEdit", "element_id": ta, "text": "any agent"})
        sel = find(state, r'AXTextArea[^\n]*selected="([^"]*)"')
        (passed if sel == "any agent" else failed).append(f"select phrase (got: {sel!r})")

        # 4. Verify focus was never stolen — the whole thing ran in the background.
        frontmost_after = subprocess.run(
            ["osascript", "-e", 'tell application "System Events" to name of first process whose frontmost is true'],
            capture_output=True, text=True).stdout.strip()
        ok_bg = frontmost == "Finder" and frontmost_after == "Finder"
        (passed if ok_bg else failed).append(f"stayed in background (frontmost: {frontmost} -> {frontmost_after})")

    finally:
        mcp.close()

    print("PASSED:")
    for p in passed:
        print("  ✓", p)
    if failed:
        print("FAILED:")
        for f in failed:
            print("  ✗", f)
    print(f"\n{len(passed)}/{len(passed)+len(failed)} steps passed over the live MCP stdio transport.")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
