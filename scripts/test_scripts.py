#!/usr/bin/env python3
"""Deterministic tests for repository helper scripts.

These tests intentionally avoid live GUI, TCC, app launch, clipboard, and
global input paths. They cover the safety helpers that keep preflight and
bundle scaffolding suitable for hosted CI.
"""

from __future__ import annotations

import os
import math
import unittest

import tempfile
import textwrap
from pathlib import Path

import build_app_bundle
import check_version_consistency
import common
import deploy_app_bundle
import preflight
import live_background_eval


class ScriptHelperTests(unittest.TestCase):
    def test_tail_text_handles_bytes_and_none(self) -> None:
        self.assertEqual(preflight.tail_text(b"abc"), "abc")
        self.assertEqual(preflight.tail_text(None), "")

    def test_ci_safe_env_disables_live_flags_and_sets_binary(self) -> None:
        env = preflight.ci_safe_env("/tmp/tool")
        for name in preflight.LIVE_ENV_VARS:
            self.assertEqual(env[name], "0")
        self.assertEqual(env["COMPUTER_USE_MCP_BIN"], "/tmp/tool")

    def test_cursor_position_has_finite_coordinates(self) -> None:
        position = live_background_eval.cursor_position()
        self.assertTrue(set(position) == {"x", "y"})
        self.assertTrue(all(math.isfinite(value) for value in position.values()))

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

    def test_staleness_comparison_with_injected_mtimes(self) -> None:
        self.assertTrue(deploy_app_bundle.is_stale(100.0, 200.0))
        self.assertFalse(deploy_app_bundle.is_stale(200.0, 100.0))
        self.assertFalse(deploy_app_bundle.is_stale(100.0, 100.0))
        # Missing installed executable is always stale.
        self.assertTrue(deploy_app_bundle.is_stale(None, 100.0))
        self.assertTrue(deploy_app_bundle.is_stale(None, None))
        # No source/build mtimes cannot prove staleness.
        self.assertFalse(deploy_app_bundle.is_stale(100.0, None))

    def test_install_dir_precedence_flag_env_default(self) -> None:
        old = os.environ.get("COMPUTER_USE_MCP_INSTALL_DIR")
        try:
            os.environ["COMPUTER_USE_MCP_INSTALL_DIR"] = "/tmp/env-apps"
            self.assertEqual(
                deploy_app_bundle.resolve_install_dir("/tmp/flag-apps"),
                deploy_app_bundle.Path("/tmp/flag-apps"),
            )
            self.assertEqual(
                deploy_app_bundle.resolve_install_dir(None),
                deploy_app_bundle.Path("/tmp/env-apps"),
            )
            os.environ.pop("COMPUTER_USE_MCP_INSTALL_DIR", None)
            self.assertEqual(
                deploy_app_bundle.resolve_install_dir(None),
                deploy_app_bundle.DEFAULT_INSTALL_DIR,
            )
        finally:
            if old is None:
                os.environ.pop("COMPUTER_USE_MCP_INSTALL_DIR", None)
            else:
                os.environ["COMPUTER_USE_MCP_INSTALL_DIR"] = old

    def test_installed_executable_path_shape(self) -> None:
        path = deploy_app_bundle.installed_executable(deploy_app_bundle.Path("/tmp/apps"))
        self.assertEqual(
            path,
            deploy_app_bundle.Path(
                "/tmp/apps/Computer Use MCP.app/Contents/MacOS/computer-use-mcp"
            ),
        )

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

    def test_version_parsers_skip_unreleased_and_match(self) -> None:
        self.assertEqual(
            check_version_consistency.read_version_swift('let version = "0.4.1"\n'),
            "0.4.1",
        )
        self.assertEqual(
            check_version_consistency.read_homebrew_version('  version "0.4.1"\n'),
            "0.4.1",
        )
        changelog = textwrap.dedent(
            """\
            ## [Unreleased]

            Nothing yet.

            ## [0.4.1] — 2026-07-20

            Notes for 0.4.1.

            ## [0.4.0] — 2026-07-03

            Older.
            """
        )
        self.assertEqual(check_version_consistency.read_changelog_version(changelog), "0.4.1")
        self.assertEqual(
            check_version_consistency.changelog_notes_for(changelog, "0.4.1").strip(),
            "Notes for 0.4.1.",
        )

    def test_version_consistency_detects_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "Sources" / "computer-use-mcp").mkdir(parents=True)
            (root / "packaging" / "homebrew").mkdir(parents=True)
            (root / "Sources" / "computer-use-mcp" / "Version.swift").write_text(
                'let version = "0.4.1"\n', encoding="utf-8"
            )
            (root / "packaging" / "homebrew" / "computer-use-mcp.rb").write_text(
                'version "0.4.1"\n', encoding="utf-8"
            )
            (root / "CHANGELOG.md").write_text(
                "## [Unreleased]\n\n## [0.4.0] — 2026-07-03\n\nNotes.\n",
                encoding="utf-8",
            )
            versions = check_version_consistency.collect_versions(root)
            self.assertEqual(versions["Version.swift"], "0.4.1")
            self.assertEqual(versions["CHANGELOG.md"], "0.4.0")
            self.assertEqual(len(set(versions.values())), 2)


if __name__ == "__main__":
    unittest.main()
