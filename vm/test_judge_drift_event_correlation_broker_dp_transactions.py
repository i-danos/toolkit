import unittest
from judgetest import JudgeCase


def tx(prefix="10.1.0.0/24", d=100.0, c=100.5, result="ok", completion=True):
    return {"prefix": prefix, "delivery": {"timestamp": d}, "completion": {"timestamp": c, "result": result} if completion else None}


class T(JudgeCase):
    """The product emits no completion record today; these tests pin what a passing capture would be, and that today's gap FAILs."""
    script = "judge-drift-event-correlation-broker-dp-transactions.py"

    def test_delivery_with_ok_completion_passes(self):
        self.assertPass(self.write("t.json", {"transactions": [tx(), tx("10.2.0.0/24")]}))

    def test_delivery_without_completion_fails(self):
        self.assertFail(self.write("t.json", {"transactions": [tx(completion=False)]}), contains="no completion record")

    def test_completion_with_error_result_fails(self):
        self.assertFail(self.write("t.json", {"transactions": [tx(result="error")]}), contains="result 'error'")

    def test_completion_before_delivery_fails(self):
        self.assertFail(self.write("t.json", {"transactions": [tx(d=100.0, c=99.0)]}), contains="before it was delivered")

    def test_empty_capture_which_is_what_the_product_gives_today_fails(self):
        self.assertFail(self.write("t.json", {"transactions": []}), contains="emits no completion record")

    def test_missing_input_fails(self):
        self.assertFail(self.tmp / "nope.json", contains="input missing")

    def test_truncated_input_fails(self):
        self.assertFail(self.write("t.json", '{"transactions": [{"pref'), contains="truncated")


if __name__ == "__main__":
    unittest.main()
