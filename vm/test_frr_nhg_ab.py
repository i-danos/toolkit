"""Tests for the analysis half of frr-nhg-ab.py: group membership, when the kernel route leaves the dead member, and flow silence.

Run: python3 -m unittest -v vm/test_frr_nhg_ab.py   (synthetic guest files; nothing boots)
"""
import importlib.util
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("nhg", HERE / "frr-nhg-ab.py")
nhg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nhg)

NH_BOTH = ["id 17 via 10.0.2.2 dev dp0s9 scope link proto zebra", "id 25 via 10.0.3.2 dev dp0s10 scope link proto zebra",
           "id 143 group 17/25 proto zebra"]
S0 = 1000.0


def guest(root, rows, nh_dumps, replies=None, total=108):
    d = Path(root) / "nhg"; d.mkdir(parents=True)
    (d / "start.txt").write_text("S0=%s\nrole=r1\nfrr_pkg=10.3-3+deb13u1\n" % S0)
    (d / "route.log").write_text("".join("%s|%s|%s|%s\n" % r for r in rows))
    out = ""
    for t, lines in nh_dumps:
        out += "N|%s|nhid=x\n" % t + "".join("N|%s\n" % l for l in lines)
    (d / "nh.log").write_text(out)
    for name, ts in (replies or {}).items():
        (d / name).write_text("".join("[%.6f] 64 bytes from 10.255.2.1: icmp_seq=%d ttl=64 time=0.4 ms\n" % (t, i) for i, t in enumerate(ts)))


def steady(a, b, step=1.0):
    t, out = a, []
    while t < b:
        out.append(t); t += step
    return out


class Parse(unittest.TestCase):
    def test_a_group_resolves_to_both_interfaces(self):
        tab = nhg.parse_nh(NH_BOTH)
        self.assertEqual(nhg.devs_of_route("10.255.2.1 nhid 143 proto ospf metric 20", tab), {"dp0s9", "dp0s10"})

    def test_a_weighted_group_line_is_read(self):
        tab = nhg.parse_nh(["id 17 via 10.0.2.2 dev dp0s9 scope link", "id 25 via 10.0.3.2 dev dp0s10 scope link", "id 143 group 17,2/25,1 proto zebra"])
        self.assertEqual(nhg.devs_of_route("10.255.2.1 nhid 143 proto ospf", tab), {"dp0s9", "dp0s10"})

    def test_a_single_nexthop_resolves_to_its_interface(self):
        self.assertEqual(nhg.devs_of_route("10.255.2.1 nhid 25 proto ospf", nhg.parse_nh(NH_BOTH)), {"dp0s10"})

    def test_a_route_without_nhid_is_read_from_its_nexthop_lines(self):
        rt = "10.255.2.1 proto ospf metric 20 \n\tnexthop via 10.0.2.2 dev dp0s9 weight 1 \n\tnexthop via 10.0.3.2 dev dp0s10 weight 1"
        self.assertEqual(nhg.devs_of_route(rt, {}), {"dp0s9", "dp0s10"})

    def test_an_unknown_nhid_is_unknown_not_empty(self):
        self.assertIsNone(nhg.devs_of_route("10.255.2.1 nhid 999 proto ospf", nhg.parse_nh(NH_BOTH)))


class Kernel(unittest.TestCase):
    def view(self, rows, dumps):
        d = Path(tempfile.mkdtemp()); self.addCleanup(lambda: __import__("shutil").rmtree(d, True))
        guest(d, rows, dumps)
        return nhg.kernel_view(d, "dp0s9")

    def test_the_move_time_is_measured_from_the_carrier_loss(self):
        rows = [(S0 + 1, "up", "up", "10.255.2.1 nhid 143 proto ospf"), (S0 + 5, "dormant", "up", "10.255.2.1 nhid 143 proto ospf"),
                (S0 + 20, "dormant", "up", "10.255.2.1 nhid 143 proto ospf"), (S0 + 35.5, "dormant", "up", "10.255.2.1 nhid 25 proto ospf"),
                (S0 + 80, "up", "up", "10.255.2.1 nhid 25 proto ospf")]
        dumps = [(S0 + 0.5, NH_BOTH)]
        v = self.view(rows, dumps)
        self.assertAlmostEqual(v["t_cut"], S0 + 5); self.assertAlmostEqual(v["kernel_move_s"], 30.5, places=2); self.assertAlmostEqual(v["t_restore"], S0 + 80)

    def test_a_route_that_keeps_the_dead_member_until_the_link_returns_never_moved(self):
        rows = [(S0 + 1, "up", "up", "10.255.2.1 nhid 143 proto ospf"), (S0 + 5, "dormant", "up", "10.255.2.1 nhid 143 proto ospf"),
                (S0 + 60, "dormant", "up", "10.255.2.1 nhid 143 proto ospf"), (S0 + 80, "up", "up", "10.255.2.1 nhid 143 proto ospf")]
        v = self.view(rows, [(S0 + 0.5, NH_BOTH)])
        self.assertIsNone(v["kernel_move_s"]); self.assertAlmostEqual(v["window_s"], 75.0)

    def test_an_immediate_move_is_about_zero(self):
        rows = [(S0 + 1, "up", "up", "10.255.2.1 nhid 143 proto ospf"), (S0 + 5, "dormant", "up", "10.255.2.1 nhid 25 proto ospf"), (S0 + 80, "up", "up", "10.255.2.1 nhid 25 proto ospf")]
        v = self.view(rows, [(S0 + 0.5, NH_BOTH)])
        self.assertLess(v["kernel_move_s"], 0.01)

    def test_a_group_dump_taken_at_the_change_is_the_one_used(self):
        # nhid 143 is the two-member group at first and (after a re-number) a single member later: the dump at the time decides
        later = ["id 143 via 10.0.3.2 dev dp0s10 scope link proto zebra"]
        rows = [(S0 + 1, "up", "up", "10.255.2.1 nhid 143 proto ospf"), (S0 + 5, "dormant", "up", "10.255.2.1 nhid 143 proto ospf"), (S0 + 9, "dormant", "up", "10.255.2.1 nhid 143 proto ospf")]
        v = self.view(rows, [(S0 + 0.5, NH_BOTH), (S0 + 8, later)])
        self.assertAlmostEqual(v["kernel_move_s"], 4.0, places=2)

    def test_no_carrier_loss_is_reported_not_guessed(self):
        v = self.view([(S0 + 1, "up", "up", "x"), (S0 + 5, "up", "up", "x")], [])
        self.assertIn("error", v)


class Flows(unittest.TestCase):
    def gaps(self, replies):
        d = Path(tempfile.mkdtemp()); self.addCleanup(lambda: __import__("shutil").rmtree(d, True))
        guest(d, [], [], replies={"ping-a-b.log": replies})
        return nhg.flow_gaps(d, 5.0, 80.0, S0, 108)["ping-a-b.log"]

    def test_a_flow_that_never_stops_has_only_the_ping_interval_as_gap(self):
        self.assertAlmostEqual(self.gaps(steady(S0, S0 + 107, 0.05))["max_gap_s"], 0.05, places=2)

    def test_a_silence_after_the_cut_is_the_gap(self):
        ts = steady(S0, S0 + 5, 0.05) + steady(S0 + 35, S0 + 107, 0.05)
        self.assertAlmostEqual(self.gaps(ts)["max_gap_s"], 30.05, delta=0.1)

    def test_a_flow_that_never_answers_again_is_measured_to_the_end_of_the_log(self):
        self.assertGreater(self.gaps(steady(S0, S0 + 5, 0.05))["max_gap_s"], 90)

    def test_a_gap_after_the_restore_does_not_count_as_the_cut(self):
        ts = steady(S0, S0 + 85, 0.05) + steady(S0 + 95, S0 + 107, 0.05)
        self.assertLess(self.gaps(ts)["max_gap_s"], 1.0)

    def test_a_gap_that_starts_slightly_before_the_nominal_cut_still_counts(self):
        # another guest's script started ~1 s later than r1's, so its flow went silent at S0+4.2 while r1's offset of the cut is 5.0: the first
        # version of flow_gaps used a window starting at cut-0.5 and reported ~0.05 s for a flow that was silent for 30 s
        ts = steady(S0, S0 + 4.2, 0.05) + steady(S0 + 34.2, S0 + 107, 0.05)
        self.assertGreater(self.gaps(ts)["max_gap_s"], 29)

    def test_a_gap_starting_just_before_the_restore_is_the_restore_not_the_cut(self):
        ts = steady(S0, S0 + 79.0, 0.05) + steady(S0 + 90, S0 + 107, 0.05)
        self.assertLess(self.gaps(ts)["max_gap_s"], 1.0)

    def test_too_few_replies_is_none_not_zero(self):
        self.assertIsNone(self.gaps([S0 + 1, S0 + 2])["max_gap_s"])


class Summary(unittest.TestCase):
    def test_counts_runs_with_a_stuck_group_and_never_moved(self):
        def run(name, m1, m2):
            fl = {"F": {"a": {"max_gap_s": 0.1}}, "O1": {"a": {"max_gap_s": 20.0 if m1 is None or m1 > 5 else 0.1}}, "O2": {"a": {"max_gap_s": 0.1}}}
            return {"run": name, "flows": fl, "r1": {"kernel_move_s": m1, "window_s": 75.0}, "r2": {"kernel_move_s": m2, "window_s": 75.0}}
        s = nhg.summarise([run("r1", 0.2, 0.3), run("r2", 30.0, 0.2), run("r3", None, 0.1)])
        self.assertEqual(s["kernel_never_moved_in_window"], 1)
        self.assertEqual(s["runs_with_a_stuck_kernel_group_on_either_router"], 2)
        self.assertEqual(s["flow_O1"]["runs_with_any_flow_over_10s"], 2)


if __name__ == "__main__":
    unittest.main()
