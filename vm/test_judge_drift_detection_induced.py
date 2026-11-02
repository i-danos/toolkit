import unittest
from judgetest import JudgeCase, drift

KEY = ("route", "10.91.0.0/24")


class T(JudgeCase):
    script = "judge-drift-detection-induced.py"

    def run3(self, before=None, during=None, after=None, key="route:default:10.91.0.0/24"):
        return [self.write("b.json", before or drift()), self.write("d.json", during or drift(missing=[KEY])),
                self.write("a.json", after or drift()), "--key", key]

    def test_clean_detected_cleared_passes(self):
        self.assertPass(*self.run3())

    def test_not_detected_fails(self):
        self.assertFail(*self.run3(during=drift()), contains="was not detected")

    def test_detected_under_a_different_key_fails(self):
        self.assertFail(*self.run3(during=drift(missing=[("route", "10.92.0.0/24")])), contains="was not detected")

    def test_dirty_baseline_fails(self):
        self.assertFail(*self.run3(before=drift(missing=[KEY])), contains="baseline is not clean")

    def test_left_behind_after_resume_fails(self):
        self.assertFail(*self.run3(after=drift(missing=[KEY])), contains="still reported")

    def test_extra_side_also_counts_as_detection(self):
        self.assertPass(*self.run3(during=drift(extra=[KEY])))

    def test_bad_key_format_fails(self):
        self.assertFail(*self.run3(key="nonsense"), contains="not CLASS:VRF:PREFIX")

    def test_missing_snapshot_fails(self):
        self.assertFail(self.tmp / "x.json", self.write("d.json", drift()), self.write("a.json", drift()), "--key", "route:default:1.0.0.0/8", contains="input missing")

    def test_truncated_snapshot_fails(self):
        self.assertFail(self.write("b.json", "{\"status\": \"diag"), self.write("d.json", drift()), self.write("a.json", drift()), "--key", "route:default:1.0.0.0/8", contains="truncated")


if __name__ == "__main__":
    unittest.main()
