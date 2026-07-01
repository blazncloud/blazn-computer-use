#!/usr/bin/env python3
"""Opt-in real-app compatibility smoke matrix.

Default mode is CI-safe and reports the matrix without opening or controlling
apps. `--live` runs local GUI/TCC checks. Keep this lightweight: deterministic
coverage belongs in `live_background_eval.py`.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LIVE_ENV = "COMPUTER_USE_MCP_RUN_REAL_APP_SMOKE"


def run(
    args: list[str], timeout: int = 120, *, check: bool = True
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, cwd=ROOT, text=True, capture_output=True, timeout=timeout, check=check)


def textedit_smoke() -> dict[str, object]:
    completed = run(["python3", "scripts/e2e_demo.py", "--live"], timeout=180, check=False)
    return {
        "name": "textedit_background_stdio",
        "passed": completed.returncode == 0,
        "returncode": completed.returncode,
        "stdout_tail": completed.stdout[-4000:],
        "stderr_tail": completed.stderr[-4000:],
    }


def finder_readonly_smoke() -> dict[str, object]:
    binary = ROOT / ".build" / "debug" / "computer-use-mcp"
    completed = run([str(binary), "call", "list_windows", '{"app":"Finder"}'], timeout=45, check=False)
    return {
        "name": "finder_list_windows",
        "passed": completed.returncode == 0,
        "returncode": completed.returncode,
        "stdout_tail": completed.stdout[-2000:],
        "stderr_tail": completed.stderr[-2000:],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--live", action="store_true", help="run local GUI/TCC smoke checks")
    args = parser.parse_args()

    if not args.live and os.environ.get(LIVE_ENV) != "1":
        print(
            json.dumps(
                {
                    "live": False,
                    "passed": True,
                    "matrix": ["TextEdit background stdio", "Finder list_windows"],
                    "notes": f"Real-app smoke skipped. Pass --live or set {LIVE_ENV}=1 to opt in.",
                },
                indent=2,
            )
        )
        return 0

    run(["swift", "build"], timeout=180)
    steps = [finder_readonly_smoke(), textedit_smoke()]
    result = {"live": True, "passed": all(step["passed"] for step in steps), "steps": steps}
    print(json.dumps(result, indent=2))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
