#!/usr/bin/env python3
"""Safe local smoke/benchmark entrypoint for the MCP stdio path.

By default this script does not open apps, call the MCP server, or mutate GUI
state. Pass --live or set COMPUTER_USE_MCP_RUN_LIVE_SMOKE=1 to run the live
TextEdit/Finder smoke that drives the actual MCP stdio transport.
"""
import argparse
import json
import os
import platform
import re
import select
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_BIN = ".build/debug/computer-use-mcp"
LIVE_OPT_IN_ENV = "COMPUTER_USE_MCP_RUN_LIVE_SMOKE"
REPO_ROOT = Path(__file__).resolve().parents[1]


class MCP:
    def __init__(self, bin_path, request_timeout):
        self.p = subprocess.Popen(
            [bin_path, "serve"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )
        self._id = 0
        self.request_timeout = request_timeout

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
            ready, _, _ = select.select([self.p.stdout], [], [], self.request_timeout)
            if not ready:
                raise TimeoutError(
                    f"timed out waiting for {method} response after {self.request_timeout}s"
                )
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
        if self.p.poll() is None:
            self.p.terminate()
            try:
                self.p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.p.kill()


def textarea_value(state):
    m = re.search(r'AXTextArea[^\n]*value="([^"]*)"', state)
    return m.group(1) if m else None


def find(state, pattern):
    m = re.search(pattern, state)
    return m.group(1) if m else None


def truthy_env(name):
    return os.environ.get(name, "").strip().lower() in {"1", "true", "yes", "on"}


def resolve_path(path):
    candidate = Path(path).expanduser()
    if candidate.is_absolute():
        return candidate
    return REPO_ROOT / candidate


def run_text(args, timeout=5):
    try:
        completed = subprocess.run(
            args,
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if completed.returncode != 0:
        return None
    return completed.stdout.strip()


def frontmost_app():
    script = 'tell application "System Events" to name of first process whose frontmost is true'
    return subprocess.run(
        ["osascript", "-e", script],
        cwd=REPO_ROOT,
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    ).stdout.strip()


def wait_for_process(process_name, timeout=10):
    deadline = time.time() + timeout
    while time.time() < deadline:
        completed = subprocess.run(
            ["pgrep", "-x", process_name],
            cwd=REPO_ROOT,
            text=True,
            capture_output=True,
            timeout=5,
        )
        if completed.returncode == 0:
            return
        time.sleep(0.2)
    raise RuntimeError(f"{process_name} did not launch within {timeout}s")


def require_frontmost(expected, phase):
    observed = frontmost_app()
    if observed != expected:
        raise RuntimeError(
            f"{phase} changed frontmost app: expected {expected!r}, observed {observed!r}"
        )
    return observed


def git_dirty():
    completed = subprocess.run(
        ["git", "diff", "--quiet"],
        cwd=REPO_ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return completed.returncode == 1


def collect_metadata(bin_path):
    resolved_bin = resolve_path(bin_path)
    return {
        "git_sha": run_text(["git", "rev-parse", "--short", "HEAD"]),
        "git_dirty": git_dirty(),
        "macos": platform.mac_ver()[0],
        "machine": platform.machine(),
        "python": platform.python_version(),
        "tool_binary": str(resolved_bin),
        "tool_binary_exists": resolved_bin.exists(),
    }


def make_step(name, status, start, notes=None, error=None):
    step = {
        "name": name,
        "status": status,
        "latency_ms": round((time.perf_counter() - start) * 1000, 3),
    }
    if notes:
        step["notes"] = notes
    if error:
        step["error"] = format_error(error)
    return step


def format_error(error):
    if isinstance(error, subprocess.CalledProcessError):
        details = [
            f"command {error.cmd!r} exited {error.returncode}",
        ]
        if error.stdout:
            details.append(f"stdout: {error.stdout[-2000:]}")
        if error.stderr:
            details.append(f"stderr: {error.stderr[-2000:]}")
        return "\n".join(details)
    if isinstance(error, subprocess.TimeoutExpired):
        details = [f"command {error.cmd!r} timed out after {error.timeout}s"]
        if error.stdout:
            details.append(f"stdout: {error.stdout[-2000:]}")
        if error.stderr:
            details.append(f"stderr: {error.stderr[-2000:]}")
        return "\n".join(details)
    return str(error)


def skipped_live_steps(reason):
    now = time.perf_counter()
    return [
        make_step(
            "live_textedit_smoke",
            "skipped",
            now,
            notes=reason,
        )
    ]


def run_live_smoke(bin_path, request_timeout):
    if not Path(bin_path).exists():
        raise FileNotFoundError(f"computer-use-mcp binary not found: {bin_path}")

    steps = []
    server_info = None

    start = time.perf_counter()
    frontmost = frontmost_app()
    if frontmost == "TextEdit":
        raise RuntimeError(
            "TextEdit is already frontmost; refusing to bring another app forward during setup. "
            "Put any non-TextEdit app in front before running the live smoke."
        )
    subprocess.run(["open", "-g", "-a", "TextEdit"], cwd=REPO_ROOT, check=True, timeout=10)
    wait_for_process("TextEdit")
    require_frontmost(frontmost, "background TextEdit launch")
    steps.append(
        make_step("prepare_background_textedit", "passed", start, notes=f"frontmost={frontmost}")
    )

    mcp = MCP(bin_path, request_timeout)
    try:
        start = time.perf_counter()
        info = mcp.initialize()
        server_info = info
        steps.append(
            make_step(
                "initialize_mcp_stdio",
                "passed",
                start,
                notes=f"{info.get('name')} {info.get('version')}",
            )
        )

        # 1. Perceive.
        start = time.perf_counter()
        state, err = mcp.call("get_app_state", {"app": "TextEdit"})
        if err:
            raise RuntimeError(state)
        steps.append(make_step("perceive_textedit", "passed", start))

        # If the Open panel is showing, start a new document.
        start = time.perf_counter()
        nd = find(state, r'(e\d+@s\d+) AXButton "New Document"')
        if nd:
            state, err = mcp.call("click", {"app": "TextEdit", "element_id": nd})
            if err:
                raise RuntimeError(state)
            note = "clicked New Document"
        else:
            note = "New Document button not present"
        ta = find(state, r'(e\d+@s\d+) AXTextArea')
        if not ta:
            raise RuntimeError("no text area:\n" + state[:800])
        steps.append(make_step("find_text_area", "passed", start, notes=note))

        # 2. Clear any prior text, then type a paragraph.
        start = time.perf_counter()
        state, err = mcp.call(
            "set_value",
            {"app": "TextEdit", "element_id": ta, "value": "", "confirm": True},
        )
        if err:
            raise RuntimeError(state)
        state, err = mcp.call("get_app_state", {"app": "TextEdit"})
        if err:
            raise RuntimeError(state)
        ta = find(state, r'(e\d+@s\d+) AXTextArea')
        paragraph = "Computer use, for any agent. This MCP server let a background agent write this line."
        state, err = mcp.call(
            "type_text",
            {"app": "TextEdit", "element_id": ta, "text": paragraph},
        )
        if err:
            raise RuntimeError(state)
        got = textarea_value(state)
        if got != paragraph:
            raise RuntimeError(f"type paragraph mismatch: got {got!r}")
        steps.append(make_step("type_paragraph", "passed", start, notes=f"chars={len(paragraph)}"))

        # 3. Select a phrase.
        start = time.perf_counter()
        ta = find(state, r'(e\d+@s\d+) AXTextArea')
        state, err = mcp.call("select_text", {"app": "TextEdit", "element_id": ta, "text": "any agent"})
        if err:
            raise RuntimeError(state)
        sel = find(state, r'AXTextArea[^\n]*selected="([^"]*)"')
        if sel != "any agent":
            raise RuntimeError(f"select phrase mismatch: got {sel!r}")
        steps.append(make_step("select_phrase", "passed", start, notes=f"selected={sel!r}"))

        # 4. Verify focus was never stolen — the whole thing ran in the background.
        start = time.perf_counter()
        frontmost_after = require_frontmost(frontmost, "live TextEdit smoke")
        steps.append(
            make_step(
                "stayed_in_background",
                "passed",
                start,
                notes=f"frontmost={frontmost}->{frontmost_after}",
            )
        )

    finally:
        mcp.close()
    return steps, server_info


def summarize_status(steps):
    if any(step["status"] == "failed" for step in steps):
        return "failed"
    if steps and all(step["status"] == "skipped" for step in steps):
        return "skipped"
    if any(step["status"] == "skipped" for step in steps):
        return "passed_with_skips"
    return "passed"


def write_result(result, output_format, output_path):
    if output_format == "jsonl":
        run_record = {"type": "run", **{k: v for k, v in result.items() if k != "steps"}}
        lines = [json.dumps(run_record, sort_keys=True)]
        lines.extend(
            json.dumps({"type": "step", **step}, sort_keys=True)
            for step in result["steps"]
        )
        payload = "\n".join(lines) + "\n"
    else:
        payload = json.dumps(result, indent=2, sort_keys=True) + "\n"

    if output_path:
        Path(output_path).parent.mkdir(parents=True, exist_ok=True)
        Path(output_path).write_text(payload)
    else:
        sys.stdout.write(payload)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Run the computer-use-mcp smoke harness. Defaults to a non-mutating structured dry run."
    )
    parser.add_argument(
        "--live",
        action="store_true",
        help=f"run the live GUI smoke; also enabled by {LIVE_OPT_IN_ENV}=1",
    )
    parser.add_argument(
        "--bin",
        default=os.environ.get("COMPUTER_USE_MCP_BIN", DEFAULT_BIN),
        help="path to the computer-use-mcp binary",
    )
    parser.add_argument("--format", choices=("json", "jsonl"), default="json", help="structured output format")
    parser.add_argument("--output", help="write structured output to this path instead of stdout")
    parser.add_argument(
        "--timeout-seconds",
        type=float,
        default=15.0,
        help="per-request timeout for live MCP calls",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    run_id = str(uuid.uuid4())
    started = time.perf_counter()
    live = args.live or truthy_env(LIVE_OPT_IN_ENV)
    bin_path = str(resolve_path(args.bin))
    result = {
        "run_id": run_id,
        "started_at": datetime.now(timezone.utc).isoformat(),
        "mode": "live" if live else "dry_run",
        "status": "unknown",
        "metadata": collect_metadata(args.bin),
        "steps": [],
        "notes": [],
        "config": {
            "live_opt_in_env": LIVE_OPT_IN_ENV,
            "request_timeout_seconds": args.timeout_seconds,
        },
    }

    if live:
        try:
            result["steps"], server_info = run_live_smoke(bin_path, args.timeout_seconds)
            if server_info:
                result["metadata"]["server_info"] = server_info
        except Exception as exc:
            result["steps"].append(make_step("live_textedit_smoke", "failed", started, error=exc))
    else:
        result["notes"].append(f"Live GUI smoke skipped. Pass --live or set {LIVE_OPT_IN_ENV}=1 to opt in.")
        result["steps"] = skipped_live_steps(result["notes"][0])

    result["duration_ms"] = round((time.perf_counter() - started) * 1000, 3)
    result["status"] = summarize_status(result["steps"])
    write_result(result, args.format, args.output)
    sys.exit(1 if result["status"] == "failed" else 0)


if __name__ == "__main__":
    main()
