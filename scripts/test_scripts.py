#!/usr/bin/env python3
"""Deterministic tests for repository helper scripts.

These tests intentionally avoid live GUI, TCC, app launch, clipboard, and
global input paths. They cover the safety helpers that keep preflight and
bundle scaffolding suitable for hosted CI.
"""

from __future__ import annotations

import os
import unittest

import build_app_bundle
import common
import preflight


class ScriptHelperTests(unittest.TestCase):
    def test_tail_text_handles_bytes_and_none(self) -> None:
        self.assertEqual(preflight.tail_text(b"abc"), "abc")
        self.assertEqual(preflight.tail_text(None), "")

    def test_ci_safe_env_disables_live_flags_and_sets_binary(self) -> None:
        env = preflight.ci_safe_env("/tmp/tool")
        for name in preflight.LIVE_ENV_VARS:
            self.assertEqual(env[name], "0")
        self.assertEqual(env["COMPUTER_USE_MCP_BIN"], "/tmp/tool")

    def test_default_preflight_binary_ignores_ambient_env(self) -> None:
        old = os.environ.get("COMPUTER_USE_MCP_BIN")
        try:
            os.environ["COMPUTER_USE_MCP_BIN"] = "/tmp/stale-tool"
            self.assertEqual(preflight.select_tool_binary(None, False), str(common.DEFAULT_BIN))
            self.assertEqual(preflight.select_tool_binary("relative/tool", False), str(common.ROOT / "relative" / "tool"))
        finally:
            if old is None:
                os.environ.pop("COMPUTER_USE_MCP_BIN", None)
            else:
                os.environ["COMPUTER_USE_MCP_BIN"] = old

    def test_run_step_reports_missing_command_as_structured_failure(self) -> None:
        result = preflight.run_step("missing", ["./definitely-not-a-command"], 1)
        self.assertEqual(result["status"], "failed")
        self.assertIn("error", result)

    def test_app_name_rejects_path_traversal(self) -> None:
        with self.assertRaises(ValueError):
            build_app_bundle.validate_app_name("../../SomeApp")
        with self.assertRaises(ValueError):
            build_app_bundle.validate_app_name("/tmp/Victim")

    def test_bundle_path_stays_under_output_root(self) -> None:
        bundle = build_app_bundle.bundle_path("Computer Use MCP")
        self.assertEqual(bundle.parent, (build_app_bundle.ROOT / ".build" / "app-bundle").resolve())
        self.assertTrue(str(bundle).endswith("Computer Use MCP.app"))

    def test_resolve_binary_uses_env_or_default(self) -> None:
        old = os.environ.get("COMPUTER_USE_MCP_BIN")
        try:
            os.environ.pop("COMPUTER_USE_MCP_BIN", None)
            self.assertEqual(common.resolve_binary(), common.DEFAULT_BIN)
            os.environ["COMPUTER_USE_MCP_BIN"] = "relative/tool"
            self.assertEqual(common.resolve_binary(), common.ROOT / "relative" / "tool")
        finally:
            if old is None:
                os.environ.pop("COMPUTER_USE_MCP_BIN", None)
            else:
                os.environ["COMPUTER_USE_MCP_BIN"] = old


if __name__ == "__main__":
    unittest.main()
