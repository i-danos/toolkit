"""Negative tests for dpa-drift.py next-hop comparison (A05).

Run: python3 -m unittest -v test_dpa_drift_next_hops   (from this directory)
The module runs CLI code at import time, so only its definitions are loaded.
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
drift = types.ModuleType("drift_under_test")
drift.__file__ = str(_path)
exec(compile(_tree, str(_path), "exec"), drift.__dict__)

KEY = ("route6", "default", "2001:db8:10::/64")


def compare(zebra_hops, dp_hops, key=KEY):
    desired = {key: {"protocol": "static", "next_hops": zebra_hops}}
    programmed = {key: [{"owned": False, "next_hops": dp_hops}]}
    return drift.compare_next_hops(desired, programmed, {key})


def zhop(ip, ifname="dp0s4"):
    h = {"ip": ip, "fib": True}
    if ifname:
        h["interfaceName"] = ifname
    return h


def dhop(via, ifname="dp0s4", dead=False, backup=False):
    h = {"kind": "gateway", "via": via, "dead": dead, "backup": backup}
    if ifname:
        h["ifname"] = ifname
    return h


class GatewayInterfaceTest(unittest.TestCase):
    def test_same_gateway_same_interface_matches(self):
        self.assertEqual(compare([zhop("fe80::1")], [dhop("fe80::1")]), ([], 0, 0))

    def test_same_gateway_other_interface_is_mismatch(self):
        mism, nc, nr = compare([zhop("fe80::1", "dp0s4")], [dhop("fe80::1", "dp0s5")])
        self.assertEqual(len(mism), 1)
        self.assertEqual((nc, nr), (0, 0))
        self.assertEqual(mism[0]["classification"], "next_hop_mismatch")

    def test_other_gateway_same_interface_is_mismatch(self):
        mism, _, _ = compare([zhop("fe80::1")], [dhop("fe80::2")])
        self.assertEqual(len(mism), 1)

    def test_ipv4_gateway_other_interface_is_mismatch(self):
        key = ("route", "default", "10.9.0.0/24")
        mism, _, _ = compare([zhop("10.0.0.1", "dp0s4")], [dhop("10.0.0.1", "dp0s5")], key)
        self.assertEqual(len(mism), 1)

    def test_missing_interface_on_dataplane_is_not_comparable(self):
        self.assertEqual(
            compare([zhop("fe80::1")], [dhop("fe80::1", ifname=None)]), ([], 1, 0))

    def test_missing_interface_on_zebra_is_not_comparable(self):
        self.assertEqual(
            compare([zhop("fe80::1", ifname=None)], [dhop("fe80::1")]), ([], 1, 0))

    def test_ecmp_same_gateway_swapped_interfaces_is_mismatch(self):
        want = [zhop("fe80::1", "dp0s4"), zhop("fe80::1", "dp0s5")]
        have = [dhop("fe80::1", "dp0s4"), dhop("fe80::1", "dp0s4")]
        mism, _, _ = compare(want, have)
        self.assertEqual(len(mism), 1)

    def test_ecmp_same_gateway_both_interfaces_matches(self):
        want = [zhop("fe80::1", "dp0s4"), zhop("fe80::1", "dp0s5")]
        have = [dhop("fe80::1", "dp0s5"), dhop("fe80::1", "dp0s4")]
        self.assertEqual(compare(want, have), ([], 0, 0))

    def test_dead_hop_on_right_interface_does_not_count_as_live(self):
        mism, _, _ = compare([zhop("fe80::1")], [dhop("fe80::1", dead=True)])
        self.assertEqual(len(mism), 1)

    def test_address_spelling_is_still_normalized(self):
        self.assertEqual(
            compare([zhop("2001:0db8::1")], [dhop("2001:db8::1")]), ([], 0, 0))


class BackupDeadTest(unittest.TestCase):
    def test_live_primary_with_standby_backup_matches(self):
        have = [dhop("fe80::1", "dp0s4"), dhop("fe80::2", "dp0s5", backup=True)]
        self.assertEqual(compare([zhop("fe80::1", "dp0s4")], have), ([], 0, 0))

    def test_live_primary_wrong_with_backup_present_is_mismatch(self):
        have = [dhop("fe80::9", "dp0s4"), dhop("fe80::1", "dp0s4", backup=True)]
        mism, nc, _ = compare([zhop("fe80::1", "dp0s4")], have)
        self.assertEqual((len(mism), nc), (1, 0))
        self.assertEqual(mism[0]["programmed_backup_next_hops"], ["via fe80::1 dp0s4"])

    def test_backup_only_path_is_not_equal_to_zebra_primary(self):
        # the backup carries exactly zebra's gateway; still not a match
        have = [dhop("fe80::1", "dp0s4", backup=True)]
        self.assertEqual(compare([zhop("fe80::1", "dp0s4")], have), ([], 1, 0))

    def test_dead_primary_with_live_backup_is_not_comparable(self):
        have = [dhop("fe80::1", "dp0s4", dead=True), dhop("fe80::2", "dp0s5", backup=True)]
        self.assertEqual(compare([zhop("fe80::1", "dp0s4")], have), ([], 1, 0))

    def test_dead_primary_with_dead_backup_is_mismatch(self):
        have = [dhop("fe80::1", "dp0s4", dead=True),
                dhop("fe80::2", "dp0s5", dead=True, backup=True)]
        mism, nc, _ = compare([zhop("fe80::1", "dp0s4")], have)
        self.assertEqual((len(mism), nc), (1, 0))

    def test_dead_primary_only_is_mismatch(self):
        mism, nc, _ = compare([zhop("fe80::1")], [dhop("fe80::1", dead=True)])
        self.assertEqual((len(mism), nc), (1, 0))

    def test_ecmp_one_primary_dead_is_mismatch(self):
        want = [zhop("fe80::1", "dp0s4"), zhop("fe80::2", "dp0s5")]
        have = [dhop("fe80::1", "dp0s4"), dhop("fe80::2", "dp0s5", dead=True)]
        mism, _, _ = compare(want, have)
        self.assertEqual(len(mism), 1)
        self.assertEqual(mism[0]["programmed_dead_next_hops"], ["via fe80::2 dp0s5"])

    def test_zebra_hop_with_backup_is_not_comparable(self):
        z = zhop("fe80::1", "dp0s4")
        z["backupIndex"] = [0]
        self.assertEqual(compare([z], [dhop("fe80::1", "dp0s4")]), ([], 1, 0))

    def test_opaque_backup_hop_is_not_comparable(self):
        have = [dhop("fe80::1", "dp0s4"), {"kind": "local", "backup": True, "dead": False}]
        self.assertEqual(compare([zhop("fe80::1", "dp0s4")], have), ([], 1, 0))

    def test_ipv4_backup_only_and_interface_error_cases(self):
        key = ("route", "default", "10.9.0.0/24")
        self.assertEqual(
            compare([zhop("10.0.0.1")], [dhop("10.0.0.1", backup=True)], key), ([], 1, 0))
        mism, _, _ = compare([zhop("10.0.0.1", "dp0s4")],
                             [dhop("10.0.0.1", "dp0s5")], key)
        self.assertEqual(len(mism), 1)


class EdgeShapeTest(unittest.TestCase):
    """Odd-but-possible report shapes: each must end as match, mismatch or an
    explicit not_comparable -- never a silent equal."""

    def test_non_dataplane_gateway_without_interface_is_not_comparable(self):
        have = [{"kind": "non-dataplane interface", "via": "10.0.0.1", "dead": False}]
        self.assertEqual(compare([zhop("10.0.0.1", "mgmt0")], have,
                                 ("route", "default", "10.9.0.0/24")), ([], 1, 0))

    def test_non_dataplane_connected_route_is_not_comparable(self):
        have = [{"kind": "non-dataplane interface", "ifname": "mgmt0", "dead": False}]
        z = [{"directlyConnected": True, "interfaceName": "mgmt0", "fib": True}]
        self.assertEqual(compare(z, have, ("route", "default", "10.8.0.0/24")), ([], 1, 0))

    def test_empty_interface_names_are_not_comparable(self):
        self.assertEqual(compare([zhop("fe80::1", "")], [dhop("fe80::1")]), ([], 1, 0))
        self.assertEqual(compare([zhop("fe80::1")], [dhop("fe80::1", "")]), ([], 1, 0))

    def test_missing_dead_and_backup_keys_mean_live_primary(self):
        have = [{"kind": "gateway", "via": "fe80::1", "ifname": "dp0s4"}]
        self.assertEqual(compare([zhop("fe80::1")], have), ([], 0, 0))

    def test_null_backup_flag_is_primary(self):
        have = [dict(dhop("fe80::1"), backup=None)]
        self.assertEqual(compare([zhop("fe80::1")], have), ([], 0, 0))

    def test_empty_backup_index_list_means_unprotected(self):
        z = zhop("fe80::1")
        z["backupIndex"] = []
        self.assertEqual(compare([z], [dhop("fe80::1")]), ([], 0, 0))

    def test_uppercase_and_expanded_ipv6_spelling_still_match_per_interface(self):
        self.assertEqual(compare([zhop("FE80:0:0:0:0:0:0:1")], [dhop("fe80::1")]), ([], 0, 0))
        mism, _, _ = compare([zhop("FE80:0:0:0:0:0:0:1", "dp0s4")], [dhop("fe80::1", "dp0s5")])
        self.assertEqual(len(mism), 1)

    def test_blackhole_backup_only_is_not_equal_to_blackhole_primary(self):
        z = [{"blackhole": True, "unreachable": True, "fib": True}]
        have = [{"kind": "blackhole", "dead": False, "backup": True}]
        self.assertEqual(compare(z, have), ([], 1, 0))

    def test_blackhole_primary_matches_and_wrong_kind_mismatches(self):
        z = [{"blackhole": True, "unreachable": True, "fib": True}]
        self.assertEqual(compare(z, [{"kind": "blackhole", "dead": False}]), ([], 0, 0))
        mism, _, _ = compare(z, [{"kind": "unreachable", "dead": False}])
        self.assertEqual(len(mism), 1)

    def test_two_dataplane_entries_are_not_comparable(self):
        desired = {KEY: {"protocol": "static", "next_hops": [zhop("fe80::1")]}}
        programmed = {KEY: [{"owned": False, "next_hops": [dhop("fe80::1")]},
                            {"owned": False, "next_hops": [dhop("fe80::1", "dp0s5")]}]}
        self.assertEqual(drift.compare_next_hops(desired, programmed, {KEY}), ([], 1, 0))

    def test_unreported_next_hops_are_counted_not_compared(self):
        desired = {KEY: {"protocol": "static", "next_hops": [zhop("fe80::1")]}}
        programmed = {KEY: [{"owned": False, "next_hops": None}]}
        self.assertEqual(drift.compare_next_hops(desired, programmed, {KEY}), ([], 0, 1))

    def test_dataplane_owned_entry_is_skipped(self):
        desired = {KEY: {"protocol": "static", "next_hops": [zhop("fe80::1")]}}
        programmed = {KEY: [{"owned": True, "next_hops": [dhop("fe80::9")]}]}
        self.assertEqual(drift.compare_next_hops(desired, programmed, {KEY}), ([], 1, 0))

    def test_non_route_classes_are_ignored(self):
        k = ("mroute", "default", "(1.1.1.1,232.1.1.1)")
        self.assertEqual(drift.compare_next_hops({k: {}}, {k: []}, {k}), ([], 0, 0))


class MalformedReportTest(unittest.TestCase):
    """A producer that reports an unexpected shape must be counted as not
    comparable. It must neither crash the whole drift run nor be read with
    the wrong meaning (a string "false" is not a false flag)."""

    Z = [{"ip": "fe80::1", "interfaceName": "a", "fib": True}]
    D = {"kind": "gateway", "via": "fe80::1", "ifname": "a"}

    def nc(self, z, d):
        self.assertEqual(compare(z, d), ([], 1, 0), (z, d))

    def test_dataplane_hop_list_shapes(self):
        for bad in ({"x": 1}, ["x"], [None], [5], "gateway"):
            self.nc(self.Z, bad)

    def test_zebra_hop_list_shapes(self):
        for bad in (None, ["x"], [None], {"ip": "fe80::1"}):
            self.nc(bad, [self.D])

    def test_string_flags_are_not_booleans(self):
        for key in ("dead", "backup"):
            for val in ("false", "true", "0", 1, 0):
                self.nc(self.Z, [dict(self.D, **{key: val})])

    def test_null_flags_mean_unset(self):
        self.assertEqual(compare(self.Z, [dict(self.D, dead=None, backup=None)]), ([], 0, 0))

    def test_non_string_or_invalid_address_or_interface(self):
        for over in ({"via": 5}, {"via": "not-an-ip"}, {"ifname": 7}, {"via": ["fe80::1"]}):
            self.nc(self.Z, [dict(self.D, **over)])
        for over in ({"ip": "not-an-ip"}, {"interfaceName": 7}, {"ip": 5}):
            self.nc([dict(self.Z[0], **over)], [self.D])

    def test_invalid_address_on_both_sides_is_not_an_equal_match(self):
        self.nc([{"ip": "garbage", "interfaceName": "a"}], [dict(self.D, via="garbage")])

    def test_dead_flag_only_on_real_true(self):
        mism, nc, _ = compare(self.Z, [dict(self.D, dead=True)])
        self.assertEqual((len(mism), nc), (1, 0))


class MultiVrfTest(unittest.TestCase):
    def test_same_prefix_in_two_vrfs_is_judged_independently(self):
        k1 = ("route6", "RED", "2001:db8:10::/64")
        k2 = ("route6", "BLUE", "2001:db8:10::/64")
        desired = {k1: {"protocol": "static", "next_hops": [zhop("fe80::1", "dp0s4")]},
                   k2: {"protocol": "static", "next_hops": [zhop("fe80::1", "dp0s4")]}}
        programmed = {
            k1: [{"owned": False, "next_hops": [dhop("fe80::1", "dp0s4")]}],
            k2: [{"owned": False, "next_hops": [dhop("fe80::1", "dp0s5")]}]}
        mism, nc, nr = drift.compare_next_hops(desired, programmed, {k1, k2})
        self.assertEqual([(m["vrf"], m["prefix"]) for m in mism],
                         [("BLUE", "2001:db8:10::/64")])
        self.assertEqual((nc, nr), (0, 0))

    def test_vrf_keys_do_not_leak_between_vrfs(self):
        # zebra's route in RED, data plane's only entry sits under BLUE: no match
        k1 = ("route", "RED", "10.1.0.0/24")
        k2 = ("route", "BLUE", "10.1.0.0/24")
        desired = {k1: {"protocol": "static", "next_hops": [zhop("10.0.0.1")]}}
        programmed = {k2: [{"owned": False, "next_hops": [dhop("10.0.0.1")]}]}
        self.assertEqual(drift.compare_next_hops(desired, programmed, {k1} & set(programmed)),
                         ([], 0, 0))


if __name__ == "__main__":
    unittest.main()
