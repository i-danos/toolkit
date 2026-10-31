"""Tests for the version fingerprint of accept-lifecycle.sh (no VM): fp, fp_diff, fp_judge.

The script cannot be sourced (it checks ISOs and starts a VM at the top), so the three functions are cut out of it
and run in bash, with a gssh that runs its argument locally and a fake dpkg-query.

Run: python3 -m unittest -v vm/test_accept_lifecycle.py
"""
import os
import re
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = (Path(__file__).with_name("accept-lifecycle.sh")).read_text()
FUNCS = "\n".join(re.search(r"^%s\(\) \{.*?^\}" % n, SCRIPT, re.M | re.S).group(0) for n in ("fp", "fp_diff", "fp_judge"))

FAKE_DPKG = r"""#!/bin/bash
# dpkg-query -W -f=FORMAT : one line per row of $FAKE_PKGS ("name version"), the format's \n turned into a newline
fmt=${2#-f=}
while read -r n v; do
	line=${fmt//\$\{Package\}/$n}; line=${line//\$\{Version\}/$v}
	printf '%b' "$line"
done < "$FAKE_PKGS"
"""

# test3 (configd 2.12.2danos9) and test4 (2.12.2danos10): the two images of the first real cross-version run
COMMON = """libc6 2.41-12
vyatta-image-tools 5.57
acmd 1.9danos9
vyatta-vrrp 3.8
vci-kdump 0.3danos5
openssh-server 1:10.0p1-7
"""
TEST3 = COMMON + "configd 2.12.2danos9\nconfig-utils 2.12.2danos9\n"
TEST4 = COMMON.replace("acmd 1.9danos9", "acmd 1.9danos10").replace("vyatta-vrrp 3.8", "vyatta-vrrp 3.8+danos1") + \
    "configd 2.12.2danos10\nconfig-utils 2.12.2danos10\n"


def sh(script, pkgs=None, **env):
    with tempfile.TemporaryDirectory() as d:
        bin_ = Path(d, "bin")
        bin_.mkdir()
        p = bin_ / "dpkg-query"
        p.write_text(FAKE_DPKG)
        p.chmod(p.stat().st_mode | stat.S_IXUSR)
        (Path(d) / "pkgs").write_text(pkgs or "")
        e = dict(PATH=f"{bin_}:/usr/bin:/bin", FAKE_PKGS=str(Path(d) / "pkgs"), **env)
        prelude = 'gssh() { echo "Welcome to DANOS"; bash -c "$1"; }\n' + FUNCS + "\n"
        r = subprocess.run(["bash", "-c", prelude + script], capture_output=True, text=True, env=e)
        return r.returncode, r.stdout.strip(), r.stderr


class Fingerprint(unittest.TestCase):
    def fp(self, pkgs):
        return sh("fp", pkgs)[1]

    def test_it_keeps_image_tools_and_every_danos_versioned_package_and_nothing_else(self):
        self.assertEqual(self.fp(TEST3).splitlines(), [
            "acmd 1.9danos9", "config-utils 2.12.2danos9", "configd 2.12.2danos9",
            "vci-kdump 0.3danos5", "vyatta-image-tools 5.57"])

    def test_banner_lines_from_the_login_shell_are_ignored(self):
        self.assertNotIn("Welcome", self.fp(TEST3))

    def test_a_version_with_a_plus_danos_suffix_counts(self):
        self.assertIn("vyatta-vrrp 3.8+danos1", self.fp(TEST4))

    def test_image_tools_alone_is_never_enough_to_be_empty(self):
        self.assertEqual(self.fp("vyatta-image-tools 5.57\nlibc6 2.41\n"), "vyatta-image-tools 5.57")


class Judge(unittest.TestCase):
    def judge(self, old, new):
        rc, out, err = sh('F0=$(printf "%s" "$OLD" | sort); F1=$(printf "%s" "$NEW" | sort); fp_judge "$F0" "$F1"; echo "rc=$?"',
                          OLD=old, NEW=new)
        self.assertEqual(err, "")
        text, _, rc = out.rpartition("rc=")
        return int(rc), text.strip()

    def fp_of(self, pkgs):
        return sh("fp", pkgs)[1]

    def test_the_first_real_cross_version_run_test3_to_test4(self):
        # vyatta-image-tools is 5.57 in both; configd, config-utils, acmd (danos9 -> danos10) and vrrp (3.8 -> 3.8+danos1) differ
        old, new = self.fp_of(TEST3), self.fp_of(TEST4)
        rc, text = self.judge(old, new)
        self.assertEqual(rc, 0, text)
        self.assertEqual(text, "acmd 1.9danos9 -> 1.9danos10; config-utils 2.12.2danos9 -> 2.12.2danos10; "
                               "configd 2.12.2danos9 -> 2.12.2danos10 (+1 more)")
        self.assertNotIn("5.57 -> 5.57", text)
        diff = sh('fp_diff "$OLD" "$NEW"', OLD=old, NEW=new)[1].splitlines()
        self.assertEqual(diff, ["acmd 1.9danos9 -> 1.9danos10", "config-utils 2.12.2danos9 -> 2.12.2danos10",
                                "configd 2.12.2danos9 -> 2.12.2danos10", "vyatta-vrrp (not in the set) -> 3.8+danos1"])

    def test_a_configd_bump_is_the_readable_example(self):
        new = TEST3.replace("configd 2.12.2danos9", "configd 2.12.2danos10")        # nothing else changes
        rc, text = self.judge(self.fp_of(TEST3), self.fp_of(new))
        self.assertEqual((rc, text), (0, "configd 2.12.2danos9 -> 2.12.2danos10"))

    def test_identical_images_fail_and_say_what_was_compared(self):
        rc, text = self.judge(self.fp_of(TEST3), self.fp_of(TEST3))
        self.assertEqual(rc, 1)
        self.assertIn("no version differs among the 5 compared packages", text)
        self.assertIn("configd 2.12.2danos9", text)
        self.assertIn("vyatta-image-tools 5.57", text)

    def test_image_tools_alone_the_old_witness_cannot_tell_these_apart_but_this_can(self):
        old, new = self.fp_of(TEST3), self.fp_of(TEST4)
        tools = lambda s: [l for l in s.splitlines() if l.startswith("vyatta-image-tools")]
        self.assertEqual(tools(old), tools(new))                 # the failing witness of the real run
        self.assertEqual(self.judge(old, new)[0], 0)

    def test_a_package_on_one_side_only_counts(self):
        old = self.fp_of(COMMON)
        new = self.fp_of(COMMON + "libnew 1.0danos1\n")
        rc, text = self.judge(old, new)
        self.assertEqual((rc, text), (0, "libnew (not in the set) -> 1.0danos1"))

    def test_more_than_three_differences_are_summarised(self):
        old = "a 1danos1\nb 1danos1\nc 1danos1\nd 1danos1\ne 1danos1\nvyatta-image-tools 5.57"
        new = "a 1danos2\nb 1danos2\nc 1danos2\nd 1danos2\ne 1danos2\nvyatta-image-tools 5.57"
        rc, text = self.judge(old, new)
        self.assertEqual(rc, 0)
        self.assertTrue(text.endswith("(+2 more)"), text)

    def test_an_unreadable_side_fails_with_a_reason_instead_of_an_arrow(self):
        for old, new, who in (("", "x 1danos1", "old"), ("x 1danos1", "", "new")):
            rc, text = self.judge(old, new)
            self.assertEqual(rc, 1)
            self.assertIn(f"the {who} image's package versions could not be read", text)

    def test_the_four_check_names_are_unchanged(self):
        for name in ("the new image runs a different version", "the new image runs the same version as the old",
                     "the new image runs the new version", "the new image does not run the expected version"):
            self.assertIn(f'"{name}"', SCRIPT)

    def test_expect_upg_ver_keeps_comparing_image_tools_alone(self):
        self.assertIn('[ "$V1" = "$EXPECT_UPG_VER" ]', SCRIPT)
        self.assertIn('[ "$V0" = "$EXPECT_BASE_VER" ]', SCRIPT)


if __name__ == "__main__":
    unittest.main()
