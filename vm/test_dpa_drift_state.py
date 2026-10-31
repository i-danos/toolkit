"""Deterministic tests for the drift state machine in dpa-drift.py: classify_extra, classify_missing, advance_state.

Run: python3 -m unittest -v vm/test_dpa_drift_state.py
The module runs CLI code at import time, so only its definitions are loaded (same as test_dpa_drift_next_hops.py).

Eight named states: five EXPLAINED ones (reserved_owned, transient_in_flight, unsupported_or_unreadable,
next_hop_dependency, source_mismatch) that never accumulate a streak, and observed -> stale_candidate ->
confirmed_stale for the residual (stale_after + confirm_after consecutive cycles of the same classification).

ReservedOwned pins the ownership test of classify_extra (it was inverted until DRIFT-r2).
"""
import ast
import contextlib
import io
import json
import re
import subprocess
import sys
import types
import unittest
from pathlib import Path

_path = Path(__file__).with_name("dpa-drift.py")
_tree = ast.parse(_path.read_text())
_cli = next(i for i, n in enumerate(_tree.body)
            if isinstance(n, ast.If) and "--watch" in ast.unparse(n.test))
_tree.body = _tree.body[:_cli]
drift = types.ModuleType("drift_state_under_test")
drift.__file__ = str(_path)
exec(compile(_tree, str(_path), "exec"), drift.__dict__)

KEY = ("route", "default", "198.51.100.0/24")
EXPLAINED = ["reserved_owned", "transient_in_flight", "unsupported_or_unreadable",
             "next_hop_dependency", "source_mismatch"]


def entry(state="FULL", owned=None, deps=None):
    return {"state": state, "owned": owned, "dependencies": deps or []}


def extra(*entries, key=KEY):
    return {key: list(entries)}, key


def chain(classification, n, stale_after=3, confirm_after=3, prior=None):
    """The tracking dicts for n consecutive cycles of the same classification."""
    out = []
    for _ in range(n):
        prior = drift.advance_state(prior, classification, stale_after, confirm_after)
        out.append(prior)
    return out


class ClassifyMissing(unittest.TestCase):
    def test_a_class_that_is_not_enumerable_is_unsupported_or_unreadable(self):
        cov = {"enumerable": ["route"]}
        self.assertEqual(drift.classify_missing("route6", cov), "unsupported_or_unreadable")

    def test_an_enumerable_class_starts_as_observed(self):
        cov = {"enumerable": ["route", "route6"]}
        self.assertEqual(drift.classify_missing("route6", cov), "observed")

    def test_without_coverage_information_it_is_observed_not_unsupported(self):
        self.assertEqual(drift.classify_missing("route", None), "observed")
        self.assertEqual(drift.classify_missing("route", {}), "observed")

    def test_there_is_no_programmed_state_to_read_a_reason_from(self):
        # the only reasons it can give are the two above; nothing else is ever returned
        for klass in ("route", "route6", "mpls-route", "mroute", "mroute6"):
            for cov in (None, {"enumerable": []}, {"enumerable": [klass]}):
                self.assertIn(drift.classify_missing(klass, cov), ("observed", "unsupported_or_unreadable"))


class ClassifyExtra(unittest.TestCase):
    """The branches after the ownership test, reached with owned unknown (None), as an image that cannot
    report ownership produces."""

    def test_partial_and_not_needed_are_transient_in_flight(self):
        for state in ("PARTIAL", "NOT_NEEDED", "partial", "not_needed"):
            p, k = extra(entry(state))
            self.assertEqual(drift.classify_extra(p, k, None), "transient_in_flight", state)

    def test_no_resource_and_no_support_are_unsupported_or_unreadable_in_either_case(self):
        # route's DPA state comes back upper case, route6's lower case (measured live): both must land here
        for state in ("NO_RESOURCE", "NO_SUPPORT", "no_resource", "no_support"):
            p, k = extra(entry(state), key=("route6", "default", "2001:db8::/32"))
            self.assertEqual(drift.classify_extra(p, k, None), "unsupported_or_unreadable", state)

    def test_dependencies_make_it_next_hop_dependency(self):
        p, k = extra(entry("FULL", deps=["nexthop-group inet/idx:7"]))
        self.assertEqual(drift.classify_extra(p, k, None), "next_hop_dependency")

    def test_nothing_else_to_say_is_source_mismatch(self):
        p, k = extra(entry("FULL"))
        self.assertEqual(drift.classify_extra(p, k, None), "source_mismatch")

    def test_a_missing_or_null_state_is_not_an_error(self):
        for state in (None, ""):
            p, k = extra(entry(state))
            self.assertEqual(drift.classify_extra(p, k, None), "source_mismatch", repr(state))

    def test_the_state_wins_over_dependencies(self):
        p, k = extra(entry("PARTIAL", deps=["x"]))
        self.assertEqual(drift.classify_extra(p, k, None), "transient_in_flight")
        p, k = extra(entry("NO_SUPPORT", deps=["x"]))
        self.assertEqual(drift.classify_extra(p, k, None), "unsupported_or_unreadable")

    def test_every_result_is_a_member_of_the_explained_set(self):
        for st in ("FULL", "PARTIAL", "NOT_NEEDED", "NO_RESOURCE", "NO_SUPPORT", None):
            for deps in ([], ["d"]):
                p, k = extra(entry(st, deps=deps))
                self.assertIn(drift.classify_extra(p, k, None), EXPLAINED)


class ReservedOwned(unittest.TestCase):
    """reserved_owned is for entries the data plane owns (owned is True), not for entries known NOT to be owned.

    classify_extra() used to begin with `if unowned(p, k): return "reserved_owned"`. unowned() is True for
    entries known not to be owned, and watch() / main() pass on exactly those keys, so every real
    programmed-not-desired object was labelled reserved_owned and the state checks after it could not be
    reached from watch(). (It was found writing this file; the extra direction had never been induced live.)
    """

    def test_an_entry_the_data_plane_owns_is_reserved_owned(self):
        for state in ("FULL", "PARTIAL", "NO_SUPPORT", None):
            p, k = extra(entry(state, owned=True))
            self.assertEqual(drift.classify_extra(p, k, None), "reserved_owned", state)

    def test_an_entry_known_not_to_be_owned_is_not_reserved_owned(self):
        # the only kind of key watch() hands to classify_extra: it is classified by what it is
        want = {"FULL": "source_mismatch", "PARTIAL": "transient_in_flight", "NOT_NEEDED": "transient_in_flight",
                "NO_SUPPORT": "unsupported_or_unreadable", "no_support": "unsupported_or_unreadable"}
        for state, cls in want.items():
            p, k = extra(entry(state, owned=False))
            self.assertEqual(drift.classify_extra(p, k, None), cls, state)
        p, k = extra(entry("FULL", owned=False, deps=["nexthop-group inet/idx:7"]))
        self.assertEqual(drift.classify_extra(p, k, None), "next_hop_dependency")

    def test_one_input_both_ways(self):
        k_owned, k_real = ("route", "default", "127.0.0.0/8"), ("route", "default", "198.51.100.0/24")
        p = {k_owned: [entry("FULL", owned=True)], k_real: [entry("FULL", owned=False)]}
        self.assertEqual(drift.classify_extra(p, k_owned, None), "reserved_owned")
        self.assertNotEqual(drift.classify_extra(p, k_real, None), "reserved_owned")

    def test_a_key_is_reserved_only_if_every_entry_under_it_is(self):
        # 0.0.0.0/0 carries a reserved entry and a real one at different scopes: the real one must not hide
        p, k = extra(entry("FULL", owned=True), entry("FULL", owned=False))
        self.assertNotEqual(drift.classify_extra(p, k, None), "reserved_owned")
        p, k = extra(entry("FULL", owned=True), entry("FULL", owned=None))
        self.assertNotEqual(drift.classify_extra(p, k, None), "reserved_owned")
        p, k = extra(entry("FULL", owned=True), entry("PARTIAL", owned=True))
        self.assertEqual(drift.classify_extra(p, k, None), "reserved_owned")

    def test_what_watch_feeds_it_never_comes_back_reserved_owned(self):
        # watch(): extra = keys programmed but not desired, with unowned(p, k); owned keys never get here
        p = {("route", "default", "127.0.0.0/8"): [entry("FULL", owned=True)],
             ("route", "default", "198.51.100.0/24"): [entry("FULL", owned=False)],
             ("route6", "default", "2001:db8::/32"): [entry("no_support", owned=False)],
             ("route", "default", "203.0.113.0/24"): [entry("FULL", owned=None)]}
        fed = [k for k in p if drift.unowned(p, k)]
        self.assertEqual(len(fed), 2)                                    # unknown ownership is not drift
        self.assertEqual([drift.classify_extra(p, k, None) for k in fed],
                         ["source_mismatch", "unsupported_or_unreadable"])


class AdvanceState(unittest.TestCase):
    def states(self, classification, n, **kw):
        return [(s["state"], s["streak"]) for s in chain(classification, n, **kw)]

    def test_default_thresholds_three_and_three(self):
        want = [("observed", 1), ("observed", 2), ("stale_candidate", 3), ("stale_candidate", 4),
                ("stale_candidate", 5), ("confirmed_stale", 6), ("confirmed_stale", 7),
                ("confirmed_stale", 8)]
        self.assertEqual(self.states("observed", 8), want)

    def test_the_boundaries_are_exactly_three_and_six(self):
        s = chain("observed", 8)
        self.assertEqual(s[1]["state"], "observed")          # 2: a machine that promoted at 2 fails here
        self.assertEqual(s[2]["state"], "stale_candidate")   # 3
        self.assertEqual(s[4]["state"], "stale_candidate")   # 5: one that confirmed at 5 fails here
        self.assertEqual(s[5]["state"], "confirmed_stale")   # 6

    def test_other_thresholds(self):
        self.assertEqual(self.states("observed", 5, stale_after=1, confirm_after=1),
                         [("stale_candidate", 1), ("confirmed_stale", 2), ("confirmed_stale", 3),
                          ("confirmed_stale", 4), ("confirmed_stale", 5)])
        self.assertEqual(self.states("observed", 8, stale_after=2, confirm_after=4),
                         [("observed", 1), ("stale_candidate", 2), ("stale_candidate", 3),
                          ("stale_candidate", 4), ("stale_candidate", 5), ("confirmed_stale", 6),
                          ("confirmed_stale", 7), ("confirmed_stale", 8)])
        self.assertEqual(self.states("observed", 6, stale_after=4, confirm_after=0),
                         [("observed", 1), ("observed", 2), ("observed", 3), ("confirmed_stale", 4),
                          ("confirmed_stale", 5), ("confirmed_stale", 6)])

    def test_the_thresholds_are_not_hard_coded_to_the_defaults(self):
        a = [s["state"] for s in chain("observed", 6, 3, 3)]
        b = [s["state"] for s in chain("observed", 6, 2, 2)]
        self.assertNotEqual(a, b)

    def test_a_change_of_classification_restarts_the_streak_at_one(self):
        s = chain("observed", 5)
        self.assertEqual(s[-1]["state"], "stale_candidate")
        nxt = drift.advance_state(s[-1], "next_hop_mismatch", 3, 3)
        self.assertEqual((nxt["state"], nxt["streak"]), ("observed", 1))
        again = drift.advance_state(nxt, "next_hop_mismatch", 3, 3)
        self.assertEqual(again["streak"], 2)

    def test_a_first_sighting_is_streak_one(self):
        s = drift.advance_state(None, "observed", 3, 3)
        self.assertEqual((s["classification"], s["state"], s["streak"]), ("observed", "observed", 1))

    def test_every_explained_classification_is_reported_as_itself_with_streak_zero(self):
        for c in EXPLAINED:
            for n, s in enumerate(chain(c, 8), 1):
                self.assertEqual((s["state"], s["classification"], s["streak"]), (c, c, 0), (c, n))

    def test_an_explained_classification_never_reaches_stale_whatever_the_thresholds(self):
        for c in EXPLAINED:
            for sa, ca in ((1, 0), (1, 1), (3, 3), (2, 6)):
                self.assertEqual({s["state"] for s in chain(c, 10, sa, ca)}, {c}, (c, sa, ca))

    def test_explained_after_a_long_unexplained_run_drops_the_streak(self):
        long_run = chain("observed", 7)[-1]
        self.assertEqual(long_run["state"], "confirmed_stale")
        s = drift.advance_state(long_run, "transient_in_flight", 3, 3)
        self.assertEqual((s["state"], s["streak"]), ("transient_in_flight", 0))

    def test_unexplained_after_an_explained_run_starts_from_one(self):
        e = chain("next_hop_dependency", 5)[-1]
        s = drift.advance_state(e, "observed", 3, 3)
        self.assertEqual((s["state"], s["streak"]), ("observed", 1))

    def test_a_next_hop_mismatch_counts_a_streak_like_any_residual(self):
        s = chain("next_hop_mismatch", 6)
        self.assertEqual([x["state"] for x in s],
                         ["observed", "observed", "stale_candidate", "stale_candidate",
                          "stale_candidate", "confirmed_stale"])

    def test_the_prior_dict_is_not_mutated(self):
        prior = {"classification": "observed", "state": "observed", "streak": 2}
        before = dict(prior)
        drift.advance_state(prior, "observed", 3, 3)
        self.assertEqual(prior, before)


class TheEightNamedStates(unittest.TestCase):
    def test_the_explained_set_is_exactly_the_five_names(self):
        self.assertEqual(drift.EXPLAINED, set(EXPLAINED))

    def test_eight_states_are_reachable_and_only_eight(self):
        seen = set()
        for c in EXPLAINED:
            seen |= {s["state"] for s in chain(c, 2)}
        seen |= {s["state"] for s in chain("observed", 8)}
        self.assertEqual(seen, set(EXPLAINED) | {"observed", "stale_candidate", "confirmed_stale"})
        self.assertEqual(len(seen), 8)



# ---- what the data plane does not hold by design (DRIFT-r3) ----------------------------------------------
#
# First real run of cases/drift-state-machine.yaml on a settled box reported two disagreements:
#   missing  route6 fe80::/64   (zebra: protocol connected, interface ens31 = the management NIC)
#   extra    route6 fe80::5054:ff:fe01:1f01/128   (that NIC's own link-local address)
# Neither is drift. vyatta-dataplane src/ip_netlink.c handle_route6() returns before adding any route whose
# destination is the unspecified link-local prefix (IN6_IS_ADDR_UNSPEC_LINKLOCAL, src/netinet6/route_v6.h:31),
# on every interface; and it builds RTN_LOCAL host routes itself (RTF_LOCAL, next hop kind "local",
# src/dpa_object.c dpa_nh_kind) for every address the box has, which zebra's RIB does not list as installed.

VPLSH = drift.VPLSH_CMDS
VTYSH = drift.VTYSH_CMDS


def zebra_route(proto="connected", ifname="ens31", vrf="default"):
    return [{"selected": True, "installed": True, "protocol": proto, "vrfName": vrf, "table": 254,
             "nexthops": [{"fib": True, "interfaceName": ifname, "directlyConnected": True}]}]


def dp_obj(klass, key, state, hops, owned=False):
    return {"class": klass, "key": key, "state": state, "backend": "sw-dataplane", "dataplane_owned": owned,
            "nh_index": 1, "next_hops": hops}


def objects(klass, objs):
    return {"dpa_objects": {"classes": [], "objects": objs}}


LOCAL = [{"kind": "local", "dead": False, "backup": False}]
MGMT_HOP = [{"kind": "non-dataplane interface", "dead": False, "backup": False}]
LINK = "vrf:default/table:254/fe80::5054:ff:fe01:1f01/128/scope:0"


def settled_box(local_hops=LOCAL, extra_desired=None):
    """The answers of a settled R1 as the first real run saw them: the management NIC's IPv4 connected route
    (programmed as a non-dataplane-interface route), its fe80::/64 (never programmed), its link-local /128 (a local
    host route in the data plane only), and an unrelated static IPv6 route that matches."""
    zebra = {
        tuple(VTYSH["route"]): {"10.0.2.0/24": zebra_route()},
        tuple(VTYSH["route6"]): {"fe80::/64": zebra_route(), "2001:db8:1::/64": zebra_route("static", "dp0s4")},
        tuple(VTYSH["mpls-route"]): {}, tuple(VTYSH["mroute"]): {}, tuple(VTYSH["mroute6"]): {},
    }
    if extra_desired:
        zebra[tuple(VTYSH["route6"])].update(extra_desired)
    dp = {
        tuple(VPLSH["route"]): objects("route", [dp_obj("route", "vrf:default/table:254/10.0.2.0/24/scope:0",
                                                         "NO_SUPPORT", MGMT_HOP)]),
        tuple(VPLSH["route6"]): objects("route6", [
            dp_obj("route6", "vrf:default/table:254/2001:db8:1::/64/scope:0", "no_support",
                   [{"kind": "directly connected", "ifname": "dp0s4", "dead": False, "backup": False}]),
            dp_obj("route6", "vrf:default/table:254/::1/128/scope:0", "no_support", LOCAL, owned=True),
            dp_obj("route6", LINK, "no_support", local_hops)]),
        tuple(VPLSH["mpls-route"]): objects("mpls-route", []), tuple(VPLSH["mroute"]): objects("mroute", []),
        tuple(VPLSH["mroute6"]): objects("mroute6", []),
        tuple(drift.VPLSH_CLASSES): {"dpa_objects": {"classes": [
            {"class": c, "enumerable": True} for c in ("route", "route6", "mpls-route", "mroute", "mroute6")],
            "objects": []}},
    }
    return {**zebra, **dp}


class Box:
    """Run dpa-drift's own main() / watch() against canned vtysh and vplsh answers."""

    def __init__(self, answers):
        self.answers = answers

    def __enter__(self):
        self.saved = (drift.run, drift.time)
        drift.run = lambda cmd: self.answers.get(tuple(cmd))
        drift.time = types.SimpleNamespace(sleep=lambda s: None)
        return self

    def __exit__(self, *a):
        drift.run, drift.time = self.saved

    def snapshot(self):
        buf, old = io.StringIO(), sys.argv
        sys.argv = ["dpa-drift.py", "--json"]
        try:
            with contextlib.redirect_stdout(buf):
                rc = drift.main()
        finally:
            sys.argv = old
        return rc, json.loads(buf.getvalue())

    def watch_text(self, cycles):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            drift.watch(0, cycles, False)
        return buf.getvalue()

    def watch_json(self, cycles):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            drift.watch(0, cycles, True)
        return [json.loads(l) for l in buf.getvalue().splitlines() if l.startswith("{")]


class NeverProgrammed(unittest.TestCase):
    def test_the_link_local_prefix_is_never_programmed_on_any_interface(self):
        for pfx in ("fe80::/64", "fe80::/10", "fe80::/128", "FE80::/64", "febf::/64"):
            self.assertIn("link-local", drift.never_programmed("route6", pfx) or "", pfx)

    def test_link_local_addresses_and_other_prefixes_are_not_excluded(self):
        for pfx in ("fe80::5054:ff:fe01:1f01/128", "fe80::1/128", "fe80::1:0:0:0/64", "fec0::/64",
                    "2001:db8::/32", "::/0", "ff02::/16", "not-an-address/64"):
            self.assertIsNone(drift.never_programmed("route6", pfx), pfx)

    def test_only_route6_is_affected(self):
        for klass in ("route", "mpls-route", "mroute", "mroute6"):
            self.assertIsNone(drift.never_programmed(klass, "fe80::/64"), klass)

    def test_it_mirrors_the_dataplane_macro(self):
        # IN6_IS_ADDR_UNSPEC_LINKLOCAL: (a[0] & 0xffc00000) == 0xfe800000 and a[1] == a[2] == a[3] == 0
        import ipaddress
        for text in ("fe80::", "fe81::", "febf:ffff::", "fec0::", "fe80::1", "fe80:0:0:1::", "fe7f::", "::"):
            a = ipaddress.IPv6Address(text).packed
            word = lambda i: int.from_bytes(a[4 * i:4 * i + 4], "big")
            macro = (word(0) & 0xffc00000) == 0xfe800000 and word(1) == word(2) == word(3) == 0
            self.assertEqual(bool(drift.never_programmed("route6", text + "/64")), macro, text)


class KernelLocal(unittest.TestCase):
    def p(self, *hop_lists):
        return {KEY: [{"owned": False, "next_hops": h} for h in hop_lists]}

    def test_an_entry_whose_only_hop_is_local(self):
        self.assertTrue(drift.kernel_local(self.p(LOCAL), KEY))
        self.assertTrue(drift.kernel_local(self.p(LOCAL, LOCAL), KEY))

    def test_anything_else_is_an_ordinary_entry(self):
        gw = [{"kind": "gateway", "via": "10.0.0.1", "ifname": "dp0s4"}]
        for hops in (None, [], gw, MGMT_HOP, LOCAL + gw, [{"kind": "blackhole"}], ["local"]):
            self.assertFalse(drift.kernel_local(self.p(hops), KEY), repr(hops))
        self.assertFalse(drift.kernel_local(self.p(LOCAL, gw), KEY))      # one real entry under the key is enough


class SettledBox(unittest.TestCase):
    """The same answers the first real run got, through dpa-drift's real main() and watch()."""

    def test_the_two_false_differences_are_gone_and_reported_on_their_own_lines(self):
        with Box(settled_box()) as b:
            rc, r = b.snapshot()
        self.assertEqual(rc, 0, r)
        self.assertEqual((r["desired_not_programmed"], r["programmed_not_desired"]), ([], []))
        self.assertEqual([x["prefix"] for x in r["kernel_local"]], ["fe80::5054:ff:fe01:1f01/128"])
        self.assertEqual([x["prefix"] for x in r["not_programmable"]], ["fe80::/64"])
        self.assertIn("link-local", r["not_programmable"][0]["reason"])

    def test_the_management_nics_ipv4_connected_route_is_still_compared(self):
        # no interface-name filter: the data plane programs it (kind "non-dataplane interface") and it matches
        with Box(settled_box()) as b:
            rc, r = b.snapshot()
        self.assertEqual(r["desired"], 2)                      # 10.0.2.0/24 and 2001:db8:1::/64; fe80::/64 left out
        self.assertEqual(r["matched"], 2)

    def test_watch_sees_zero_disagreements_on_every_cycle(self):
        with Box(settled_box()) as b:
            cycles = b.watch_json(3)
        self.assertEqual(len(cycles), 3)
        for c in cycles:
            self.assertEqual(c["disagreements"], [], c)
        with Box(settled_box()) as b:
            self.assertIn("disagreements 0", b.watch_text(3).splitlines()[-1])

    def test_a_mgmt_nic_route_the_data_plane_does_not_hold_is_still_drift(self):
        # not excluded by interface name: an ordinary IPv4 connected route zebra installed and the data plane lacks
        box = settled_box()
        box[tuple(VPLSH["route"])] = objects("route", [])
        with Box(box) as b:
            rc, r = b.snapshot()
        self.assertEqual(rc, 1)
        self.assertEqual([x["prefix"] for x in r["desired_not_programmed"]], ["10.0.2.0/24"])

    def test_a_non_local_extra_is_still_drift(self):
        gw = [{"kind": "gateway", "via": "fe80::1", "ifname": "dp0s4", "dead": False, "backup": False}]
        for hops in (gw, None):                                # a real next hop; an image that reports none
            with Box(settled_box(local_hops=hops)) as b:
                rc, r = b.snapshot()
            self.assertEqual(rc, 1, hops)
            self.assertEqual([x["prefix"] for x in r["programmed_not_desired"]], ["fe80::5054:ff:fe01:1f01/128"], hops)
            self.assertEqual(r["kernel_local"], [], hops)

    def test_a_link_local_address_route_zebra_does_list_is_compared_normally(self):
        # fe80::x/128 is not the prefix the data plane ignores
        host = {"fe80::5054:ff:fe01:1f01/128": zebra_route("local", "ens31")}
        with Box(settled_box(extra_desired=host)) as b:
            rc, r = b.snapshot()
        self.assertEqual(rc, 0, r)
        self.assertEqual(r["matched"], 3)
        self.assertEqual(r["kernel_local"], [])


if __name__ == "__main__":
    unittest.main()
