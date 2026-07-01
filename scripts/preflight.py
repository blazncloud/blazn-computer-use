#!/usr/bin/env python3
"""Release/preflight runner for deterministic and opt-in live checks."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

from build_app_bundle import DEFAULT_APP_NAME, bundle_path
from common import DEFAULT_BIN, resolve_binary


ROOT = Path(__file__).resolve().parents[1]
LIVE_ENV_VARS = [
    "COMPUTER_USE_MCP_RUN_LIVE_BACKGROUND_EVAL",
    "COMPUTER_USE_MCP_RUN_REAL_APP_SMOKE",
    "COMPUTER_USE_MCP_RUN_LIVE_SMOKE",
]


def tail_text(output: str | bytes | None, limit: int = 4000) -> str:
    if output is None:
        return ""
    if isinstance(output, bytes):
        output = output.decode(errors="replace")
    return output[-limit:]


def ci_safe_env(tool_binary: str | None = None) -> dict[str, str]:
    env = os.environ.copy()
    for name in LIVE_ENV_VARS:
        env[name] = "0"
    if tool_binary:
        env["COMPUTER_USE_MCP_BIN"] = tool_binary
    return env


def select_tool_binary(explicit_bin: str | None, use_app_bundle: bool) -> str:
    if use_app_bundle:
        return str(bundle_path(DEFAULT_APP_NAME) / "Contents" / "MacOS" / "computer-use-mcp")
    if explicit_bin:
        return str(resolve_binary(explicit_bin))
    return str(DEFAULT_BIN)


def run_step(
    name: str, args: list[str], timeout: int, *, env: dict[str, str] | None = None
) -> dict[str, object]:
    start = time.perf_counter()
    try:
        completed = subprocess.run(
            args,
            cwd=ROOT,
            text=True,
            capture_output=True,
            timeout=timeout,
            env=env,
        )
        status = "passed" if completed.returncode == 0 else "failed"
        return {
            "name": name,
            "status": status,
            "command": args,
            "latency_ms": round((time.perf_counter() - start) * 1000, 3),
            "returncode": completed.returncode,
            "stdout_tail": tail_text(completed.stdout),
            "stderr_tail": tail_text(completed.stderr),
        }
    except subprocess.TimeoutExpired as error:
        return {
            "name": name,
            "status": "timeout",
            "command": args,
            "latency_ms": round((time.perf_counter() - start) * 1000, 3),
            "error": str(error),
            "stdout_tail": tail_text(error.stdout),
            "stderr_tail": tail_text(error.stderr),
        }
    except OSError as error:
        return {
            "name": name,
            "status": "failed",
            "command": args,
            "latency_ms": round((time.perf_counter() - start) * 1000, 3),
            "error": str(error),
            "stdout_tail": "",
            "stderr_tail": "",
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--live-background", action="store_true", help="run the live fixture eval")
    parser.add_argument("--live-real-app", action="store_true", help="run the real-app smoke matrix")
    parser.add_argument("--build-app", action="store_true", help="build the local .app wrapper")
    parser.add_argument(
        "--use-app-bundle",
        action="store_true",
        help="build the local .app wrapper and run CLI/smoke checks through its executable",
    )
    parser.add_argument(
        "--bin",
        help="explicit computer-use-mcp binary for CLI/smoke checks; default ignores COMPUTER_USE_MCP_BIN",
    )
    parser.add_argument("--output", help="write JSON report to this path")
    args = parser.parse_args()

    steps: list[dict[str, object]] = []
    tool_binary = select_tool_binary(args.bin, args.use_app_bundle)
    build_app = args.build_app or args.use_app_bundle

    checks = [
        ("script_helper_tests", ["python3", "scripts/test_scripts.py"], 30, ci_safe_env()),
        ("swift_build", ["swift", "build"], 180, None),
        ("swift_test", ["swift", "test"], 180, None),
    ]
    if build_app:
        checks.append(("build_app_bundle", ["python3", "scripts/build_app_bundle.py"], 180, None))
    checks += [
        ("cli_version", [tool_binary, "version"], 30, None),
        ("cli_help", [tool_binary, "help"], 30, None),
        ("health_report_json", [tool_binary, "health_report", "--json"], 30, None),
        ("background_eval_dry_run", ["python3", "scripts/live_background_eval.py"], 30, ci_safe_env(tool_binary)),
    ]
    if args.live_background:
        checks.append(
            ("background_eval_live", ["python3", "scripts/live_background_eval.py", "--live"], 180, ci_safe_env(tool_binary))
        )
    if args.live_real_app:
        checks.append(
            ("real_app_smoke_live", ["python3", "scripts/real_app_smoke.py", "--live"], 240, ci_safe_env(tool_binary))
        )

    for name, command, timeout, env in checks:
        steps.append(run_step(name, command, timeout, env=env))

    report = {
        "passed": all(step["status"] == "passed" for step in steps),
        "tool_binary": tool_binary,
        "using_app_bundle": args.use_app_bundle,
        "steps": steps,
    }
    text = json.dumps(report, indent=2)
    if args.output:
        Path(args.output).write_text(text + "\n", encoding="utf-8")
    print(text)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
