import importlib.util, unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location("plj", Path(__file__).with_name("power-loss-to-junit.py"))
plj = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(plj)

GOOD = """===== base =====
old sha=aa
===== trial 1: cut 0.6s after the commit is sent =====
  config=OLD
  PASS
===== trial 2: cut 5s after the commit is sent =====
  config=NEW
  PASS

===== 2 passed, 0 failed of 2 cuts =====
"""


class ParseTest(unittest.TestCase):
    def test_trials_and_verdicts(self):
        t = plj.parse(GOOD)
        self.assertEqual([(x[0], x[1]) for x in t], [("1: cut 0.6s after the commit is sent", "PASS"), ("2: cut 5s after the commit is sent", "PASS")])

    def test_fail_and_blocked_are_kept_as_they_are(self):
        t = plj.parse(GOOD.replace("config=NEW\n  PASS", "config=MIXED\n  FAIL"))
        self.assertEqual(t[1][1], "FAIL")

    def test_log_without_trials_is_refused(self):
        with self.assertRaises(ValueError):
            plj.parse("===== base =====\nold\n")

    def test_truncated_log_is_refused(self):
        with self.assertRaises(ValueError):
            plj.parse(GOOD.split("===== 2 passed")[0].rsplit("  PASS", 1)[0])

    def test_trial_without_verdict_before_next_block_is_refused(self):
        with self.assertRaises(ValueError):
            plj.parse("===== trial 1: a =====\nx\n===== trial 2: b =====\n  PASS\n")


class SummaryTest(unittest.TestCase):
    def run_main(self, log_text):
        import subprocess, sys, tempfile
        d = Path(tempfile.mkdtemp())
        (d / "l.log").write_text(log_text)
        return subprocess.run([sys.executable, str(Path(__file__).with_name("power-loss-to-junit.py")), "x_item", str(d / "l.log"),
                               "0" * 64, str(d / "out"), "toolkit/vm/verify-power-loss-more.sh", "test"], capture_output=True, text=True)

    def test_summary_with_a_mode_prefix_is_cross_checked(self):
        bad = GOOD.replace("===== 2 passed, 0 failed of 2 cuts =====", "===== boot: 1 passed, 1 failed of 2 cuts =====")
        r = self.run_main(bad)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("disagrees", r.stderr + r.stdout)

    def test_matching_summary_with_a_mode_prefix_is_accepted(self):
        ok = GOOD.replace("===== 2 passed, 0 failed of 2 cuts =====", "===== boot: 2 passed, 0 failed of 2 cuts =====")
        self.assertEqual(self.run_main(ok).returncode, 0)


if __name__ == "__main__":
    unittest.main()
