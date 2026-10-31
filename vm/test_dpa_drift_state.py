"""Deterministic tests for the drift state machine in dpa-drift.py: classify_extra, classify_missing, advance_state.

Run: python3 -m unittest -v vm/test_dpa_drift_state.py
The module runs CLI code at import time, so only its definitions are loaded (same as test_dpa_drift_next_hops.py).

Eight named states: five EXPLAINED ones (reserved_owned, transient_in_flight, unsupported_or_unreadable,
next_hop_dependency, source_mismatch) that never accumulate a streak, and observed -> stale_candidate ->
confirmed_stale for the residual (stale_after + confirm_after consecutive cycles of the same classification).

ReservedOwned pins the ownership test of classify_extra (it was inverted until DRIFT-r2).
"""
import ast
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


if __name__ == "__main__":
    unittest.main()
