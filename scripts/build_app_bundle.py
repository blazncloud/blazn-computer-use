#!/usr/bin/env python3
"""Build a local .app wrapper for manual stable-identity testing."""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BUNDLE_ID = "dev.computer-use-mcp.app"
DEFAULT_APP_NAME = "Computer Use MCP"
APP_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._-]{0,79}$")


def run(args: list[str], *, timeout: int = 120) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, cwd=ROOT, text=True, capture_output=True, timeout=timeout, check=True)


def validate_app_name(app_name: str) -> str:
    if not APP_NAME_RE.fullmatch(app_name):
        raise ValueError(
            "app name must be 1-80 characters and contain only letters, numbers, spaces, '.', '_', or '-'"
        )
    if Path(app_name).name != app_name:
        raise ValueError("app name must be a plain filename component, not a path")
    return app_name


def bundle_path(app_name: str) -> Path:
    safe_name = validate_app_name(app_name)
    output_root = (ROOT / ".build" / "app-bundle").resolve()
    bundle = (output_root / f"{safe_name}.app").resolve()
    if output_root != bundle.parent:
        raise ValueError(f"bundle path escaped output directory: {bundle}")
    return bundle


def build_bundle(
    app_name: str, bundle_id: str, sign: bool, configuration: str = "debug"
) -> dict[str, object]:
    run(["swift", "build", "-c", configuration], timeout=600)
    source_bin = ROOT / ".build" / configuration / "computer-use-mcp"
    if not source_bin.exists():
        raise FileNotFoundError(source_bin)

    bundle = bundle_path(app_name)
    contents = bundle / "Contents"
    macos = contents / "MacOS"
    resources = contents / "Resources"
    if bundle.exists():
        shutil.rmtree(bundle)
    macos.mkdir(parents=True)
    resources.mkdir(parents=True)

    executable = macos / "computer-use-mcp"
    shutil.copy2(source_bin, executable)
    executable.chmod(0o755)

    info = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleDisplayName": app_name,
        "CFBundleExecutable": "computer-use-mcp",
        "CFBundleIdentifier": bundle_id,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": app_name,
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.2.0",
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "14.0",
        "LSUIElement": True,
        "NSAppleEventsUsageDescription": "Computer Use MCP can control Mac apps when an agent explicitly requests it.",
        "NSHumanReadableCopyright": "Local development build",
    }
    with (contents / "Info.plist").open("wb") as handle:
        plistlib.dump(info, handle)
    (contents / "PkgInfo").write_text("APPL????", encoding="ascii")

    signed = False
    signing_error = None
    if sign:
        try:
            run(["codesign", "--force", "--deep", "--sign", "-", str(bundle)], timeout=60)
            signed = True
        except subprocess.CalledProcessError as error:
            signing_error = (error.stderr or error.stdout or str(error)).strip()

    identity = subprocess.run(
        ["codesign", "-dv", str(bundle)],
        cwd=ROOT,
        text=True,
        capture_output=True,
        timeout=30,
    )
    return {
        "bundle": str(bundle),
        "bundle_id": bundle_id,
        "configuration": configuration,
        "executable": str(executable),
        "sign_requested": sign,
        "signed": signed,
        "signing_error": signing_error,
        "codesign_status": identity.returncode,
        "codesign_detail": (identity.stderr or identity.stdout).strip(),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app-name", default=DEFAULT_APP_NAME)
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    parser.add_argument("--no-sign", action="store_true", help="skip ad-hoc codesign")
    parser.add_argument(
        "--configuration",
        choices=["debug", "release"],
        default="debug",
        help="swift build configuration to wrap (release for the installed runtime bundle)",
    )
    args = parser.parse_args()

    result = build_bundle(
        args.app_name, args.bundle_id, sign=not args.no_sign, configuration=args.configuration
    )
    print(json.dumps(result, indent=2))
    return 0 if args.no_sign or result["codesign_status"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
