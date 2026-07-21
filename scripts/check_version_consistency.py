#!/usr/bin/env python3
"""Fail when Version.swift, Homebrew formula, and CHANGELOG disagree.

Compares the binary version, packaging/homebrew/computer-use-mcp.rb version,
and the first Keep-a-Changelog version heading (skipping [Unreleased]). This
guards against tagging a release that never got a CHANGELOG section.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

VERSION_SWIFT_RE = re.compile(
    r'^\s*let\s+version\s*=\s*"(?P<version>[0-9]+\.[0-9]+\.[0-9]+)"\s*$',
    re.MULTILINE,
)
HOMEBREW_VERSION_RE = re.compile(
    r'^\s*version\s+"(?P<version>[0-9]+\.[0-9]+\.[0-9]+)"\s*$',
    re.MULTILINE,
)
CHANGELOG_VERSION_RE = re.compile(
    r"^## \[(?P<label>[^\]]+)\](?:\s*—\s*(?P<date>\S+))?\s*$",
    re.MULTILINE,
)


def read_version_swift(text: str) -> str:
    match = VERSION_SWIFT_RE.search(text)
    if not match:
        raise ValueError('Version.swift: expected `let version = "X.Y.Z"`')
    return match.group("version")


def read_homebrew_version(text: str) -> str:
    match = HOMEBREW_VERSION_RE.search(text)
    if not match:
        raise ValueError('computer-use-mcp.rb: expected `version "X.Y.Z"`')
    return match.group("version")


def read_changelog_version(text: str) -> str:
    for match in CHANGELOG_VERSION_RE.finditer(text):
        label = match.group("label").strip()
        if label.lower() == "unreleased":
            continue
        if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", label):
            return label
        raise ValueError(f"CHANGELOG.md: unexpected version heading [{label}]")
    raise ValueError("CHANGELOG.md: no versioned ## [X.Y.Z] section found")


def changelog_notes_for(text: str, version: str) -> str:
    """Return the body under ## [version] until the next ## heading."""
    pattern = re.compile(
        rf"^## \[{re.escape(version)}\](?:\s*—\s*\S+)?\s*$",
        re.MULTILINE,
    )
    match = pattern.search(text)
    if not match:
        raise ValueError(f"CHANGELOG.md: missing ## [{version}] section")
    start = match.end()
    next_heading = re.search(r"^##\s+", text[start:], re.MULTILINE)
    end = start + next_heading.start() if next_heading else len(text)
    return text[start:end].strip() + "\n"


def collect_versions(root: Path) -> dict[str, str]:
    version_swift = (root / "Sources" / "computer-use-mcp" / "Version.swift").read_text(
        encoding="utf-8"
    )
    homebrew = (root / "packaging" / "homebrew" / "computer-use-mcp.rb").read_text(
        encoding="utf-8"
    )
    changelog = (root / "CHANGELOG.md").read_text(encoding="utf-8")
    return {
        "Version.swift": read_version_swift(version_swift),
        "packaging/homebrew/computer-use-mcp.rb": read_homebrew_version(homebrew),
        "CHANGELOG.md": read_changelog_version(changelog),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=ROOT,
        help="repository root (default: parent of scripts/)",
    )
    parser.add_argument(
        "--print-notes",
        action="store_true",
        help="print CHANGELOG notes for the agreed version to stdout and exit 0",
    )
    args = parser.parse_args()
    root = args.root.resolve()

    try:
        versions = collect_versions(root)
    except (OSError, ValueError) as error:
        print(f"version-consistency: {error}", file=sys.stderr)
        return 1

    unique = set(versions.values())
    if len(unique) != 1:
        print("version-consistency: mismatch across version sources:", file=sys.stderr)
        for path, version in versions.items():
            print(f"  {path}: {version}", file=sys.stderr)
        return 1

    version = unique.pop()
    if args.print_notes:
        changelog = (root / "CHANGELOG.md").read_text(encoding="utf-8")
        try:
            sys.stdout.write(changelog_notes_for(changelog, version))
        except ValueError as error:
            print(f"version-consistency: {error}", file=sys.stderr)
            return 1
        return 0

    print(f"version-consistency: ok ({version})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
