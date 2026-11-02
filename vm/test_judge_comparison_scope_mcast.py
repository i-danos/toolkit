import json, unittest
from judgetest import JudgeCase, drift

LOG = """===== 5. SSM counters after sending =====
    10.1.1.2 -> 232.1.1.1  packets=5000 bytes=420000 wrong_if=0 punted=1
===== 9. R1 sends 5000 packets =====
===== 10. IPv6 counters after sending =====
--- R2 fcstat6 ---
{"fcstat6": [{"packets": 5000, "bytes": 500000}]}

===== Done =====
"""
CLS = ("route", "mroute", "mroute6")


class T(JudgeCase):
    script = "judge-comparison-scope-mcast.py"

    def args(self, d=None, log=LOG):
        return [self.write("d.json", d if d is not None else drift(CLS)), self.write("l.log", log)]

    def test_agreeing_sides_and_forwarding_pass(self):
        self.assertPass(*self.args())

    def test_missing_mroute_entry_fails(self):
        self.assertFail(*self.args(drift(CLS, missing=[("mroute", "10.1.1.2,232.1.1.1")])), contains="multicast disagreement")

    def test_only_one_of_the_two_classes_compared_fails(self):
        self.assertFail(*self.args(drift(("route", "mroute"))), contains="mroute6 is not in coverage.compared")

    def test_wrong_interface_traffic_fails(self):
        self.assertFail(*self.args(log=LOG.replace("wrong_if=0", "wrong_if=12")), contains="wrong_if = 0")

    def test_ipv6_section_without_packets_fails(self):
        self.assertFail(*self.args(log=LOG.replace('"packets": 5000', '"packets": 0')), contains="IPv6 forwarding")

    def test_log_cut_short_fails(self):
        self.assertFail(*self.args(log=LOG.split("===== 9.")[0]), contains="cut short")

    def test_empty_log_fails(self):
        self.assertFail(*self.args(log="  \n"), contains="input empty")

    def test_truncated_drift_fails(self):
        s = json.dumps(drift(CLS))
        self.assertFail(self.write("d.json", s[:40]), self.write("l.log", LOG), contains="truncated")


if __name__ == "__main__":
    unittest.main()
