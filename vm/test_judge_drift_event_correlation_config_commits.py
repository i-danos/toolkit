import unittest
from judgetest import JudgeCase


def ev(prefix, gap=1.2, commit="2026-11-01T00:00:01+00:00"):
    return {"kind": "missing", "class": "route", "vrf": "default", "prefix": prefix, "type": "resolved",
            "correlated_commit": {"commit_timestamp": commit, "gap_seconds": gap}}


def doc(*events, window=30.0):
    return {"schema_version": 1, "window_seconds": window, "events": list(events), "read_only": True}


class T(JudgeCase):
    script = "judge-drift-event-correlation-config-commits.py"

    def test_every_event_tied_to_a_commit_passes(self):
        self.assertPass(self.write("c.json", doc(ev("10.1.0.0/24"), ev("10.2.0.0/24", 2.0, "2026-11-01T00:01:00+00:00"))), "--expect-commits", "2")

    def test_orphan_event_fails_and_quotes_the_reason(self):
        orphan = {"kind": "extra", "prefix": "10.9.0.0/24", "correlated_commit": None, "correlation_note": "no commit within 30s"}
        self.assertFail(self.write("c.json", doc(ev("10.1.0.0/24"), orphan)), contains="orphan event")

    def test_gap_outside_window_fails(self):
        self.assertFail(self.write("c.json", doc(ev("10.1.0.0/24", 45.0))), contains="outside 0..30")

    def test_negative_gap_fails(self):
        self.assertFail(self.write("c.json", doc(ev("10.1.0.0/24", -0.5))), contains="outside 0..30")

    def test_wrong_number_of_distinct_commits_fails(self):
        self.assertFail(self.write("c.json", doc(ev("10.1.0.0/24"), ev("10.2.0.0/24"))), "--expect-commits", "2", contains="1 distinct commit")

    def test_no_events_fails(self):
        self.assertFail(self.write("c.json", doc()), contains="no events")

    def test_real_uncorrelated_history_fails(self):
        # the real events file from the 2026-09-20 run has never been through the correlator: no correlated_commit anywhere
        from judgetest import DATA
        import json
        events = json.load(open(DATA / "dpa-drift-events-real.json"))
        events["window_seconds"] = 30.0
        self.assertFail(self.write("c.json", events), contains="orphan event")

    def test_missing_input_fails(self):
        self.assertFail(self.tmp / "nope.json", contains="input missing")

    def test_truncated_input_fails(self):
        self.assertFail(self.write("c.json", '{"events": [{"prefix"'), contains="truncated")


if __name__ == "__main__":
    unittest.main()
