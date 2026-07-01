#!/usr/bin/env python3
"""Opt-in live background-control eval for computer-use-mcp.

Default mode is non-mutating and CI-safe: it prints a skipped result. Pass
--live or set COMPUTER_USE_MCP_RUN_LIVE_BACKGROUND_EVAL=1 to build and launch a
small fixture app, keep Finder frontmost, mutate the fixture through MCP, and
assert foreground focus did not change.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LIVE_ENV = "COMPUTER_USE_MCP_RUN_LIVE_BACKGROUND_EVAL"
FIXTURE_NAME = "BackgroundControlFixture"
FIXTURE_BUNDLE_ID = "dev.computer-use-mcp.background-fixture"


def run(args: list[str], *, timeout: int = 30, capture: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=ROOT,
        text=True,
        capture_output=capture,
        timeout=timeout,
        check=True,
    )


def build_fixture() -> Path:
    source = ROOT / "scripts" / "fixtures" / "BackgroundControlFixture.swift"
    bundle = ROOT / ".build" / "background-fixture" / f"{FIXTURE_NAME}.app"
    contents = bundle / "Contents"
    macos = contents / "MacOS"
    macos.mkdir(parents=True, exist_ok=True)

    executable = macos / FIXTURE_NAME
    run(["swiftc", str(source), "-o", str(executable)], timeout=60)

    plist = contents / "Info.plist"
    plist.write_text(
        f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>{FIXTURE_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>{FIXTURE_BUNDLE_ID}</string>
  <key>CFBundleName</key>
  <string>{FIXTURE_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
""",
        encoding="utf-8",
    )
    return bundle


def frontmost_app() -> str:
    script = 'tell application "System Events" to get name of first application process whose frontmost is true'
    return run(["osascript", "-e", script], timeout=10).stdout.strip()


def wait_for_fixture() -> None:
    deadline = time.time() + 10
    while time.time() < deadline:
        result = subprocess.run(
            ["pgrep", "-x", FIXTURE_NAME],
            cwd=ROOT,
            text=True,
            capture_output=True,
            timeout=5,
        )
        if result.returncode == 0:
            return
        time.sleep(0.2)
    raise RuntimeError(f"{FIXTURE_NAME} did not launch")


def mcp_call(tool: str, args: dict[str, object]) -> str:
    binary = ROOT / ".build" / "debug" / "computer-use-mcp"
    completed = run([str(binary), "call", tool, json.dumps(args)], timeout=45)
    return completed.stdout + completed.stderr


def extract_text_field_id(state: str) -> str:
    for line in state.splitlines():
        if "AXTextField" in line and "initial-background-value" in line:
            match = re.search(r"([A-Za-z0-9_-]+@[A-Za-z0-9_-]+)\s+AXTextField", line)
            if match:
                return match.group(1)
    raise RuntimeError("could not find fixture text field element id")


def cleanup_fixture() -> None:
    subprocess.run(["pkill", "-x", FIXTURE_NAME], cwd=ROOT, text=True, capture_output=True, timeout=5)


def live_eval() -> dict[str, object]:
    if shutil.which("swiftc") is None:
        raise RuntimeError("swiftc is required for the fixture app")

    run(["swift", "build"], timeout=120)
    bundle = build_fixture()
    cleanup_fixture()
    run(["open", "-gj", str(bundle)], timeout=10)
    wait_for_fixture()

    run(["open", "-a", "Finder"], timeout=10)
    time.sleep(0.5)
    before = frontmost_app()

    state = mcp_call("get_app_state", {"app": FIXTURE_NAME, "max_elements": 200})
    element_id = extract_text_field_id(state)
    expected = f"background-eval-{int(time.time())}"
    mcp_call(
        "set_value",
        {
            "app": FIXTURE_NAME,
            "element_id": element_id,
            "value": expected,
            "include_screenshot": False,
            "include_state": False,
        },
    )
    after = frontmost_app()
    verification = mcp_call("get_app_state", {"app": FIXTURE_NAME, "max_elements": 200})

    return {
        "live": True,
        "fixture_app": str(bundle),
        "frontmost_before": before,
        "frontmost_after": after,
        "frontmost_unchanged": before == after,
        "value_observed": expected in verification,
        "passed": before == after and expected in verification,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--live", action="store_true", help="run the mutating local GUI eval")
    args = parser.parse_args()

    if not args.live and os.environ.get(LIVE_ENV) != "1":
        print(
            json.dumps(
                {
                    "live": False,
                    "passed": True,
                    "notes": f"Live GUI eval skipped. Pass --live or set {LIVE_ENV}=1 to opt in.",
                },
                indent=2,
            )
        )
        return 0

    try:
        result = live_eval()
        print(json.dumps(result, indent=2))
        return 0 if result["passed"] else 1
    finally:
        cleanup_fixture()


if __name__ == "__main__":
    sys.exit(main())
