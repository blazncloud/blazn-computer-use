#!/usr/bin/env python3
"""Prove JSON CLI and MCP expose the same local health outcome."""

from __future__ import annotations

import argparse
import json
import os
import selectors
import subprocess
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROVIDER_ENV = {
    "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GOOGLE_API_KEY", "GEMINI_API_KEY",
    "OPENROUTER_API_KEY", "BROWSERBASE_API_KEY", "DAYTONA_API_KEY",
}


def child_env() -> dict[str, str]:
    env = {key: value for key, value in os.environ.items() if key not in PROVIDER_ENV}
    home = Path("/tmp") / f"blazn-m0-home-{os.getuid()}"
    home.mkdir(parents=True, exist_ok=True)
    env["CFFIXED_USER_HOME"] = str(home)
    env["TMPDIR"] = str(home)
    env["COMPUTER_USE_MCP_NO_TELEMETRY"] = "1"
    return env


def send(process: subprocess.Popen[str], value: object) -> None:
    assert process.stdin is not None
    process.stdin.write(json.dumps(value, separators=(",", ":")) + "\n")
    process.stdin.flush()


def receive(
    process: subprocess.Popen[str], selector: selectors.BaseSelector,
    request_id: int, timeout: float,
) -> dict[str, object]:
    deadline = time.monotonic() + timeout
    assert process.stdout is not None
    while time.monotonic() < deadline:
        events = selector.select(max(0, deadline - time.monotonic()))
        if not events:
            break
        line = process.stdout.readline()
        if not line:
            break
        message = json.loads(line)
        if message.get("id") == request_id:
            return message
    raise TimeoutError(f"no MCP response for request {request_id}")


def invariants(result: dict[str, object]) -> dict[str, object]:
    structured = result.get("structuredContent")
    if not isinstance(structured, dict):
        raise AssertionError("health_report result lacks structuredContent")
    permissions = structured.get("permissions")
    if not isinstance(permissions, dict):
        raise AssertionError("health_report lacks permissions")
    return {
        "version": structured.get("version"),
        "reportVersion": structured.get("reportVersion"),
        "accessibility": permissions.get("accessibility"),
        "screenRecording": permissions.get("screenRecording"),
        # The responsible process legitimately differs: direct CLI calls are
        # attributed to the executable while daemon-backed MCP calls are
        # attributed to launchd. Presence is the stable contract.
        "tccAttributionPresent": bool(structured.get("tccAttribution")),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", default=str(ROOT / ".build/debug/computer-use-mcp"))
    parser.add_argument("--output")
    args = parser.parse_args()
    binary = str(Path(args.bin).resolve())
    env = child_env()

    cli_started = time.monotonic()
    cli = subprocess.run(
        [binary, "call", "--json", "health_report", "{}"],
        cwd=ROOT, env=env, text=True, capture_output=True, timeout=30)
    if cli.returncode != 0:
        raise SystemExit(f"JSON CLI failed: {cli.stderr or cli.stdout}")
    cli_envelope = json.loads(cli.stdout)
    cli_result = cli_envelope.get("result")
    if not isinstance(cli_result, dict):
        raise SystemExit("JSON CLI result envelope is missing result")

    process = subprocess.Popen(
        [binary, "serve"], cwd=ROOT, env=env, text=True, bufsize=1,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    selector = selectors.DefaultSelector()
    assert process.stdout is not None
    selector.register(process.stdout, selectors.EVENT_READ)
    mcp_started = time.monotonic()
    try:
        send(process, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "m0-parity", "version": "1"}}})
        initialize = receive(process, selector, 1, 20)
        initialized_at = time.monotonic()
        send(process, {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
        send(process, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        tools_message = receive(process, selector, 2, 20)
        send(process, {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {
            "name": "health_report", "arguments": {}}})
        mcp_message = receive(process, selector, 3, 30)
    finally:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
    mcp_result = mcp_message.get("result")
    if not isinstance(mcp_result, dict):
        raise SystemExit("MCP response is missing result")
    tools_result = tools_message.get("result")
    if not isinstance(tools_result, dict) or not isinstance(tools_result.get("tools"), list):
        raise SystemExit("MCP tools/list response is missing tools")
    tools = tools_result["tools"]

    cli_invariants = invariants(cli_result)
    mcp_invariants = invariants(mcp_result)
    if cli_invariants != mcp_invariants:
        raise SystemExit(
            "MCP/CLI invariant mismatch:\n"
            + json.dumps({"cli": cli_invariants, "mcp": mcp_invariants}, indent=2))

    report = {
        "schemaVersion": 1,
        "passed": True,
        "binary": binary,
        "cliLatencyMs": round((mcp_started - cli_started) * 1000, 3),
        "mcpInitializeMs": round((initialized_at - mcp_started) * 1000, 3),
        "mcpRoundTripMs": round((time.monotonic() - mcp_started) * 1000, 3),
        "mcpProtocolVersion": initialize.get("result", {}).get("protocolVersion"),
        "toolCount": len(tools),
        "toolSchemaBytes": len(json.dumps(tools, separators=(",", ":")).encode()),
        "providerEnvironmentRemoved": sorted(PROVIDER_ENV),
        "requiredExternalServices": [],
        "invariants": cli_invariants,
    }
    text = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        Path(args.output).write_text(text, encoding="utf-8")
    print(text, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
