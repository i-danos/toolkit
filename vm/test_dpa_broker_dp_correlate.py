"""Tests for dpa-broker-dp-correlate.py: the completion record it derives from `dpa object show route` snapshots, what it says about
its own uncertainty, and that its output is what judge-drift-event-correlation-broker-dp-transactions.py accepts or refuses.

Run: python3 -m unittest -v vm/test_dpa_broker_dp_correlate.py   (synthetic input only; nothing touches a router)
"""
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("bdc", HERE / "dpa-broker-dp-correlate.py")
bdc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bdc)
JUDGE = HERE / "judge-drift-event-correlation-broker-dp-transactions.py"

T = 1000.0  # seconds; the delivery of the first test prefix is logged at T


def route(prefix, state="no_support", backend="sw-dataplane", table=254, scope=0):
    ip, depth = prefix.split("/")
    return {"class": "route", "key": "vrf:default/table:%d/%s/%s/scope:%d" % (table, ip, depth, scope), "state": state, "backend": backend}


def nl(prefix, ts, verb="RTM_NEWROUTE", table=254):
    msg = "ROUTE: %s table %d type multicast dst %s gw 0.0.0.0 dev 0 scope 0 proto 196" % (verb, table, prefix)
    return json.dumps({"MESSAGE": msg, "__REALTIME_TIMESTAMP": str(int(ts * 1e6)), "_PID": "7"})


class Cap:
    """a capture directory: snapshots as (start, end, [route objects], rc)"""
    def __init__(self, tc, deliveries, snaps):
        self.d = Path(tempfile.mkdtemp()); tc.addCleanup(lambda: __import__("shutil").rmtree(self.d, True))
        (self.d / "nl.jsonl").write_text("\n".join(deliveries) + "\n")
        rows = []
        for n, (s, e, objs, rc) in enumerate(snaps):
            rows.append("%d %.9f %.9f %d" % (n, s, e, rc))
            if objs is not None:
                (self.d / ("snap-%d.json" % n)).write_text(json.dumps({"dpa_objects": {"classes": [], "objects": objs}}))
        (self.d / "snaps.log").write_text("\n".join(rows) + "\n")

    def run(self, *extra):
        out = self.d / "tx.json"
        r = subprocess.run([sys.executable, str(HERE / "dpa-broker-dp-correlate.py"), "--nl", str(self.d / "nl.jsonl"), "--snaps", str(self.d),
                            "--out", str(out), *extra], capture_output=True, text=True)
        assert r.returncode == 0, r.stderr
        return json.loads(out.read_text()), out

    def judge(self, out):
        r = subprocess.run([sys.executable, str(JUDGE), str(out)], capture_output=True, text=True)
        return r.returncode, (r.stdout + r.stderr).strip()


P = "10.95.1.0/24"


class T_(unittest.TestCase):
    def normal(self, **kw):
        # two snapshots without the route, then the third (ending at T+0.030) lists it
        snaps = [(T - 0.040, T - 0.030, [], 0), (T - 0.010, T + 0.000, [], 0), (T + 0.010, T + 0.030, [route(P, **kw)], 0)]
        return Cap(self, [nl(P, T + 0.005)], snaps)

    def test_completion_is_the_end_of_the_first_snapshot_that_lists_the_route(self):
        doc, out = self.normal().run()
        t = doc["transactions"][0]
        self.assertEqual(t["prefix"], P)
        self.assertAlmostEqual(t["delivery"]["timestamp"], T + 0.005, places=6)
        c = t["completion"]
        self.assertAlmostEqual(c["timestamp"], T + 0.030, places=6)
        self.assertEqual((c["state"], c["backend"], c["result"], c["snapshot"]), ("no_support", "sw-dataplane", "ok", "snap-2.json"))
        self.assertAlmostEqual(c["last_absent_end"], T + 0.000, places=6)
        self.assertAlmostEqual(c["uncertainty_seconds"], 0.030, places=6)

    def test_judge_passes_a_normal_capture(self):
        cap = self.normal(); _, out = cap.run()
        rc, text = cap.judge(out)
        self.assertEqual(rc, 0, text)

    def test_a_delivered_route_that_is_never_listed_has_no_completion_and_the_judge_refuses(self):
        cap = Cap(self, [nl(P, T)], [(T - 0.02, T - 0.01, [], 0), (T + 0.01, T + 0.02, [], 0)])
        doc, out = cap.run()
        self.assertIsNone(doc["transactions"][0]["completion"])
        self.assertIn("never seen installed", doc["transactions"][0]["note"])
        rc, text = cap.judge(out)
        self.assertEqual(rc, 1); self.assertIn("no completion record", text)

    def test_a_route_listed_before_it_was_delivered_completes_before_the_delivery_and_the_judge_refuses(self):
        cap = Cap(self, [nl(P, T)], [(T - 0.05, T - 0.04, [route(P)], 0), (T + 0.01, T + 0.02, [route(P)], 0)])
        doc, out = cap.run()
        self.assertLess(doc["transactions"][0]["completion"]["timestamp"], doc["transactions"][0]["delivery"]["timestamp"])
        rc, text = cap.judge(out)
        self.assertEqual(rc, 1); self.assertIn("before it was delivered", text)

    def test_an_error_state_is_not_ok(self):
        cap = self.normal(state="error"); doc, out = cap.run()
        self.assertEqual(doc["transactions"][0]["completion"]["result"], "error")
        rc, text = cap.judge(out)
        self.assertEqual(rc, 1); self.assertIn("result 'error'", text)

    def test_the_ok_states_are_the_callers_to_set_and_full_only_refuses_no_support(self):
        cap = self.normal(); doc, out = cap.run("--ok-states", "full")
        self.assertEqual(doc["transactions"][0]["completion"]["result"], "no_support")
        self.assertEqual(cap.judge(out)[0], 1)
        doc, out = cap.run("--ok-states", "full,no_support")
        self.assertEqual(doc["transactions"][0]["completion"]["result"], "ok")

    def test_a_longer_or_shorter_prefix_is_not_the_same_route(self):
        snaps = [(T - 0.02, T - 0.01, [], 0), (T + 0.01, T + 0.02, [route("10.95.1.0/25"), route("10.95.11.0/24"), route("10.95.1.0/24", scope=253)], 0)]
        doc, _ = Cap(self, [nl(P, T)], snaps).run()
        self.assertIsNone(doc["transactions"][0]["completion"])

    def test_a_snapshot_that_failed_is_skipped_and_counted_not_read_as_absent_or_present(self):
        snaps = [(T - 0.03, T - 0.02, [], 0), (T - 0.02, T - 0.01, None, 1), (T + 0.01, T + 0.02, None, 0), (T + 0.03, T + 0.04, [route(P)], 0)]
        cap = Cap(self, [nl(P, T)], snaps); doc, _ = cap.run()
        self.assertEqual(doc["method"]["snapshots_used"], 2)
        self.assertEqual(len(doc["method"]["snapshots_skipped"]), 2)
        c = doc["transactions"][0]["completion"]
        self.assertAlmostEqual(c["timestamp"], T + 0.04, places=6)
        self.assertAlmostEqual(c["last_absent_end"], T - 0.02, places=6)   # the failed snapshots are not evidence of absence

    def test_deliveries_in_one_snapshot_share_its_window_and_are_kept_apart_by_prefix(self):
        a, b = "10.95.1.0/24", "10.95.2.0/24"
        snaps = [(T - 0.02, T - 0.01, [], 0), (T + 0.01, T + 0.02, [route(a), route(b)], 0)]
        doc, out = Cap(self, [nl(a, T), nl(b, T + 0.0004)], snaps).run()
        self.assertEqual([t["prefix"] for t in doc["transactions"]], [a, b])
        self.assertEqual({t["completion"]["snapshot"] for t in doc["transactions"]}, {"snap-1.json"})

    def test_a_delivery_from_an_earlier_run_is_not_matched_with_this_runs_installation(self):
        # the same prefix was delivered 164 s before the capture began; this run installs it later. Matching them would be a false pairing.
        snaps = [(T - 0.02, T - 0.01, [], 0), (T + 0.01, T + 0.02, [route(P)], 0)]
        cap = Cap(self, [nl(P, T - 164.0), nl(P, T)], snaps)
        doc, out = cap.run()
        self.assertEqual(len(doc["transactions"]), 1)
        self.assertAlmostEqual(doc["transactions"][0]["delivery"]["timestamp"], T, places=6)
        ig = [i for i in doc["method"]["ignored_deliveries"] if "why" in i]
        self.assertEqual(len(ig), 1); self.assertIn("outside the capture window", ig[0]["why"])
        self.assertEqual(cap.judge(out)[0], 0)

    def test_only_old_lines_leave_nothing_to_judge(self):
        cap = Cap(self, [nl(P, T - 164.0)], [(T - 0.02, T - 0.01, [], 0), (T + 0.01, T + 0.02, [route(P)], 0)])
        doc, out = cap.run()
        self.assertEqual(doc["transactions"], [])
        self.assertEqual(cap.judge(out)[0], 1)

    def test_a_delivery_with_no_earlier_snapshot_gets_no_completion(self):
        # the only snapshot starts before the delivery but ends after it: nothing shows the route was absent first
        cap = Cap(self, [nl(P, T)], [(T - 0.01, T + 0.02, [route(P)], 0)])
        doc, out = cap.run()
        self.assertIsNone(doc["transactions"][0]["completion"])
        self.assertIn("nothing shows the route was absent first", doc["transactions"][0]["note"])
        self.assertEqual(cap.judge(out)[0], 1)

    def test_a_delete_delivery_is_listed_as_ignored_not_turned_into_a_transaction(self):
        cap = Cap(self, [nl(P, T, verb="RTM_DELROUTE")], [(T + 0.01, T + 0.02, [], 0)])
        doc, out = cap.run()
        self.assertEqual(doc["transactions"], [])
        self.assertEqual(doc["method"]["ignored_deliveries"][0]["verb"], "RTM_DELROUTE")
        self.assertEqual(cap.judge(out)[0], 1)   # nothing to judge is not a pass


if __name__ == "__main__":
    unittest.main()
