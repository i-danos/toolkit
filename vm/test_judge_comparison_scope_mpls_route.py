import json, unittest
from judgetest import JudgeCase, drift

LOG = """===== 5. Wait for BGP to converge =====
R1 label 144 for 3.3.3.3/32
===== 6. Forwarding: ping PE2's VRF from PE1's VRF =====
5 packets transmitted, 5 received, 0% packet loss, time 4005ms

===== Done =====
"""


class T(JudgeCase):
    script = "judge-comparison-scope-mpls-route.py"

    def args(self, d=None, log=LOG, label="144"):
        return [self.write("d.json", d if d is not None else drift(("route", "mpls-route"))), self.write("l.log", log), "--label", label]

    def test_agreeing_sides_labels_and_full_ping_pass(self):
        self.assertPass(*self.args())

    def test_mpls_label_missing_on_the_programmed_side_fails(self):
        self.assertFail(*self.args(drift(("route", "mpls-route"), missing=[("mpls-route", "144")])), contains="mpls-route disagreement")

    def test_class_not_compared_fails(self):
        self.assertFail(*self.args(drift(("route",))), contains="mpls-route is not in coverage.compared")

    def test_partial_ping_loss_fails(self):
        self.assertFail(*self.args(log=LOG.replace("5 received", "3 received")), contains="forwarding step")

    def test_label_not_in_log_fails(self):
        self.assertFail(*self.args(label="777"), contains="label 777")

    def test_log_cut_short_fails(self):
        self.assertFail(*self.args(log=LOG.replace("===== Done =====", "")), contains="cut short")

    def test_missing_log_fails(self):
        self.assertFail(self.write("d.json", drift(("mpls-route",))), self.tmp / "nope.log", "--label", "144", contains="input missing")

    def test_truncated_drift_json_fails(self):
        s = json.dumps(drift(("mpls-route",)))
        self.assertFail(self.write("d.json", s[:60]), self.write("l.log", LOG), "--label", "144", contains="truncated")


if __name__ == "__main__":
    unittest.main()
