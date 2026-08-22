#!/usr/bin/env python3
"""Validate qualification evidence without third-party Python packages."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


REQUIRED = {
    "schemaVersion", "project", "commit", "taskId", "evidenceClass",
    "backend", "startedAt", "durationMs", "actionOutcome", "oracle",
    "artifacts", "environment",
}
EVIDENCE_CLASSES = {"unit", "protocol", "browser", "desktop", "remote", "consumer"}
OUTCOMES = {
    "read_only", "verified", "effect_not_verified", "refused", "stale",
    "ambiguous", "unsupported", "unknown_commit", "failed",
}
ORACLE_STATUSES = {"passed", "failed", "not_applicable"}


def validate_result(value: object) -> list[str]:
    if not isinstance(value, dict):
        return ["result must be an object"]
    errors: list[str] = []
    missing = sorted(REQUIRED - set(value))
    if missing:
        errors.append(f"missing required fields: {', '.join(missing)}")
    if value.get("schemaVersion") != 1:
        errors.append("schemaVersion must equal 1")
    if value.get("project") != "blazncloud/blazn-computer-use":
        errors.append("project must identify the Blazn fork")
    if not re.fullmatch(r"[0-9a-f]{40}", str(value.get("commit", ""))):
        errors.append("commit must be a 40-character lowercase SHA")
    if value.get("evidenceClass") not in EVIDENCE_CLASSES:
        errors.append("evidenceClass is invalid")
    if value.get("actionOutcome") not in OUTCOMES:
        errors.append("actionOutcome is invalid")
    if not isinstance(value.get("durationMs"), (int, float)) or value.get("durationMs", -1) < 0:
        errors.append("durationMs must be non-negative")
    oracle = value.get("oracle")
    if not isinstance(oracle, dict):
        errors.append("oracle must be an object")
    else:
        if oracle.get("status") not in ORACLE_STATUSES:
            errors.append("oracle.status is invalid")
        if not isinstance(oracle.get("type"), str) or not oracle.get("type"):
            errors.append("oracle.type is required")
        if not isinstance(oracle.get("evidence"), dict):
            errors.append("oracle.evidence must be an object")
    if value.get("actionOutcome") in {"verified", "read_only"}:
        if not isinstance(oracle, dict) or oracle.get("status") != "passed":
            errors.append("successful outcomes require a passed independent oracle")
    if not isinstance(value.get("artifacts"), list):
        errors.append("artifacts must be an array")
    environment = value.get("environment")
    if not isinstance(environment, dict) or not {"os", "architecture"} <= set(environment):
        errors.append("environment must contain os and architecture")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="+")
    args = parser.parse_args()
    failed = False
    for raw_path in args.paths:
        path = Path(raw_path)
        errors = validate_result(json.loads(path.read_text(encoding="utf-8")))
        if errors:
            failed = True
            print(f"{path}: {'; '.join(errors)}")
        else:
            print(f"{path}: valid")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
