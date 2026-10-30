"""Tests for the two host-side drift cases: cases/drift-state-machine.yaml and cases/dpa-object-model.yaml.

Neither needs a VM here. The topology is replaced by a fake `docker` on PATH and, for the drift case, a fake
verify-drift-watch.sh whose check names are READ FROM THE REAL SCRIPT, so a renamed check in the script breaks
these tests instead of silently breaking the suite-config contract.

Run: python3 -m unittest -v vm/test_drift_cases.py
"""
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).resolve().parent
TOOL = HERE / "verify-case.py"
CASES = HERE / "cases"

# handoff/verify/suite-config.json, items.drift_state_machine.required_cases (copied: the contract being pinned)
DRIFT_REQUIRED = [
    "drift_state_machine.three-cycles-on-a-settled-box-no-disagreement",
    "drift_state_machine.the-count-rises-across-cycles",
    "drift_state_machine.the-drift-is-still-there-after-watching",
    "drift_state_machine.the-count-went-back-to-zero",
]


def slug(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def script_names(kind):
    """The first argument of every ok / bad call in verify-drift-watch.sh, in order of appearance."""
    text = (HERE / "verify-drift-watch.sh").read_text()
    out = []
    for m in re.finditer(r'^\s*%s "([^"]*)"' % kind, text, re.M):
        if m.group(1) not in out:
            out.append(m.group(1))
    return out


def junit(path):
    return {tc.get("classname") + "." + tc.get("name"): ("FAIL" if tc.find("failure") is not None else
                                                          "SKIP" if tc.find("skipped") is not None else "PASS")
            for tc in ET.parse(path).getroot().iter("testcase")}


def write_exe(path, text):
    Path(path).write_text(text)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)


class Host:
    """A temp dir with a fake docker on PATH, run through verify-case.py --exec local."""

    def __init__(self, case, fake_docker, extra_files=None):
        self.td = tempfile.TemporaryDirectory()
        self.d = Path(self.td.name)
        (self.d / "bin").mkdir()
        write_exe(self.d / "bin" / "docker", fake_docker)
        self.case = CASES / case
        (self.d / "vm").mkdir()
        os.symlink(HERE / "fixture-log-to-result.py", self.d / "vm" / "fixture-log-to-result.py")
        for name, text in (extra_files or {}).items():
            write_exe(self.d / "vm" / name, text)

    def run(self, **env):
        e = dict(os.environ, PATH=f"{self.d / 'bin'}:{os.environ['PATH']}", **env)
        j = self.d / "j.xml"
        p = subprocess.run([sys.executable, str(TOOL), str(self.case), "--exec", "local", "--junit", str(j),
                            "--var", f"vm_dir={self.d / 'vm'}", "--var", f"log={self.d / 'log'}",
                            "--allow-dirty"], capture_output=True, text=True, env=e, timeout=300)
        return p, (junit(j) if j.exists() else {})

    def close(self):
        self.td.cleanup()


FAKE_DOCKER_DRIFT = "#!/bin/bash\ncase \"${@: -1}\" in *R1_UP*) echo R1_UP;; esac\nexit 0\n"


def fake_watch_script(mode_env="FAKE_MODE"):
    names = script_names("ok")
    lines = ['#!/bin/bash', 'OUT=${OUT:?}', f'MODE=${{{mode_env}:-pass}}', 'exec > "$OUT" 2>&1',
             'echo "===== 0. Install ====="']
    body = []
    for i, n in enumerate(names):
        body += [f'echo "===== {i + 1}. check ====="', 'echo "    cycle 1  desired 3  disagreements 0"',
                 f'if [ "$MODE" = "fail{i}" ]; then printf \'  FAIL  %s\\n\' "{n}"; printf \'        %s\\n\' "detail"; f=$((f+1)); '
                 f'else printf \'  PASS  %s\\n\' "{n}"; printf \'        %s\\n\' "a detail line"; p=$((p+1)); fi']
        if i == 0:
            body.append('if [ "$MODE" = "dup" ]; then printf \'  PASS  %s\\n\' "' + n + '"; p=$((p+1)); fi')
    lines += ['p=0; f=0'] + body + ['echo "===== Result ====="', 'printf \'  %d passed, %d failed\\n\' "$p" "$f"', 'exit "$f"']
    # mode "silent": writes nothing at all (the stale-log test)
    lines.insert(3, 'if [ "$MODE" = "silent" ]; then exit 0; fi')
    return "\n".join(lines) + "\n"


class DriftStateMachineCase(unittest.TestCase):
    def host(self):
        h = Host("drift-state-machine.yaml", FAKE_DOCKER_DRIFT, {"verify-drift-watch.sh": fake_watch_script()})
        self.addCleanup(h.close)
        return h

    def test_the_four_required_names_are_exactly_the_slugs_of_the_real_scripts_check_names(self):
        ok, bad = script_names("ok"), script_names("bad")
        self.assertEqual(len(ok), 4, ok)
        self.assertEqual(ok, bad, "a check must print the same name on PASS and on FAIL")
        self.assertEqual(["drift_state_machine." + slug(n) for n in ok], DRIFT_REQUIRED)

    def test_the_case_declares_those_names_as_steps_and_the_id_matches(self):
        case = json.loads((CASES / "drift-state-machine.yaml").read_text())
        self.assertEqual(case["id"], "drift_state_machine")
        names = [case["id"] + "." + s["name"] for s in case["steps"]]
        for req in DRIFT_REQUIRED:
            self.assertIn(req, names)

    def test_a_clean_run_passes_every_testcase_including_the_four_required(self):
        p, res = self.host().run()
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        for req in DRIFT_REQUIRED:
            self.assertEqual(res.get(req), "PASS", req)
        self.assertEqual({v for v in res.values()}, {"PASS"}, res)
        self.assertEqual(len(res), 9)                                   # console-sync + 8 steps

    def test_a_failing_check_fails_its_own_testcase_and_the_log_checks(self):
        p, res = self.host().run(FAKE_MODE="fail2")
        self.assertEqual(p.returncode, 1)
        self.assertEqual(res[DRIFT_REQUIRED[2]], "FAIL")
        self.assertEqual([res[r] for r in DRIFT_REQUIRED if r != DRIFT_REQUIRED[2]], ["PASS"] * 3)
        self.assertEqual(res["drift_state_machine.check-lines-parse-and-are-exactly-four"], "FAIL")
        self.assertEqual(res["drift_state_machine.script-summary-line-says-4-passed-0-failed"], "FAIL")

    def test_a_check_printed_twice_does_not_pass(self):
        p, res = self.host().run(FAKE_MODE="dup")
        self.assertEqual(res[DRIFT_REQUIRED[0]], "FAIL")                  # occurrences=2
        self.assertEqual(res["drift_state_machine.check-lines-parse-and-are-exactly-four"], "FAIL")
        self.assertEqual(p.returncode, 1)

    def test_a_stale_log_from_an_earlier_run_cannot_satisfy_the_case(self):
        h = self.host()
        (h.d / "log").write_text("".join(f"  PASS  {n}\n" for n in script_names("ok")) + "  4 passed, 0 failed\n")
        p, res = h.run(FAKE_MODE="silent")                                # the script writes nothing this time
        self.assertEqual(p.returncode, 1)
        self.assertEqual(res["drift_state_machine.run-verify-drift-watch"], "FAIL")
        for req in DRIFT_REQUIRED:
            self.assertEqual(res[req], "FAIL", req)

    def test_an_unreachable_topology_fails_instead_of_being_skipped(self):
        h = Host("drift-state-machine.yaml", "#!/bin/bash\nexit 1\n", {"verify-drift-watch.sh": fake_watch_script()})
        self.addCleanup(h.close)
        p, res = h.run()
        self.assertEqual(res["drift_state_machine.topology-is-up"], "FAIL")
        self.assertNotIn("SKIP", res.values())
        self.assertEqual(p.returncode, 1)

    def test_a_changed_name_does_not_pass(self):
        h = self.host()
        text = (h.d / "vm" / "verify-drift-watch.sh").read_text().replace("the count rises across cycles",
                                                                          "the count rises")
        write_exe(h.d / "vm" / "verify-drift-watch.sh", text)
        p, res = h.run()
        self.assertEqual(res[DRIFT_REQUIRED[1]], "FAIL")


if __name__ == "__main__":
    unittest.main()
