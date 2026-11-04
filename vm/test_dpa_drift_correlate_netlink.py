"""Tests for dpa-drift-correlate-netlink.py: the verb it reports must be the dataplane's own name for it ("RTM_NEWROUTE" /
"RTM_DELROUTE"), as its docstring and judge-drift-event-correlation-netlink.py say, and an event without a netlink counterpart
must say why.

Run: python3 -m unittest -v vm/test_dpa_drift_correlate_netlink.py
The journal is replaced by canned `journalctl -o json` lines; nothing here touches a router.
"""
import importlib.util
import json
import subprocess
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("correlate_netlink", HERE / "dpa-drift-correlate-netlink.py")
cn = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cn)

T0 = 1_793_000_000  # seconds


def journal(*rows):
    """canned `journalctl -u vyatta-dataplane -o json` output: (seconds, message) -> one JSON object per line"""
    return "\n".join(json.dumps({"MESSAGE": m, "__REALTIME_TIMESTAMP": str(int(t * 1_000_000))}) for t, m in rows) + "\n"


def with_journal(text):
    done = subprocess.CompletedProcess(cn.JOURNAL, 0, stdout=text, stderr="")
    return mock.patch.object(cn.subprocess, "run", return_value=done)


NEW = "ROUTE: RTM_NEWROUTE table 254 type multicast dst 10.94.1.0/24 gw 0.0.0.0 dev 0 scope 0 proto 196"
DEL = "ROUTE: RTM_DELROUTE table 254 type unicast dst 10.94.2.0/24 gw 10.0.2.2 dev 3 scope 0 proto 196"


class T(unittest.TestCase):
    def test_parsed_verb_keeps_the_rtm_prefix(self):
        with with_journal(journal((T0, NEW), (T0 + 1, DEL))):
            got = cn.netlink_route_events()
        self.assertEqual([g[1] for g in got], ["RTM_NEWROUTE", "RTM_DELROUTE"])
        self.assertEqual([g[3] for g in got], ["10.94.1.0/24", "10.94.2.0/24"])

    def test_a_line_that_is_not_a_route_message_is_ignored(self):
        with with_journal(journal((T0, "ROUTE: something else"), (T0, "unrelated"), (T0, NEW))):
            self.assertEqual(len(cn.netlink_route_events()), 1)

    def test_correlated_event_reports_a_verb_the_judge_accepts(self):
        ev = {"events": [{"prefix": "10.94.1.0/24", "first_timestamp": "2026-11-03T22:25:30+00:00"}]}
        # put the netlink line a few seconds before the event
        t_ev = __import__("datetime").datetime.fromisoformat("2026-11-03T22:25:30+00:00").timestamp()
        with with_journal(journal((t_ev - 4, NEW))):
            out = cn.correlate(ev, 120)
        n = out[0]["correlated_netlink_route"]
        self.assertEqual(n["verb"], "RTM_NEWROUTE")
        self.assertEqual(n["gap_seconds"], 4.0)
        self.assertIn(n["verb"], {"RTM_NEWROUTE", "RTM_DELROUTE"})

    def test_event_without_a_netlink_counterpart_says_why(self):
        t_ev = __import__("datetime").datetime.fromisoformat("2026-11-03T22:25:30+00:00").timestamp()
        ev = {"events": [{"prefix": "172.16.0.0/12", "first_timestamp": "2026-11-03T22:25:30+00:00"}]}
        with with_journal(journal((t_ev - 4, NEW))):
            out = cn.correlate(ev, 120)
        self.assertIsNone(out[0]["correlated_netlink_route"])
        self.assertTrue(out[0]["netlink_correlation_note"].strip())
        self.assertIn("172.16.0.0/12", out[0]["netlink_correlation_note"])

    def test_empty_journal_says_debug_may_be_off(self):
        ev = {"events": [{"prefix": "10.94.1.0/24", "first_timestamp": "2026-11-03T22:25:30+00:00"}]}
        with with_journal(journal()):
            out = cn.correlate(ev, 120)
        self.assertIsNone(out[0]["correlated_netlink_route"])
        self.assertIn("nl_route", out[0]["netlink_correlation_note"])


if __name__ == "__main__":
    unittest.main()
