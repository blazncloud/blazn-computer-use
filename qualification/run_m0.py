#!/usr/bin/env python3
"""Run deterministic M0 qualification gates and retain one aggregate report."""

from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def run(name: str, command: list[str], timeout: int) -> dict[str, object]:
    started = time.perf_counter()
    try:
        result = subprocess.run(
            command, cwd=ROOT, text=True, capture_output=True, timeout=timeout)
        return {
            "name": name,
            "passed": result.returncode == 0,
            "returncode": result.returncode,
            "durationMs": round((time.perf_counter() - started) * 1000, 3),
            "stdoutTail": result.stdout[-4000:],
            "stderrTail": result.stderr[-4000:],
        }
    except (OSError, subprocess.TimeoutExpired) as error:
        return {
            "name": name,
            "passed": False,
            "durationMs": round((time.perf_counter() - started) * 1000, 3),
            "error": str(error),
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", default=str(ROOT / ".build/debug/computer-use-mcp"))
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--output")
    args = parser.parse_args()

    commit = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    output = Path(args.output) if args.output else ROOT / "artifacts/m0" / commit / "qualification.json"
    parity_output = output.parent / "mcp-cli-parity.json"
    commands: list[tuple[str, list[str], int]] = [
        ("qualification_tests", [sys.executable, "qualification/test_qualification.py"], 30),
        ("capability_inventory", [sys.executable, "scripts/generate_capability_inventory.py", "--check"], 30),
    ]
    if not args.skip_build:
        commands += [
            ("swift_build", ["swift", "build"], 600),
            ("swift_test", ["swift", "test"], 600),
        ]
    commands += [
        ("cli_version", [args.bin, "version"], 30),
        ("cli_help", [args.bin, "help"], 30),
        ("mcp_cli_parity", [
            sys.executable, "qualification/mcp_cli_parity.py",
            "--bin", args.bin, "--output", str(parity_output),
        ], 90),
    ]

    output.parent.mkdir(parents=True, exist_ok=True)
    started_at = datetime.now(timezone.utc).isoformat()
    gates = [run(name, command, timeout) for name, command, timeout in commands]
    parity = None
    if parity_output.exists():
        parity = json.loads(parity_output.read_text(encoding="utf-8"))
    manifest = json.loads(
        (ROOT / "qualification/source-manifest.json").read_text(encoding="utf-8"))
    report = {
        "schemaVersion": 1,
        "milestone": "m0",
        "project": manifest["fork"],
        "commit": commit,
        "startedAt": started_at,
        "passed": all(gate["passed"] for gate in gates),
        "environment": {
            "os": platform.platform(),
            "architecture": platform.machine(),
            "python": platform.python_version(),
        },
        "requiredExternalServices": manifest["requiredExternalServices"],
        "requiredModelProviders": manifest["requiredModelProviders"],
        "parity": parity,
        "gates": gates,
        "artifactLayout": "artifacts/<milestone>/<commit>/",
    }
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(output)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
