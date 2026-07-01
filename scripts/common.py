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
