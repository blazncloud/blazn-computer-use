#!/usr/bin/env python3
"""Generate the committed M0 tool inventory from the Swift catalog."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "Sources/computer-use-mcp/Tools/Catalog.swift"
OUTPUT = ROOT / "qualification/capabilities.json"


def inventory() -> dict[str, object]:
    source = CATALOG.read_text(encoding="utf-8")
    names = re.findall(r'ToolSpec\(\s*name:\s*"([^"]+)"', source)
    if len(names) != len(set(names)):
        raise SystemExit("tool catalog contains duplicate names")
    return {
        "schemaVersion": 1,
        "source": str(CATALOG.relative_to(ROOT)),
        "toolCount": len(names),
        "tools": names,
        "interfaces": {
            "primaryAgent": "mcp-stdio",
            "canonicalExecutable": "json-cli",
            "optionalRemote": "mcp-streamable-http"
        },
        "requiredExternalServices": [],
        "requiredModelProviders": []
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    rendered = json.dumps(inventory(), indent=2, sort_keys=True) + "\n"
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != rendered:
            print(f"{OUTPUT.relative_to(ROOT)} is stale; regenerate it")
            return 1
        print(f"{OUTPUT.relative_to(ROOT)} is current")
        return 0
    OUTPUT.write_text(rendered, encoding="utf-8")
    print(f"wrote {OUTPUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
