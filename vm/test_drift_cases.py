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


# ---- cases/dpa-object-model.yaml ---------------------------------------------------------------------

DPA_ID = "dpa_object_model_nexthop_group"
DPA_REQUIRED = DPA_ID + ".dpa-class-nexthop-group-is-enumerable"

# A fake docker that answers like the three routers: the last argument is the remote command, the router is the
# vyatta@192.168.203.15x argument; the answers are files named <what>.<last octet> in $FAKE_DIR.
FAKE_DOCKER_DPA = r"""#!/bin/bash
cmd="${@: -1}"
host=$(printf '%s\n' "$@" | grep -o 'vyatta@192.168.203.[0-9]*' | head -1); n=${host##*.}
case "$cmd" in
  "echo UP_"*) eval "$cmd" ;;
  *"dpa object show nexthop-group"*) cat "$FAKE_DIR/nhg.$n" ;;
  *"route6 show"*) cat "$FAKE_DIR/rt6.$n" ;;
  *"route show"*) cat "$FAKE_DIR/rt4.$n" ;;
esac
exit 0
"""


def nhg_doc(enumerable=True, keys=None, state="NO_SUPPORT", backend="sw-dataplane"):
    keys = keys if keys is not None else ["inet/idx:%d" % i for i in range(6)] + ["inet6/idx:%d" % i for i in range(3)]
    return json.dumps({"dpa_objects": {
        "classes": [{"class": "route", "enumerable": True}, {"class": "nexthop-group", "enumerable": enumerable}],
        "objects": [{"class": "nexthop-group", "key": k, "state": state, "backend": backend} for k in keys]}})


def routes(key, idx):
    return json.dumps({key: [{"prefix": "10.%d.0.0/24" % i, "scope": 0, "nh_index": n} for i, n in enumerate(idx)]})


class DpaObjectModelCase(unittest.TestCase):
    ROUTERS = ("155", "156", "157")

    def setup(self, **per_router):
        """per_router: router octet -> dict(nhg=..., rt4=..., rt6=...) overriding the healthy answers."""
        h = Host("dpa-object-model.yaml", FAKE_DOCKER_DPA)
        self.addCleanup(h.close)
        fd = h.d / "answers"
        fd.mkdir()
        for r in self.ROUTERS:
            o = per_router.get(r, {})
            (fd / f"nhg.{r}").write_text(o.get("nhg", nhg_doc()))
            (fd / f"rt4.{r}").write_text(o.get("rt4", routes("route_show", [4, 5, 5])))
            (fd / f"rt6.{r}").write_text(o.get("rt6", routes("route6_show", [1, 2])))
        return h, fd

    def run_case(self, **per_router):
        h, fd = self.setup(**per_router)
        return h.run(FAKE_DIR=str(fd))

    def test_the_id_is_the_suite_config_prefix(self):
        case = json.loads((CASES / "dpa-object-model.yaml").read_text())
        self.assertEqual(case["id"], DPA_ID)
        self.assertEqual(case["item"], DPA_ID)
        self.assertIn(DPA_REQUIRED, [case["id"] + "." + s["name"] for s in case["steps"]])
        self.assertIn("HARDWARE PATH NOT COVERED", case["description"])

    def test_healthy_routers_pass_with_no_support_and_sw_dataplane(self):
        p, res = self.run_case()
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(res[DPA_REQUIRED], "PASS")
        self.assertEqual(set(res.values()), {"PASS"})

    def test_the_state_and_backend_are_reported_not_judged(self):
        other = nhg_doc(state="FULL", backend="some-hw-backend")
        p, res = self.run_case(**{"156": {"nhg": other}})
        self.assertEqual(res[DPA_REQUIRED], "PASS", p.stdout)

    def test_a_class_that_is_not_enumerable_fails(self):
        p, res = self.run_case(**{"156": {"nhg": nhg_doc(enumerable=False)}})
        self.assertEqual(res[DPA_REQUIRED], "FAIL")
        self.assertEqual(p.returncode, 1)

    def test_a_key_that_is_not_inet_or_inet6_idx_fails(self):
        for bad in ("inet/idx:x", "ipv4/idx:3", "inet/3", "inet6/idx:"):
            p, res = self.run_case(**{"157": {"nhg": nhg_doc(keys=["inet/idx:1", bad])}})
            self.assertEqual(res[DPA_REQUIRED], "FAIL", bad)

    def test_an_empty_enumeration_fails(self):
        p, res = self.run_case(**{"155": {"nhg": nhg_doc(keys=[])}})
        self.assertEqual(res[DPA_REQUIRED], "FAIL")

    def test_an_ipv4_nh_index_that_is_not_enumerated_fails(self):
        p, res = self.run_case(**{"156": {"rt4": routes("route_show", [4, 99])}})
        self.assertEqual(res[DPA_REQUIRED], "FAIL")

    def test_an_ipv6_nh_index_that_is_not_enumerated_fails(self):
        p, res = self.run_case(**{"157": {"rt6": routes("route6_show", [1, 42])}})
        self.assertEqual(res[DPA_REQUIRED], "FAIL")

    def test_the_families_are_not_mixed_up(self):
        # index 7 exists only as inet6: a route6 may use it, an IPv4 route may not
        keys = ["inet/idx:%d" % i for i in range(4)] + ["inet6/idx:7"]
        p, res = self.run_case(**{"155": {"nhg": nhg_doc(keys=keys), "rt4": routes("route_show", [1]), "rt6": routes("route6_show", [7])}})
        self.assertEqual(res[DPA_REQUIRED], "PASS", p.stdout)
        p, res = self.run_case(**{"155": {"nhg": nhg_doc(keys=keys), "rt4": routes("route_show", [7]), "rt6": routes("route6_show", [7])}})
        self.assertEqual(res[DPA_REQUIRED], "FAIL")

    def test_a_router_that_does_not_answer_fails_rather_than_being_skipped(self):
        p, res = self.run_case(**{"157": {"nhg": "", "rt4": "", "rt6": ""}})
        self.assertEqual(res[DPA_REQUIRED], "FAIL")
        self.assertNotIn("SKIP", res.values())

    def test_a_route_without_nh_index_fails_loudly(self):
        bad = json.dumps({"route_show": [{"prefix": "10.0.0.0/24"}]})
        p, res = self.run_case(**{"155": {"rt4": bad}})
        self.assertEqual(res[DPA_REQUIRED], "FAIL")

    def test_no_routes_at_all_is_not_a_failure_of_this_claim(self):
        p, res = self.run_case(**{"156": {"rt4": json.dumps({"route_show": []}), "rt6": json.dumps({"route6_show": []})}})
        self.assertEqual(res[DPA_REQUIRED], "PASS", p.stdout)


if __name__ == "__main__":
    unittest.main()
