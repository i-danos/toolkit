import json, unittest
from judgetest import DATA, JudgeCase

SHOW = "dp0s3  10.0.2.15/24  u/u\ndp0s4  -  u/u\nlo  127.0.0.1/8  u/u\n"


class T(JudgeCase):
    """interface-class is the REAL capture of 2026-09-26 (acceptance-2608-20260926/dpa-interface/A-before.txt)."""
    script = "judge-dpa-object-model-interface-routed-ports.py"

    def args(self, obj=None, show=SHOW, ports=("dp0s3", "dp0s4")):
        f = DATA / "dpa-interface-before.json" if obj is None else self.write("o.json", obj)
        return [f, self.write("s.txt", show), *sum((["--port", p] for p in ports), [])]

    def real(self):
        return json.load(open(DATA / "dpa-interface-before.json"))

    def test_real_capture_passes(self):
        self.assertPass(*self.args())

    def test_port_missing_from_objects_fails(self):
        self.assertFail(*self.args(ports=("dp0s3", "dp0s9")), contains="dp0s9 is not enumerated")

    def test_wrong_state_fails(self):
        d = self.real()
        d["dpa_objects"]["objects"][0]["state"] = "full"
        self.assertFail(*self.args(d), contains="expected not_needed/sw-dataplane")

    def test_loopback_enumerated_fails(self):
        d = self.real()
        d["dpa_objects"]["objects"].append({"class": "interface", "key": "if:lo", "state": "not_needed", "backend": "sw-dataplane"})
        self.assertFail(*self.args(d), contains="loopback")

    def test_cli_port_without_object_fails(self):
        self.assertFail(*self.args(show=SHOW + "dp0s5  -  u/u\n"), contains="no object: dp0s5")

    def test_object_port_not_in_cli_fails(self):
        self.assertFail(*self.args(show="dp0s3  10.0.2.15/24  u/u\nlo 127.0.0.1/8 u/u\n"), contains="does not list: dp0s4")

    def test_class_not_enumerable_fails(self):
        d = self.real()
        d["dpa_objects"]["classes"][0]["enumerable"] = False
        self.assertFail(*self.args(d), contains="not enumerable")

    def test_missing_input_fails(self):
        self.assertFail(self.tmp / "nope.json", self.write("s.txt", SHOW), "--port", "dp0s3", contains="input missing")

    def test_truncated_input_fails(self):
        self.assertFail(self.write("o.json", '{"dpa_objects":{"clas'), self.write("s.txt", SHOW), "--port", "dp0s3", contains="truncated")


if __name__ == "__main__":
    unittest.main()
