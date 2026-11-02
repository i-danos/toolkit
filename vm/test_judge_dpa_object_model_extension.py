import unittest
from judgetest import DATA, JudgeCase

ALL = [{"class": c, "enumerable": True} for c in ("tunnel", "acl", "qos-if", "qos-vlan")]


class T(JudgeCase):
    """A passing capture is hypothetical today: the data plane defines no tunnel or acl class, so the real one FAILs."""
    script = "judge-dpa-object-model-extension.py"

    def test_all_required_classes_enumerable_passes(self):
        self.assertPass(self.write("c.json", {"dpa_objects": {"classes": ALL, "objects": []}}))

    def test_real_capture_today_fails_because_the_classes_do_not_exist(self):
        # the real interface capture lists only the interface class
        self.assertFail(DATA / "dpa-interface-before.json", contains="not defined by the data plane")

    def test_class_defined_but_not_enumerable_fails(self):
        cls = [dict(c) for c in ALL]
        cls[1]["enumerable"] = False
        self.assertFail(self.write("c.json", {"dpa_objects": {"classes": cls, "objects": []}}), contains="not enumerable")

    def test_custom_requirement_is_honoured(self):
        self.assertPass(self.write("c.json", {"dpa_objects": {"classes": ALL, "objects": []}}), "--require", "qos-if")

    def test_missing_input_fails(self):
        self.assertFail(self.tmp / "nope.json", contains="input missing")

    def test_truncated_input_fails(self):
        self.assertFail(self.write("c.json", '{"dpa_objects": {"classes": [{"cla'), contains="truncated")

    def test_no_classes_field_fails(self):
        self.assertFail(self.write("c.json", {"dpa_objects": {}}), contains="'classes' missing")


if __name__ == "__main__":
    unittest.main()
