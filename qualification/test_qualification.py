#!/usr/bin/env python3

from __future__ import annotations

import json
import sys
import threading
import unittest
from pathlib import Path
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "qualification"))
sys.path.insert(0, str(ROOT / "qualification" / "browser_fixture"))
sys.path.insert(0, str(ROOT / "scripts"))

from generate_capability_inventory import inventory  # noqa: E402
from server import make_server  # noqa: E402
from validate_result import validate_result  # noqa: E402


class QualificationTests(unittest.TestCase):
    def test_valid_example_requires_oracle(self) -> None:
        example = json.loads(
            (ROOT / "qualification/examples/m0-smoke.json").read_text(encoding="utf-8"))
        self.assertEqual([], validate_result(example))
        example["oracle"]["status"] = "not_applicable"
        self.assertIn(
            "successful outcomes require a passed independent oracle",
            validate_result(example),
        )

    def test_task_ids_are_unique(self) -> None:
        tasks = json.loads((ROOT / "qualification/tasks.json").read_text(encoding="utf-8"))
        ids = [item["id"] for group in ("browser", "desktop") for item in tasks[group]]
        self.assertEqual(8, len(ids))
        self.assertEqual(len(ids), len(set(ids)))

    def test_browser_fixture_has_independent_server_oracle(self) -> None:
        server = make_server("127.0.0.1", 0)
        serving = threading.Event()

        def serve() -> None:
            serving.set()
            server.serve_forever(poll_interval=0.01)

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        self.assertTrue(serving.wait(timeout=1), "browser fixture server did not start")
        base = f"http://127.0.0.1:{server.server_address[1]}"
        try:
            page = urlopen(base, timeout=3).read().decode()
            self.assertIn("cobalt-otter-417", page)
            payload = json.dumps({
                "name": "Ada Lovelace",
                "email": "ada@example.test",
                "plan": "portable",
                "updates": True,
                "challenge": "cobalt-otter-417",
            }).encode()
            request = Request(
                base + "/api/submit", data=payload,
                headers={"Content-Type": "application/json"}, method="POST")
            self.assertEqual(200, urlopen(request, timeout=3).status)
            state = json.loads(urlopen(base + "/api/state", timeout=3).read())
            self.assertEqual(1, state["submissions"])
            self.assertEqual("Ada Lovelace", state["last"]["name"])
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)
            self.assertFalse(thread.is_alive(), "browser fixture server did not stop")

    def test_capability_inventory_is_current(self) -> None:
        expected = json.dumps(inventory(), indent=2, sort_keys=True) + "\n"
        actual = (ROOT / "qualification/capabilities.json").read_text(encoding="utf-8")
        self.assertEqual(expected, actual)

    def test_baseline_retains_three_clean_background_trials(self) -> None:
        baseline = json.loads(
            (ROOT / "qualification/baseline.json").read_text(encoding="utf-8"))
        self.assertEqual(17, baseline["mcp"]["toolCount"])
        self.assertGreater(baseline["mcp"]["toolSchemaBytes"], 0)
        self.assertGreater(baseline["mcp"]["startupMs"], 0)
        self.assertEqual(3, len(baseline["backgroundTrials"]))
        self.assertTrue(all(trial["passed"] for trial in baseline["backgroundTrials"]))
        self.assertTrue(all(trial["effectObserved"] for trial in baseline["backgroundTrials"]))
        self.assertTrue(all(trial["frontmostUnchanged"] for trial in baseline["backgroundTrials"]))


if __name__ == "__main__":
    unittest.main()
