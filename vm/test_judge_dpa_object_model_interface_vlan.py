import unittest
from judgetest import DATA, JudgeCase

SHOW = "Interface  IP Address  State\ndp0s3      10.0.2.15/24  u/u\ndp0s4      -  u/u\ndp0s4.100  192.0.2.1/24  u/u\n"


class T(JudgeCase):
    """before/after-config/after-restart are the REAL captures of 2026-09-26 (acceptance-2608-20260926/dpa-interface/)."""
    script = "judge-dpa-object-model-interface-vlan.py"

    def args(self, before="before", config="after-config", restart="after-restart", show=SHOW, vid="100"):
        f = lambda n: DATA / ("dpa-interface-%s.json" % n)
        return [f(before), f(config), f(restart), self.write("show.txt", show), "--parent", "dp0s4", "--vid", vid]

    def test_real_captures_pass(self):
        self.assertPass(*self.args())

    def test_subinterface_gone_after_restart_fails(self):
        self.assertFail(*self.args(restart="before"), contains="disappeared after the data plane restarted")

    def test_subinterface_never_enumerated_fails(self):
        self.assertFail(*self.args(config="before", restart="before"), contains="is not enumerated")

    def test_subinterface_already_present_before_fails(self):
        self.assertFail(*self.args(before="after-config"), contains="already enumerated")

    def test_other_vid_fails(self):
        self.assertFail(*self.args(vid="200", show=SHOW.replace(".100", ".200")), contains="is not enumerated")

    def test_cli_does_not_list_it_fails(self):
        self.assertFail(*self.args(show="dp0s3\ndp0s4\n"), contains="not listed in `show interfaces`")

    def test_cli_listing_a_longer_name_is_not_a_match(self):
        self.assertFail(*self.args(show="dp0s4.1000\n"), contains="not listed")

    def test_state_changed_across_restart_fails(self):
        import json
        d = json.load(open(DATA / "dpa-interface-after-restart.json"))
        for o in d["dpa_objects"]["objects"]:
            if o["key"] == "if:dp0s4.100":
                o["state"] = "error"
        self.assertFail(DATA / "dpa-interface-before.json", DATA / "dpa-interface-after-config.json", self.write("r.json", d), self.write("s.txt", SHOW), "--parent", "dp0s4", "--vid", "100", contains="changed across the restart")

    def test_missing_input_fails(self):
        self.assertFail(self.tmp / "nope.json", DATA / "dpa-interface-after-config.json", DATA / "dpa-interface-after-restart.json", self.write("s.txt", SHOW), "--parent", "dp0s4", "--vid", "100", contains="input missing")

    def test_truncated_input_fails(self):
        self.assertFail(self.write("b.json", '{"dpa_objects":{"classes":[{"cl'), DATA / "dpa-interface-after-config.json", DATA / "dpa-interface-after-restart.json", self.write("s.txt", SHOW), "--parent", "dp0s4", "--vid", "100", contains="truncated")


if __name__ == "__main__":
    unittest.main()
