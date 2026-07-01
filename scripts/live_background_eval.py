#!/usr/bin/env python3
"""Opt-in live background-control eval for computer-use-mcp.

Default mode is non-mutating and CI-safe: it prints a skipped result. Pass
--live or set COMPUTER_USE_MCP_RUN_LIVE_BACKGROUND_EVAL=1 to build and launch a
small fixture app, preserve the current frontmost app, mutate the fixture
through MCP, and assert foreground focus did not change.
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

from common import frontmost_app, resolve_binary


ROOT = Path(__file__).resolve().parents[1]
LIVE_ENV = "COMPUTER_USE_MCP_RUN_LIVE_BACKGROUND_EVAL"
FIXTURE_NAME = "BackgroundControlFixture"
FIXTURE_BUNDLE_ID = "dev.computer-use-mcp.background-fixture"
TOOL_BIN = resolve_binary()


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


def require_frontmost(expected: str, phase: str) -> str:
    observed = frontmost_app()
    if observed != expected:
        raise RuntimeError(
            f"{phase} changed frontmost app: expected {expected!r}, observed {observed!r}"
        )
    return observed


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
    try:
        completed = run([str(TOOL_BIN), "call", tool, json.dumps(args)], timeout=45)
        return completed.stdout + completed.stderr
    except subprocess.CalledProcessError as error:
        output = (error.stdout or "") + (error.stderr or "")
        raise RuntimeError(f"{tool} failed with exit {error.returncode}: {output}") from error


def extract_text_field_id(state: str) -> str:
    for line in state.splitlines():
        if "AXTextField" in line:
            match = re.search(r"([A-Za-z0-9_-]+@[A-Za-z0-9_-]+)\s+AXTextField", line)
            if match:
                return match.group(1)
    raise RuntimeError("could not find fixture text field element id")


def extract_element_id(state: str, role: str, contains: str) -> str:
    for line in state.splitlines():
        if role in line and contains in line:
            match = re.search(r"([A-Za-z0-9_-]+@[A-Za-z0-9_-]+)\s+" + re.escape(role), line)
            if match:
                return match.group(1)
    raise RuntimeError(f"could not find fixture {role} containing {contains!r}")


def make_step(name: str, passed: bool, **fields: object) -> dict[str, object]:
    return {"name": name, "passed": passed, **fields}


def record_frontmost_step(
    steps: list[dict[str, object]], name: str, expected_frontmost: str, **fields: object
) -> None:
    observed = require_frontmost(expected_frontmost, name)
    steps.append(make_step(name, True, frontmost=observed, **fields))


def cleanup_fixture() -> None:
    subprocess.run(["pkill", "-x", FIXTURE_NAME], cwd=ROOT, text=True, capture_output=True, timeout=5)


def wait_for_fixture_state() -> str:
    deadline = time.time() + 10
    last_state = ""
    while time.time() < deadline:
        try:
            # Mid-launch the fixture resolves before its window/AX tree
            # registers; treat tool errors as transient until the deadline.
            last_state = mcp_call("get_app_state", {"app": FIXTURE_NAME, "max_elements": 200})
            extract_text_field_id(last_state)
            extract_element_id(last_state, "AXButton", "Mark Pressed")
            return last_state
        except RuntimeError as error:
            last_state = last_state or str(error)
            time.sleep(0.2)
    raise RuntimeError(f"{FIXTURE_NAME} did not expose expected AX elements:\n{last_state}")


def live_eval() -> dict[str, object]:
    if shutil.which("swiftc") is None:
        raise RuntimeError("swiftc is required for the fixture app")

    run(["swift", "build"], timeout=120)
    bundle = build_fixture()
    before = frontmost_app()
    cleanup_fixture()
    run(["open", "-gj", str(bundle)], timeout=10)
    wait_for_fixture()
    require_frontmost(before, "background fixture launch")

    state = wait_for_fixture_state()
    element_id = extract_text_field_id(state)
    button_id = extract_element_id(state, "AXButton", "Mark Pressed")
    steps: list[dict[str, object]] = []

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
    record_frontmost_step(steps, "set_value_kept_frontmost", before)
    verification = mcp_call("get_app_state", {"app": FIXTURE_NAME, "max_elements": 200})
    steps.append(make_step("set_value_background", expected in verification, observed=expected in verification))

    typed = f"{expected}-typed"
    element_id = extract_text_field_id(verification)
    clear_result = mcp_call(
        "set_value",
        {
            "app": FIXTURE_NAME,
            "element_id": element_id,
            "value": "",
            "confirm": True,
            "include_screenshot": False,
            "include_state": True,
        },
    )
    record_frontmost_step(steps, "clear_value_kept_frontmost", before)
    element_id = extract_text_field_id(clear_result)
    typed_result = mcp_call(
        "type_text",
        {
            "app": FIXTURE_NAME,
            "element_id": element_id,
            "text": typed,
            "include_screenshot": False,
            "include_state": True,
        },
    )
    record_frontmost_step(steps, "type_text_kept_frontmost", before)
    steps.append(make_step("type_text_background", typed in typed_result, observed=typed in typed_result))
    button_id = extract_element_id(typed_result, "AXButton", "Mark Pressed")

    click_result = mcp_call(
        "click",
        {
            "app": FIXTURE_NAME,
            "element_id": button_id,
            "include_screenshot": False,
            "include_state": True,
        },
    )
    record_frontmost_step(steps, "click_kept_frontmost", before)
    steps.append(make_step("click_axpress_background", "button-status: pressed" in click_result))
    steps.append(
        make_step(
            "open_url_focus_gate_source_only",
            True,
            live_invoked=False,
            evidence="FocusTelemetryTests covers requireFocusChangeAllowed; live eval does not call open_url.",
        )
    )

    after = require_frontmost(before, "live background eval")
    verification = mcp_call("get_app_state", {"app": FIXTURE_NAME, "max_elements": 200})
    all_steps_passed = all(step["passed"] for step in steps)

    return {
        "live": True,
        "tool_binary": str(TOOL_BIN),
        "fixture_app": str(bundle),
        "frontmost_before": before,
        "frontmost_after": after,
        "frontmost_unchanged": before == after,
        "steps": steps,
        "value_observed": expected in verification or typed in verification,
        "passed": before == after and all_steps_passed,
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
