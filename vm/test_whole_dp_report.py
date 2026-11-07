"""Tests for whole-dp-report.py: the status of a suite is derived only from what the run recorded, and "did not run" is never "pass".

Run: python3 -m unittest -v vm/test_whole_dp_report.py   (synthetic rows; no container, nothing is built)
"""
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("wdr", HERE / "whole-dp-report.py")
wdr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wdr)


def row(suite="dp_test_x.c", **kw):
    r = {"suite": suite, "iter": 1, "log": suite, "rc": 0, "seconds": 3.0, "meson_ok": 1, "meson_fail": 0, "meson_skip": 0, "meson_timeout": 0,
         "meson_xfail": 0, "meson_upass": 0, "xml": True, "checks": 4, "check_failures": 0, "check_errors": 0, "checks_0_line": 0, "signal": "",
         "wrapper_timeout": False, "mem_avail_mb_start": 9000, "mem_avail_mb_end": 9000, "load1_start": 0.5, "load1_end": 0.5}
    r.update(kw)
    return r


class Classify(unittest.TestCase):
    def test_a_clean_run_with_checks_is_a_pass(self):
        self.assertEqual(wdr.classify(row()), "pass")

    def test_rc0_with_zero_checks_is_not_a_pass(self):
        self.assertEqual(wdr.classify(row(checks=0)), "empty-run")

    def test_the_checks_0_line_is_not_a_pass_even_if_the_xml_lists_tests(self):
        self.assertEqual(wdr.classify(row(checks_0_line=1)), "empty-run")

    def test_a_missing_check_xml_is_not_a_pass(self):
        self.assertEqual(wdr.classify(row(xml=False, checks=0)), "empty-run")

    def test_a_failing_check_inside_an_rc0_run_is_a_fail(self):
        self.assertEqual(wdr.classify(row(check_failures=1)), "fail")

    def test_meson_fail_is_a_fail(self):
        self.assertEqual(wdr.classify(row(rc=1, meson_ok=0, meson_fail=1)), "fail")

    def test_a_signal_is_a_crash_even_though_meson_also_says_fail(self):
        self.assertEqual(wdr.classify(row(rc=1, meson_ok=0, meson_fail=1, signal="killed by signal 11 SIGSEGV")), "crash")

    def test_a_meson_timeout_is_a_timeout_even_after_all_checks_passed(self):
        # dp_test_npf_zone.c: 15 checks pass, then the process never exits and meson kills it
        self.assertEqual(wdr.classify(row(rc=1, meson_ok=0, meson_timeout=1, signal="killed by signal 9 SIGKILL", checks=15)), "timeout")

    def test_the_wrappers_hard_cap_is_a_timeout(self):
        self.assertEqual(wdr.classify(row(rc=124, meson_ok=0, wrapper_timeout=True)), "timeout")

    def test_skipped_is_not_a_pass(self):
        self.assertEqual(wdr.classify(row(rc=0, meson_ok=0, meson_skip=1)), "skipped")

    def test_a_nonzero_rc_nothing_else_recognised_is_no_result_not_a_pass(self):
        self.assertEqual(wdr.classify(row(rc=3, meson_ok=0, checks=0, xml=False)), "no-result")


class Report(unittest.TestCase):
    def run_report(self, results, registered):
        d = Path(tempfile.mkdtemp()); self.addCleanup(lambda: __import__("shutil").rmtree(d, True))
        (d / "logs").mkdir()
        (d / "results.jsonl").write_text("\n".join(json.dumps(r) for r in results) + "\n")
        (d / "registered.txt").write_text("\n".join(registered) + "\n")
        r = subprocess.run([sys.executable, str(HERE / "whole-dp-report.py"), str(d)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads((d / "summary.json").read_text())

    def status(self, doc):
        return {s["suite"]: s["status"] for s in doc["suites"]}

    def test_a_registered_suite_with_no_result_is_not_run_never_pass(self):
        doc = self.run_report([row("dp_test_a.c")], ["dp_test_a.c", "dp_test_b.c"])
        self.assertEqual(self.status(doc), {"dp_test_a.c": "pass", "dp_test_b.c": "not-run"})
        self.assertEqual(doc["counts"], {"pass": 1, "not-run": 1})

    def test_iterations_that_disagree_make_the_suite_mixed_with_the_counts(self):
        rows = [row("dp_test_a.c", iter=1), row("dp_test_a.c", iter=2, rc=1, meson_ok=0, meson_timeout=1, signal="killed by signal 9 SIGKILL", log="dp_test_a.c.iter2")]
        doc = self.run_report(rows, ["dp_test_a.c"])
        s = doc["suites"][0]
        self.assertEqual(s["status"], "mixed")
        self.assertEqual(s["iterations"], {"n": 2, "pass": 1, "timeout": 1})
        self.assertEqual(s["triage"], "unlabelled")        # nothing is guessed: no triage.json, no label

    def test_iterations_that_agree_keep_their_status(self):
        doc = self.run_report([row("dp_test_a.c", iter=i) for i in (1, 2, 3)], ["dp_test_a.c"])
        self.assertEqual(self.status(doc), {"dp_test_a.c": "pass"})
        self.assertEqual(doc["suites"][0]["iterations"], {"n": 3, "pass": 3})

    def test_a_non_pass_without_a_triage_label_is_reported_unlabelled(self):
        doc = self.run_report([row("dp_test_a.c", checks=0)], ["dp_test_a.c"])
        self.assertEqual(doc["suites"][0]["triage"], "unlabelled")


if __name__ == "__main__":
    unittest.main()
