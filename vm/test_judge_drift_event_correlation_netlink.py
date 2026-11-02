import unittest
from judgetest import JudgeCase


def ev(prefix, verb="RTM_NEWROUTE", gap=0.4):
    return {"prefix": prefix, "type": "resolved", "correlated_netlink_route": {"verb": verb, "table": "254", "gap_seconds": gap}}


def doc(*events, window=30.0):
    return {"schema_version": 1, "window_seconds": window, "events": list(events), "read_only": True}


class T(JudgeCase):
    script = "judge-drift-event-correlation-netlink.py"

    def test_every_event_tied_to_a_netlink_message_passes(self):
        self.assertPass(self.write("n.json", doc(ev("10.1.0.0/24"), ev("10.2.0.0/24", "RTM_DELROUTE"))), "--expect-prefix", "10.2.0.0/24")

    def test_debug_not_enabled_fails_and_quotes_the_note(self):
        e = {"prefix": "10.1.0.0/24", "correlated_netlink_route": None, "netlink_correlation_note": "no RTM_*ROUTE lines in the log -- nl_route debug was likely not enabled"}
        self.assertFail(self.write("n.json", doc(e)), contains="nl_route debug")

    def test_unknown_verb_fails(self):
        self.assertFail(self.write("n.json", doc(ev("10.1.0.0/24", "RTM_GETROUTE"))), contains="verb")

    def test_gap_outside_window_fails(self):
        self.assertFail(self.write("n.json", doc(ev("10.1.0.0/24", gap=99))), contains="outside 0..30")

    def test_expected_prefix_without_an_event_fails(self):
        self.assertFail(self.write("n.json", doc(ev("10.1.0.0/24"))), "--expect-prefix", "10.7.0.0/24", contains="10.7.0.0/24")

    def test_no_events_fails(self):
        self.assertFail(self.write("n.json", doc()), contains="no events")

    def test_missing_input_fails(self):
        self.assertFail(self.tmp / "nope.json", contains="input missing")

    def test_truncated_input_fails(self):
        self.assertFail(self.write("n.json", '{"window_seconds": 30, "events": [{"pre'), contains="truncated")


if __name__ == "__main__":
    unittest.main()
