import json, unittest
from judgetest import DATA, JudgeCase, drift

ZEBRA = {"2001:db8:91::/64": [{"selected": True, "installed": True, "protocol": "static"}],
         "2001:db8:92::/64": [{"selected": True, "installed": True, "protocol": "static"}]}


class T(JudgeCase):
    script = "judge-comparison-scope-route6.py"

    def args(self, d=None, z=None, *prefixes):
        return [self.write("d.json", d if d is not None else drift()), self.write("z.json", z if z is not None else ZEBRA),
                *sum((["--prefix", p] for p in (prefixes or ["2001:db8:91::/64"])), [])]

    def test_agreeing_sides_with_witness_pass(self):
        self.assertPass(*self.args(None, None, "2001:db8:91::/64", "2001:db8:92::/64"))

    def test_real_capture_from_an_older_build_that_did_not_compare_route6_fails(self):
        self.assertFail(DATA / "dpa-drift-real-r2.json", self.write("z.json", ZEBRA), "--prefix", "2001:db8:91::/64", contains="route6 is not in coverage.compared")

    def test_missing_route6_entry_fails(self):
        self.assertFail(*self.args(drift(missing=[("route6", "2001:db8:91::/64")])), contains="route6 disagreement")

    def test_next_hop_mismatch_fails(self):
        self.assertFail(*self.args(drift(nh_mismatch=[("route6", "2001:db8:92::/64")])), contains="route6 disagreement")

    def test_ipv4_disagreement_does_not_fail_this_item(self):
        self.assertPass(*self.args(drift(missing=[("route", "10.9.0.0/24")])))

    def test_witness_not_installed_in_zebra_fails(self):
        self.assertFail(*self.args(None, {}, "2001:db8:91::/64"), contains="not selected+installed")

    def test_keyspace_mismatch_fails(self):
        self.assertFail(*self.args(drift(keyspace=True)), contains="keyspace_mismatch")

    def test_unreadable_status_fails(self):
        self.assertFail(*self.args(drift(status="unreadable")), contains="not 'diagnostic'")

    def test_missing_input_fails(self):
        self.assertFail(self.tmp / "nope.json", self.write("z.json", ZEBRA), "--prefix", "x", contains="input missing")

    def test_truncated_input_fails(self):
        s = json.dumps(drift())
        self.assertFail(self.write("d.json", s[: len(s) // 2]), self.write("z.json", ZEBRA), "--prefix", "x", contains="truncated")

    def test_no_witness_prefix_is_refused(self):
        self.assertFail(self.write("d.json", drift()), self.write("z.json", ZEBRA), contains="usage")


if __name__ == "__main__":
    unittest.main()
