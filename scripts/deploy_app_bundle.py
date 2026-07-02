#!/usr/bin/env python3
"""One-command release deploy for the installed runtime app bundle.

Replaces the manual loop of `swift build -c release`, `build_app_bundle.py`,
and `ditto` into ~/Applications, then pokes the installed binary so the
daemon hands over to the fresh executable. `--check` compares the installed
executable's mtime against the newest Sources/ and release-build mtimes so a
stale installed bundle is caught before it causes missing-tool confusion.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import sys
import time
from pathlib import Path

from build_app_bundle import DEFAULT_APP_NAME, DEFAULT_BUNDLE_ID, build_bundle
from preflight import run_step, tail_text


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_INSTALL_DIR = Path.home() / "Applications"
RELEASE_BIN = ROOT / ".build" / "release" / "computer-use-mcp"
STALE_MESSAGE = "installed bundle is older than the current source/build"


def resolve_install_dir(dest: str | None) -> Path:
    raw = dest or os.environ.get("COMPUTER_USE_MCP_INSTALL_DIR")
    return Path(raw).expanduser() if raw else DEFAULT_INSTALL_DIR


def installed_executable(install_dir: Path, app_name: str = DEFAULT_APP_NAME) -> Path:
    return install_dir / f"{app_name}.app" / "Contents" / "MacOS" / "computer-use-mcp"


def is_stale(installed_mtime: float | None, newest_source_mtime: float | None) -> bool:
    """Pure staleness comparison with injected mtimes.

    A missing installed executable counts as stale; missing source/build
    mtimes (fresh checkout, no Sources scan) cannot prove staleness.
    """
    if installed_mtime is None:
        return True
    if newest_source_mtime is None:
        return False
    return installed_mtime < newest_source_mtime


def newest_source_mtime(root: Path = ROOT) -> float | None:
    candidates = [root / ".build" / "release" / "computer-use-mcp"]
    sources = root / "Sources"
    if sources.is_dir():
        candidates.extend(path for path in sources.rglob("*") if path.is_file())
    mtimes = [path.stat().st_mtime for path in candidates if path.exists()]
    return max(mtimes, default=None)


def mtime_of(path: Path) -> float | None:
    return path.stat().st_mtime if path.exists() else None


def iso(mtime: float | None) -> str | None:
    if mtime is None:
        return None
    return datetime.datetime.fromtimestamp(mtime).isoformat(timespec="seconds")


def compact_step(step: dict[str, object]) -> dict[str, object]:
    keep = {"name": step["name"], "status": step["status"], "latency_ms": step["latency_ms"]}
    if step["status"] not in ("passed", "warning"):
        for key in ("returncode", "error", "stderr_tail"):
            if step.get(key):
                keep[key] = step[key]
    return keep


def check(install_dir: Path) -> int:
    installed = installed_executable(install_dir)
    installed_mtime = mtime_of(installed)
    source_mtime = newest_source_mtime()
    stale = is_stale(installed_mtime, source_mtime)
    report = {
        "mode": "check",
        "stale": stale,
        "installed_executable": str(installed),
        "installed_mtime": iso(installed_mtime),
        "newest_source_mtime": iso(source_mtime),
    }
    if installed_mtime is None:
        report["message"] = "no installed bundle found"
    elif stale:
        report["message"] = STALE_MESSAGE
    else:
        report["message"] = "installed bundle is up to date"
    print(json.dumps(report, indent=2))
    return 1 if stale else 0


def deploy(install_dir: Path) -> int:
    steps: list[dict[str, object]] = []
    failed = False

    build = run_step("swift_build_release", ["swift", "build", "-c", "release"], 600)
    steps.append(build)
    if build["status"] != "passed":
        failed = True

    bundle = None
    if not failed:
        start = time.perf_counter()
        try:
            result = build_bundle(
                DEFAULT_APP_NAME, DEFAULT_BUNDLE_ID, sign=True, configuration="release"
            )
            bundle = Path(str(result["bundle"]))
            status = "passed" if result["codesign_status"] == 0 else "failed"
            steps.append(
                {
                    "name": "build_app_bundle",
                    "status": status,
                    "latency_ms": round((time.perf_counter() - start) * 1000, 3),
                    "signed": result["signed"],
                    "codesign_detail": result["codesign_detail"],
                }
            )
            failed = status != "passed"
        except Exception as error:  # loud, structured failure; no traceback JSON-breaking
            steps.append(
                {
                    "name": "build_app_bundle",
                    "status": "failed",
                    "latency_ms": round((time.perf_counter() - start) * 1000, 3),
                    "error": tail_text(str(error)),
                }
            )
            failed = True

    installed = installed_executable(install_dir)
    if not failed and bundle is not None:
        install_dir.mkdir(parents=True, exist_ok=True)
        destination = install_dir / bundle.name
        install = run_step("install_ditto", ["ditto", str(bundle), str(destination)], 120)
        steps.append(install)
        failed = install["status"] != "passed"

    if not failed:
        handover = run_step("daemon_handover", [str(installed), "call", "list_apps", "{}"], 60)
        if handover["status"] != "passed":
            # Headless machines cannot serve list_apps; warn instead of failing.
            handover["status"] = "warning"
        steps.append(handover)

    report = {
        "status": "failed" if failed else "deployed",
        "installed_bundle": str(installed.parents[2]),
        "installed_executable": str(installed),
        "binary_mtime": iso(mtime_of(installed)),
        "steps": [compact_step(step) for step in steps],
    }
    print(json.dumps(report, indent=2))
    return 1 if failed else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dest",
        help="install directory (default $COMPUTER_USE_MCP_INSTALL_DIR or ~/Applications)",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="only report whether the installed bundle is stale; exit 1 when stale",
    )
    args = parser.parse_args()

    install_dir = resolve_install_dir(args.dest)
    if args.check:
        return check(install_dir)
    return deploy(install_dir)


if __name__ == "__main__":
    sys.exit(main())
