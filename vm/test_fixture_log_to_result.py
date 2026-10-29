#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-only
"""Tests for fixture-log-to-result.py: above all, that it refuses what it cannot account for.

Run: python3 -m unittest -v toolkit/vm/test_fixture_log_to_result.py   (or run this file)
"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
TOOL = HERE / "fixture-log-to-result.py"
REPRO = HERE.parents[3] / "acceptance-p05" / "repro-20261028" / "lifecycle"

spec = importlib.util.spec_from_file_location("fixture_log_to_result", TOOL)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

LIVE = (
    "===== 1 =====\n"
    "  PASS     alpha -- 12s\n"
    "  PASS     beta\n"
)
GOOD = LIVE + "\n===== Result =====\n  PASS     alpha\n  PASS     beta\n  2 of 2\n"


def convert(text, *extra):
    with tempfile.TemporaryDirectory() as d:
        log, out = Path(d, "x.log"), Path(d, "x.json")
        log.write_text(text)
        p = subprocess.run([sys.executable, str(TOOL), str(log), "--gate", "G", "--image", "/a/b.iso",
                            "--out", str(out), "--timestamp", "T", *extra],
                           capture_output=True, text=True)
        return p, (json.loads(out.read_text()) if out.exists() else None)


class FixtureLogToResult(unittest.TestCase):
    def test_schema_and_detail_carried_from_live_lines(self):
        p, r = convert(GOOD)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(list(r), ["schema_version", "read_only", "gate", "image", "timestamp",
                                   "passed", "total", "status", "checks"])
        self.assertEqual((r["image"], r["passed"], r["total"], r["status"]), ("b.iso", 2, 2, "PASS"))
        self.assertEqual(r["checks"][0], {"check": "alpha", "status": "PASS", "detail": "12s"})

    @unittest.skipUnless((REPRO / "accept-lifecycle.log").exists(), "repro evidence not on this host")
    def test_reproduces_the_harness_json_from_its_log(self):
        want = json.loads((REPRO / "lifecycle-result.json").read_text())
        p, got = convert((REPRO / "accept-lifecycle.log").read_text())
        self.assertEqual(p.returncode, 0, p.stderr)
        for k in ("passed", "total", "status", "checks"):
            self.assertEqual(got[k], want[k], k)

    def test_failure_makes_the_result_incomplete(self):
        p, r = convert("  PASS     a\n  FAIL     b -- boom\n  1 of 2\n")
        self.assertEqual(p.returncode, 0)
        self.assertEqual((r["passed"], r["total"], r["status"]), (1, 2, "INCOMPLETE"))
        self.assertEqual(r["checks"][1]["detail"], "boom")

    def test_detail_splits_on_the_first_separator_only(self):
        p, r = convert("  PASS     a -- b -- c\n  1 of 1\n")
        self.assertEqual((r["checks"][0]["check"], r["checks"][0]["detail"]), ("a", "b -- c"))

    def test_rejects_a_log_with_no_check_lines(self):
        p, r = convert("===== 0 =====\nbooting\n  3 of 3\n")
        self.assertEqual(p.returncode, 2)
        self.assertIsNone(r)
        self.assertIn("no check lines", p.stderr)

    def test_rejects_an_empty_log(self):
        for text in ("", "\n  \n"):
            p, r = convert(text)
            self.assertEqual(p.returncode, 2)
            self.assertIsNone(r)
            self.assertIn("empty", p.stderr)

    def test_rejects_a_repeated_check_name(self):
        p, r = convert("  PASS     a\n  FAIL     a\n  1 of 2\n")
        self.assertEqual(p.returncode, 2)
        self.assertIsNone(r)
        self.assertIn("duplicate", p.stderr)

    def test_rejects_a_summary_that_contradicts_the_statuses(self):
        for tail in ("  2 of 2\n", "  1 of 3\n"):
            p, r = convert("  PASS     a\n  FAIL     b\n" + tail)
            self.assertEqual(p.returncode, 2, tail)
            self.assertIsNone(r)
            self.assertIn("summary", p.stderr)

    def test_rejects_a_result_section_that_disagrees_with_the_live_lines(self):
        p, r = convert(LIVE + "===== Result =====\n  PASS     alpha\n  FAIL     beta\n  1 of 2\n")
        self.assertEqual(p.returncode, 2)
        self.assertIsNone(r)
        self.assertIn("Result section", p.stderr)

    def test_rejects_a_log_with_no_summary_line_by_default(self):
        p, r = convert("  PASS     a\n  PASS     b\n")
        self.assertEqual(p.returncode, 2)
        self.assertIsNone(r)
        self.assertIn("summary", p.stderr)

    def test_allow_missing_summary_accepts_it_but_still_checks_a_present_one(self):
        p, r = convert("  PASS     a\n  PASS     b\n", "--allow-missing-summary")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual((r["passed"], r["total"], r["status"]), (2, 2, "PASS"))
        p, r = convert("  PASS     a\n  FAIL     b\n  2 of 2\n", "--allow-missing-summary")
        self.assertEqual(p.returncode, 2)


if __name__ == "__main__":
    unittest.main()
