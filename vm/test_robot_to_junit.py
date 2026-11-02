import importlib.util, subprocess, sys, tempfile, unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location("r2j", Path(__file__).with_name("robot-to-junit.py"))
r2j = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(r2j)

TABLE = 'x\nSUITES="\nipsec ipsec IPSEC_VPN_DANOS  2\nfw    fw    FIREWALL_DANOS   1\n"\n'


def output_xml(tests, nested=False, teardown_failed=False, stat=None):
    t = "".join('<test name="%s"><status status="%s">%s</status></test>' % (n, s, m) for n, s, m in tests)
    inner = '<suite name="Sub">%s</suite>' % t if nested else t
    if stat is None:
        fails = len(tests) if teardown_failed else sum(1 for _, s, _ in tests if s != "PASS")
        stat = (len(tests) - fails, fails)
    suite_status = '<status status="FAIL">Suite teardown failed:\nboom</status>' if teardown_failed else ""
    return ('<robot><suite name="Top">%s%s</suite><statistics><total><stat pass="%d" fail="%d" skip="0">All Tests</stat></total></statistics></robot>'
            % (inner, suite_status, stat[0], stat[1]))


class T(unittest.TestCase):
    def test_suites_table_is_read_from_the_script(self):
        self.assertEqual(r2j.read_suites(TABLE), [("ipsec", "ipsec", "IPSEC_VPN_DANOS", 2), ("fw", "fw", "FIREWALL_DANOS", 1)])

    def test_missing_table_is_refused(self):
        with self.assertRaises(ValueError):
            r2j.read_suites("nothing here")

    def test_output_xml_tests_and_statuses(self):
        d = Path(tempfile.mkdtemp())
        (d / "o.xml").write_text(output_xml([("a", "PASS", ""), ("b", "FAIL", "boom")]))
        self.assertEqual([(n, s) for n, s, _ in r2j.robot_tests(d / "o.xml")], [("a", "PASS"), ("b", "FAIL")])

    def test_nested_suites_are_walked(self):
        d = Path(tempfile.mkdtemp())
        (d / "o.xml").write_text(output_xml([("a", "PASS", "")], nested=True))
        self.assertEqual(len(r2j.robot_tests(d / "o.xml")), 1)

    def test_not_a_robot_file_is_refused(self):
        d = Path(tempfile.mkdtemp())
        (d / "o.xml").write_text("<html/>")
        with self.assertRaises(ValueError):
            r2j.robot_tests(d / "o.xml")

    def test_truncated_xml_is_refused(self):
        import xml.etree.ElementTree as ET
        d = Path(tempfile.mkdtemp())
        (d / "o.xml").write_text("<robot><suite name='x'><test")
        with self.assertRaises(ET.ParseError):
            r2j.robot_tests(d / "o.xml")


    def test_a_pass_under_a_failed_suite_teardown_is_reported_as_failed(self):
        d = Path(tempfile.mkdtemp())
        (d / "o.xml").write_text(output_xml([("a", "PASS", ""), ("b", "FAIL", "x")], teardown_failed=True))
        got = r2j.robot_tests(d / "o.xml")
        self.assertEqual([s for _, s, _ in got], ["FAIL", "FAIL"])
        self.assertIn("suite teardown failed", got[0][2])

    def test_counts_that_disagree_with_robots_statistics_are_refused(self):
        d = Path(tempfile.mkdtemp())
        (d / "o.xml").write_text(output_xml([("a", "PASS", ""), ("b", "PASS", "")], stat=(1, 1)))
        with self.assertRaises(ValueError):
            r2j.robot_tests(d / "o.xml")

    def test_output_without_statistics_is_refused(self):
        d = Path(tempfile.mkdtemp())
        (d / "o.xml").write_text('<robot><suite name="Top"><test name="a"><status status="PASS"/></test></suite></robot>')
        with self.assertRaises(ValueError):
            r2j.robot_tests(d / "o.xml")


if __name__ == "__main__":
    unittest.main()
