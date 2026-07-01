#!/usr/bin/env python3
"""Shared helpers for non-live and opt-in live smoke scripts."""

from __future__ import annotations

import os
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BIN = ROOT / ".build" / "debug" / "computer-use-mcp"


def resolve_binary(path: str | None = None) -> Path:
    raw = path or os.environ.get("COMPUTER_USE_MCP_BIN")
    if not raw:
        return DEFAULT_BIN
    candidate = Path(raw).expanduser()
    if not candidate.is_absolute():
        candidate = ROOT / candidate
    return candidate


def frontmost_app() -> str:
    """Name of the frontmost app via lsappinfo.

    lsappinfo needs no TCC grant; osascript -> System Events hangs on an
    Automation permission prompt when the terminal was never approved.
    """
    import subprocess

    def run(args: list[str]) -> str:
        return subprocess.run(
            args, cwd=ROOT, check=True, capture_output=True, text=True, timeout=10
        ).stdout.strip()

    front = run(["lsappinfo", "front"])
    info = run(["lsappinfo", "info", "-only", "name", front])
    # Output looks like: "LSDisplayName"="Finder"
    if "=" in info:
        return info.split("=", 1)[1].strip().strip('"')
    return info
