#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-only
"""Tests for verify-case.py: above all, that it can FAIL.

Run: python3 -m unittest -v toolkit/vm/test_verify_case.py   (or run this file)
"""

import importlib.util
import json
import os
import pty
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).resolve().parent
TOOL = HERE / "verify-case.py"
CASES = HERE / "cases"
EVIDENCE_DIR = Path(os.environ.get("VC_EVIDENCE_DIR") or HERE.parents[3] / "handoff" / "verify" / "evidence")


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


vc = load(TOOL, "verify_case")
mk = load(HERE.parent / "release" / "mk-release.py", "mk_release")


def run_tool(*args, cwd=None):
    r = subprocess.run([sys.executable, str(TOOL), *args], capture_output=True, text=True,
                       cwd=cwd, timeout=300)
    return r.returncode, r.stdout, r.stderr


def write_case(d, steps, **kw):
    doc = {"id": "t", "item": "t_item", "suite_commit": "0" * 40, "basis": "unit test", "steps": steps, **kw}
    p = Path(d) / "t.json"
    p.write_text(json.dumps(doc))
    return p


def junit_counts(path):
    root = ET.parse(path).getroot()
    return int(root.get("tests")), int(root.get("failures"))


class FixtureCanFail(unittest.TestCase):
    def test_selfcheck_fails_with_exactly_the_four_planted_failures(self):
        with tempfile.TemporaryDirectory() as d:
            rc, out, _ = run_tool(str(CASES / "selfcheck.yaml"), "--exec", "local", "--junit", f"{d}/j.xml")
            self.assertEqual(rc, 1, out)
            self.assertEqual(junit_counts(f"{d}/j.xml"), (6, 4))
            failed = {tc.get("name") for tc in ET.parse(f"{d}/j.xml").getroot().iter("testcase")
                      if tc.find("failure") is not None}
            self.assertEqual(failed, {"must-fail-regex-never-appears", "must-fail-wrong-exit-status",
                                      "must-fail-timeout", "must-fail-json-field"})

    def test_all_passing_case_exits_zero(self):
        with tempfile.TemporaryDirectory() as d:
            p = write_case(d, [{"name": "a", "basis": "x", "cmd": "echo hi", "expect_exit": 0,
                                "expect_regex": "^hi$"}])
            rc, out, _ = run_tool(str(p), "--exec", "local", "--junit", f"{d}/j.xml")
            self.assertEqual(rc, 0, out)
            self.assertEqual(junit_counts(f"{d}/j.xml"), (2, 0))      # console-sync + a

    def test_forbidden_regex_fails(self):
        with tempfile.TemporaryDirectory() as d:
            p = write_case(d, [{"name": "a", "basis": "x", "cmd": "echo Not reconciled",
                                "expect_not_regex": "Not reconciled"}])
            rc, *_ = run_tool(str(p), "--exec", "local", "--junit", f"{d}/j.xml")
            self.assertEqual(rc, 1)

    def test_state_persists_between_steps_like_a_real_session(self):
        with tempfile.TemporaryDirectory() as d:
            p = write_case(d, [
                {"name": "set", "basis": "x", "cmd": "SID=4242", "expect_exit": 0},
                {"name": "use", "basis": "x", "cmd": "echo sid=$SID", "expect_regex": "^sid=4242$"}])
            rc, *_ = run_tool(str(p), "--exec", "local", "--junit", f"{d}/j.xml")
            self.assertEqual(rc, 0)

    def test_a_step_that_hangs_fails_and_the_next_still_runs(self):
        with tempfile.TemporaryDirectory() as d:
            p = write_case(d, [
                {"name": "hang", "basis": "x", "cmd": "sleep 30", "timeout": 1, "expect_exit": 0},
                {"name": "after", "basis": "x", "cmd": "echo alive", "expect_regex": "^alive$"}])
            rc, *_ = run_tool(str(p), "--exec", "local", "--junit", f"{d}/j.xml")
            self.assertEqual(rc, 1)
            res = {tc.get("name"): tc.find("failure") is not None
                   for tc in ET.parse(f"{d}/j.xml").getroot().iter("testcase")}
            self.assertTrue(res["hang"])
            self.assertFalse(res["after"])

    def test_connection_refused_is_a_failure_not_a_pass(self):
        with tempfile.TemporaryDirectory() as d:
            s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
            p = write_case(d, [{"name": "a", "basis": "x", "cmd": "true", "expect_exit": 0}])
            rc, *_ = run_tool(str(p), "--console", f"127.0.0.1:{port}", "--junit", f"{d}/j.xml")
            self.assertEqual(rc, 1)
            text = Path(f"{d}/j.xml").read_text()
            self.assertIn("connection failed", text)
            self.assertEqual(junit_counts(f"{d}/j.xml"), (2, 2))       # both failed, none skipped

    def test_a_console_that_never_answers_is_a_failure(self):
        with tempfile.TemporaryDirectory() as d:
            srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen(1)
            port = srv.getsockname()[1]
            conns = []
            threading.Thread(target=lambda: conns.append(srv.accept()), daemon=True).start()
            p = write_case(d, [{"name": "a", "basis": "x", "cmd": "true", "expect_exit": 0}])
            t0 = time.time()
            # console-sync has a fixed 30 s allowance; shorten by patching is not possible
            # from outside, so this test only checks the verdict, and takes ~30 s.
            rc, *_ = run_tool(str(p), "--console", f"127.0.0.1:{port}", "--junit", f"{d}/j.xml")
            self.assertEqual(rc, 1)
            self.assertIn("did not answer", Path(f"{d}/j.xml").read_text())
            self.assertEqual(junit_counts(f"{d}/j.xml"), (2, 2))
            srv.close()


class InvalidCasesAreRejected(unittest.TestCase):
    def check(self, steps, why, **kw):
        with tempfile.TemporaryDirectory() as d:
            p = write_case(d, steps, **kw)
            rc, _, err = run_tool(str(p), "--exec", "local", "--junit", f"{d}/j.xml")
            self.assertEqual(rc, 2, err)
            self.assertIn(why, err)
            self.assertEqual(junit_counts(f"{d}/j.xml"), (1, 1))      # a failing file replaces any stale one

    def test_step_without_assertion(self):
        self.check([{"name": "a", "basis": "x", "cmd": "true"}], "declares no assertion")

    def test_no_steps(self):
        self.check([], "non-empty list")

    def test_unknown_step_key_typo(self):
        self.check([{"name": "a", "basis": "x", "cmd": "true", "expct_exit": 0, "expect_exit": 0}],
                   "unknown key 'expct_exit'")

    def test_unknown_case_key(self):
        self.check([{"name": "a", "basis": "x", "cmd": "true", "expect_exit": 0}],
                   "unknown case key", stepz=1)

    def test_missing_basis(self):
        self.check([{"name": "a", "cmd": "true", "expect_exit": 0}], "basis is required")

    def test_duplicate_and_reserved_names(self):
        s = {"basis": "x", "cmd": "true", "expect_exit": 0}
        self.check([{**s, "name": "a"}, {**s, "name": "a"}], "duplicate")
        self.check([{**s, "name": "console-sync"}], "reserved")

    def test_bad_regex(self):
        self.check([{"name": "a", "basis": "x", "cmd": "true", "expect_regex": "(unclosed"}], "bad regex")

    def test_unknown_variable(self):
        self.check([{"name": "a", "basis": "x", "cmd": "echo {{nope}}", "expect_exit": 0}],
                   "unknown variable")

    def test_oversized_command(self):
        self.check([{"name": "a", "basis": "x", "cmd": "echo " + "x" * 3000, "expect_exit": 0}], "split it")


class InteractiveConsole(unittest.TestCase):
    """A bash on a pty behind a TCP socket: echo, CRLF, and console noise like a real serial line."""

    def start_server(self, noise):
        srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen(1)
        port = srv.getsockname()[1]

        def serve():
            conn, _ = srv.accept()
            pid, fd = pty.fork()
            if pid == 0:
                os.execvp("bash", ["bash", "--noprofile", "--norc", "-i"])
            stop = threading.Event()

            def pump_in():
                while not stop.is_set():
                    try:
                        d = conn.recv(4096)
                    except OSError:
                        break
                    if not d:
                        break
                    os.write(fd, d)
            threading.Thread(target=pump_in, daemon=True).start()

            def pump_noise():
                n = 0
                while not stop.is_set() and noise:
                    time.sleep(0.05)
                    n += 1
                    try:
                        conn.sendall(b"[  %d.%06d] traps: dataplane[1] trap invalid opcode\r\n" % (300 + n, n))
                        conn.sendall(b"[\x1b[0;32m  OK  \x1b[0m] Started \x1b[0;1;39mfoo.service\x1b[0m - Foo.\r\n")
                    except OSError:
                        break
            threading.Thread(target=pump_noise, daemon=True).start()
            try:
                while True:
                    d = os.read(fd, 4096)
                    if not d:
                        break
                    conn.sendall(d)
            except OSError:
                pass
            stop.set()
            conn.close()
        threading.Thread(target=serve, daemon=True).start()
        return port

    def test_results_come_from_measured_output_despite_echo_and_noise(self):
        port = self.start_server(noise=True)
        with tempfile.TemporaryDirectory() as d:
            p = write_case(d, [
                {"name": "ok", "basis": "x", "cmd": "echo alpha; sleep 0.3; echo beta", "expect_exit": 0,
                 "expect_regex": ["^alpha$", "^beta$"], "expect_not_regex": "traps|Started"},
                {"name": "rc", "basis": "x", "cmd": "sh -c 'exit 7'", "expect_exit": 7},
                {"name": "wrong", "basis": "x", "cmd": "echo wrong", "expect_exit": 0,
                 "expect_regex": "^right$"}])
            rc, out, err = run_tool(str(p), "--console", f"127.0.0.1:{port}", "--junit", f"{d}/j.xml",
                                    "--transcript", f"{d}/raw.bin")
            res = {tc.get("name"): tc.find("failure") is not None
                   for tc in ET.parse(f"{d}/j.xml").getroot().iter("testcase")}
            self.assertEqual(res, {"console-sync": False, "ok": False, "rc": False, "wrong": True}, out + err)
            self.assertEqual(rc, 1)
            self.assertIn(b"traps", Path(f"{d}/raw.bin").read_bytes())    # noise was on the wire
            self.assertIn("stripped", Path(f"{d}/j.xml").read_text())

    def test_the_echoed_command_line_cannot_satisfy_an_assertion(self):
        # The typed command contains the string the step asserts on; the command itself prints
        # something else. Only the output may count.
        port = self.start_server(noise=False)
        with tempfile.TemporaryDirectory() as d:
            p = write_case(d, [{"name": "echo-trap", "basis": "x",
                                "cmd": "true # SHOULD_NOT_MATCH_ECHO", "expect_exit": 0,
                                "expect_regex": "SHOULD_NOT_MATCH_ECHO"}])
            rc, *_ = run_tool(str(p), "--console", f"127.0.0.1:{port}", "--junit", f"{d}/j.xml")
            self.assertEqual(rc, 1)


class ExpectJson(unittest.TestCase):
    def run_step(self, cmd, asserts, rc_expected=0):
        with tempfile.TemporaryDirectory() as d:
            p = write_case(d, [{"name": "j", "basis": "x", "cmd": cmd, "expect_exit": rc_expected,
                                "expect_json": asserts}])
            rc, out, err = run_tool(str(p), "--exec", "local", "--junit", f"{d}/j.xml")
            return rc, out + err

    def test_equal_exists_contains_matches_pass(self):
        rc, out = self.run_step(
            "printf '{\"commit\": null, \"dirty\": {}, \"todo\": [\"a\", \"b\"], \"s\": \"persisting\"}'",
            [{"path": ["commit"], "equals": None}, {"path": ["dirty"], "equals": {}},
             {"path": ["todo"], "contains": "b"}, {"path": ["s"], "matches": "^pers"},
             {"path": ["todo", 1], "equals": "b"}, {"path": ["gone"], "exists": False}])
        self.assertEqual(rc, 0, out)

    def test_wrong_value_missing_field_and_wrong_type_fail(self):
        doc = "printf '{\"a\": 1, \"b\": true}'"
        for assertion in ({"path": ["a"], "equals": 2},
                          {"path": ["zzz"], "equals": 1},
                          {"path": ["a"], "equals": True},      # 1 is not true
                          {"path": ["b"], "equals": 1},         # true is not 1
                          {"path": ["a"], "exists": False},
                          {"path": ["a"], "contains": "x"}):
            rc, out = self.run_step(doc, [assertion])
            self.assertEqual(rc, 1, (assertion, out))

    def test_output_that_is_not_one_json_document_fails(self):
        for cmd in ("echo not json", "printf '{\"a\": 1} trailing'", "printf '{\"a\": '", "true"):
            rc, out = self.run_step(cmd, [{"path": ["a"], "equals": 1}])
            self.assertEqual(rc, 1, (cmd, out))
            self.assertIn("not a single JSON document", out)

    def test_invalid_expect_json_is_rejected(self):
        for bad in ([{"path": ["a"]}],                                     # no operator
                    [{"path": ["a"], "equals": 1, "exists": True}],        # two operators
                    [{"path": "a", "equals": 1}],                          # path not a list
                    [{"path": ["a"], "equals": 1, "equal": 2}],            # unknown key
                    [{"path": ["a"], "matches": "(unclosed"}],
                    []):
            with tempfile.TemporaryDirectory() as d:
                p = write_case(d, [{"name": "j", "basis": "x", "cmd": "true", "expect_json": bad}])
                rc, _, err = run_tool(str(p), "--exec", "local", "--junit", f"{d}/j.xml")
                self.assertEqual(rc, 2, (bad, err))

    def test_case_without_basis_is_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            p = write_case(d, [{"name": "a", "basis": "x", "cmd": "true", "expect_exit": 0}])
            doc = json.loads(p.read_text()); del doc["basis"]; p.write_text(json.dumps(doc))
            rc, _, err = run_tool(str(p), "--exec", "local", "--junit", f"{d}/j.xml")
            self.assertEqual(rc, 2)
            self.assertIn("basis is required at case level", err)


class FakeSerialServer:
    """A TCP 'serial console': optional login prompt, then bash on a pty, recording what it was sent."""

    def __init__(self, user=None, password=None, noise=False):
        self.user, self.password, self.noise = user, password, noise
        self.received = bytearray()
        self.srv = socket.socket(); self.srv.bind(("127.0.0.1", 0)); self.srv.listen(1)
        self.port = self.srv.getsockname()[1]
        threading.Thread(target=self._serve, daemon=True).start()

    def _readline(self, conn):
        line = b""
        while not line.endswith(b"\r") and not line.endswith(b"\n"):
            d = conn.recv(1)
            if not d:
                return None
            self.received += d
            line += d
        return line.strip()

    def _serve(self):
        conn, _ = self.srv.accept()
        conn.settimeout(120)
        try:
            if self.user is not None:
                while True:
                    conn.sendall(b"danos-ci-test login: ")
                    u = self._readline(conn)
                    if u == b"":                    # a bare CR re-prompts, as a real getty does
                        continue
                    conn.sendall(b"\r\nPassword: ")
                    pw = self._readline(conn)
                    if u is None or pw is None:
                        return
                    if u.decode() == self.user and pw.decode() == self.password:
                        conn.sendall(b"\r\n")
                        break
                    conn.sendall(b"\r\nLogin incorrect\r\n")
            pid, fd = pty.fork()
            if pid == 0:
                os.environ["PS1"] = "bash$ "
                os.execvp("bash", ["bash", "--noprofile", "--norc", "-i"])
            stop = threading.Event()

            def pump_in():
                while not stop.is_set():
                    try:
                        d = conn.recv(4096)
                    except OSError:
                        break
                    if not d:
                        break
                    self.received += d
                    os.write(fd, d)
            threading.Thread(target=pump_in, daemon=True).start()
            if self.noise:
                def pump_noise():
                    n = 0
                    while not stop.is_set():
                        time.sleep(0.05); n += 1
                        try:
                            conn.sendall(b"[  %d.%06d] traps: noise\r\n" % (300 + n, n))
                        except OSError:
                            break
                threading.Thread(target=pump_noise, daemon=True).start()
            try:
                while True:
                    d = os.read(fd, 4096)
                    if not d:
                        break
                    conn.sendall(d)
            except OSError:
                pass
            stop.set()
        finally:
            conn.close()


class WireFormatAndLogin(unittest.TestCase):
    def test_nothing_typed_contains_question_mark_tab_or_bang(self):
        # the vyatta CLI shell binds ? and Tab to completion/help; the commands may contain them
        srv = FakeSerialServer()
        with tempfile.TemporaryDirectory() as d:
            p = write_case(d, [{"name": "hostile", "basis": "x",
                                "cmd": "echo 'a?b!c'\n\tfalse; echo rc=$?",
                                "expect_regex": ["^a\\?b!c$", "^rc=1$"]}])
            rc, out, err = run_tool(str(p), "--console", f"127.0.0.1:{srv.port}", "--junit", f"{d}/j.xml")
            self.assertEqual(rc, 0, out + err)
        typed = bytes(srv.received)
        self.assertGreater(len(typed), 100)
        for ch in (b"?", b"\t", b"!"):
            self.assertNotIn(ch, typed, f"{ch!r} was typed on the console")

    def test_login_with_user_and_password_then_assertions_run(self):
        srv = FakeSerialServer(user="root", password="s3cret")
        with tempfile.TemporaryDirectory() as d:
            p = write_case(d, [{"name": "a", "basis": "x", "cmd": "echo hi", "expect_exit": 0,
                                "expect_regex": "^hi$"}])
            rc, out, err = run_tool(str(p), "--console", f"127.0.0.1:{srv.port}", "--user", "root",
                                    "--password", "s3cret", "--junit", f"{d}/j.xml")
            self.assertEqual(rc, 0, out + err)
            self.assertEqual(junit_counts(f"{d}/j.xml"), (2, 0))

    def test_wrong_password_is_a_failure_not_a_pass(self):
        srv = FakeSerialServer(user="root", password="s3cret")
        with tempfile.TemporaryDirectory() as d:
            p = write_case(d, [{"name": "a", "basis": "x", "cmd": "echo hi", "expect_exit": 0}])
            rc, out, err = run_tool(str(p), "--console", f"127.0.0.1:{srv.port}", "--user", "root",
                                    "--password", "wrong", "--junit", f"{d}/j.xml")
            self.assertEqual(rc, 1, out + err)
            self.assertIn("login as 'root' failed", Path(f"{d}/j.xml").read_text())
            self.assertEqual(junit_counts(f"{d}/j.xml"), (2, 2))

    def test_user_without_console_is_a_usage_error(self):
        with tempfile.TemporaryDirectory() as d:
            p = write_case(d, [{"name": "a", "basis": "x", "cmd": "true", "expect_exit": 0}])
            rc, *_ = run_tool(str(p), "--exec", "local", "--user", "root", "--junit", f"{d}/j.xml")
            self.assertEqual(rc, 2)


class GoldenChecksCannotBeSkipped(unittest.TestCase):
    def test_missing_evidence_directory_fails_instead_of_skipping(self):
        env = {**os.environ, "VC_EVIDENCE_DIR": "/nonexistent-evidence-dir"}
        r = subprocess.run([sys.executable, "-m", "unittest", "-v",
                            "test_verify_case.GoldenAgainstRealTranscripts.test_f6",
                            "test_verify_case.GoldenAgainstRealTranscripts.test_item12",
                            "test_verify_case.GoldenAgainstRealTranscripts.test_p2_observed_refusal_text",
                            "test_verify_case.GoldenAgainstRealTranscripts.test_real_journal_line_satisfies_the_f6_expect_json"],
                           cwd=HERE, env=env, capture_output=True, text=True)
        out = r.stdout + r.stderr
        self.assertNotEqual(r.returncode, 0, out)
        self.assertNotIn("skipped", out)
        self.assertIn("golden checks are mandatory", out)
        self.assertEqual(out.count(" ... FAIL"), 4, out)          # each of the four failed, none skipped


class P2AndP4AssertDifferentThings(unittest.TestCase):
    """At P2 acmd has not been called; at P4 it has finished. The journal fields cannot tell the
    two apart (they are the same), so the case reads acmd's own state. Prove the two steps
    discriminate by running them against fake acmd files."""

    P2, P4 = "acmd-has-not-received-the-set-p2", "acmd-has-applied-the-set-p4"

    @classmethod
    def raw(cls):
        return json.load(open(CASES / "p2p4.yaml"))

    def step(self, name):
        return [s for s in self.raw()["steps"] if s["name"] == name][0]

    def verdict(self, step_name, d, files, rule_in_conf, ref_age):
        """Run one real step of p2p4.yaml in a directory laid out like the guest."""
        d = Path(d)
        ref = d / "ref"
        ref.write_text("")
        os.utime(ref, (1000, 1000))
        paths = {"acmd_conf": d / "acmd.conf", "configruleset": d / "configruleset.txt",
                 "policy_file": d / "vci-local.conf"}
        for key, path in paths.items():
            if files.get(key, True):                      # file exists
                path.write_text('{"x":1}' if key != "acmd_conf" or not rule_in_conf else
                                '{"rule":[{"tagnode":%d,"path":"/system/login"}]}' % rule_in_conf)
                t = 2000 if ref_age.get(key) == "newer" else 500
                os.utime(path, (t, t))
        st = self.step(step_name)
        case = {"id": "disc", "item": "t_item", "suite_commit": "0" * 40, "basis": "unit test",
                "vars": {**{k: str(v) for k, v in paths.items()}, "ref_p2": str(ref), "ref_p4": str(ref)},
                "steps": [st]}
        cp = d / "disc.json"
        cp.write_text(json.dumps(case))
        rc, out, err = run_tool(str(cp), "--exec", "local", "--junit", f"{d}/j.xml")
        self.assertIn(rc, (0, 1), out + err)
        return rc == 0

    def test_p2_like_state_passes_the_p2_step_and_fails_the_p4_step(self):
        with tempfile.TemporaryDirectory() as d:
            age = {"acmd_conf": "older", "configruleset": "older", "policy_file": "older"}
            self.assertTrue(self.verdict(self.P2, d, {}, 0, age))
        with tempfile.TemporaryDirectory() as d:
            self.assertFalse(self.verdict(self.P4, d, {}, 0, age))

    def test_p4_like_state_passes_the_p4_step_and_fails_the_p2_step(self):
        age = {"acmd_conf": "newer", "configruleset": "newer", "policy_file": "newer"}
        with tempfile.TemporaryDirectory() as d:
            self.assertTrue(self.verdict(self.P4, d, {}, 5, age))
        with tempfile.TemporaryDirectory() as d:
            self.assertFalse(self.verdict(self.P2, d, {}, 5, age))

    def test_a_half_finished_set_is_not_p4(self):
        # acmd.conf was rewritten and holds the rule, but the later files were not: acmd stopped
        # inside Set(), which is P3, not P4
        age = {"acmd_conf": "newer", "configruleset": "older", "policy_file": "older"}
        with tempfile.TemporaryDirectory() as d:
            self.assertFalse(self.verdict(self.P4, d, {}, 5, age))

    def test_the_rule_must_be_in_the_config_not_just_the_files_touched(self):
        age = {"acmd_conf": "newer", "configruleset": "newer", "policy_file": "newer"}
        with tempfile.TemporaryDirectory() as d:
            self.assertFalse(self.verdict(self.P4, d, {}, 0, age))          # touched, but no rule 5

    def test_a_fresh_guest_without_the_files_is_consistent_with_p2_only(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertTrue(self.verdict(self.P2, d, {"acmd_conf": False, "configruleset": False, "policy_file": False}, 0, {}))
        with tempfile.TemporaryDirectory() as d:
            self.assertFalse(self.verdict(self.P4, d, {"acmd_conf": False, "configruleset": False, "policy_file": False}, 0, {}))

    def test_the_two_halves_do_not_share_their_distinguishing_assertions(self):
        a, b = self.step(self.P2), self.step(self.P4)
        self.assertNotEqual(a["expect_regex"], b["expect_regex"])
        self.assertNotEqual(a["cmd"], b["cmd"])
        self.assertIn("pause-p2", self.step("arm-p2")["cmd"])
        self.assertIn("pause-p4", self.step("arm-p4")["cmd"])
        self.assertNotIn("p4", self.step("arm-p2")["cmd"].replace("pause-p2", ""))
        self.assertTrue(any(s["name"] == "acmd-is-idle-not-stopped-p4" for s in self.raw()["steps"]))
        self.assertTrue(any(s["name"] == "acmd-converged-to-running-after-reconcile-p4" for s in self.raw()["steps"]))

    def test_every_step_of_the_p2_and_p4_halves_says_what_it_rests_on(self):
        for s in self.raw()["steps"]:
            self.assertTrue(s["basis"].strip(), s["name"])
            if s["name"].startswith(("acmd-has-", "acmd-is-", "acmd-converged", "acmd-baseline")):
                self.assertTrue(s["basis"].startswith(("design", "fixture")), s["name"])


class SessionCreationIsAsserted(unittest.TestCase):
    """The first real run passed session-setup and discard (both print nothing) while $SID was empty
    in a later step, and only set then failed. A session must be proved to exist."""

    def live_step(self):
        raw = json.load(open(CASES / "f6.yaml"))
        return [s for s in raw["steps"] if s["name"] == "session-live-after-session-setup"][0]

    def run_live(self, prelude, fake_rc):
        with tempfile.TemporaryDirectory() as d:
            bindir = Path(d) / "bin"
            bindir.mkdir()
            api = bindir / "cli-shell-api"
            api.write_text(f"#!/bin/sh\n[ -n \"$VYATTA_CONFIG_SID\" ] || exit 1\nexit {fake_rc}\n")
            api.chmod(0o755)
            steps = [{"name": "env", "basis": "x", "cmd": f"export PATH={bindir}:$PATH; {prelude}", "expect_exit": 0},
                     self.live_step()]
            p = write_case(d, steps)
            rc, out, err = run_tool(str(p), "--exec", "local", "--junit", f"{d}/j.xml")
            return rc

    def test_a_real_session_passes(self):
        self.assertEqual(self.run_live("SID=4242", 0), 0)

    def test_an_empty_session_id_fails(self):
        self.assertEqual(self.run_live("SID=", 0), 1)

    def test_configd_not_knowing_the_session_fails(self):
        self.assertEqual(self.run_live("SID=4242", 1), 1)

    def test_every_session_creation_in_every_case_is_followed_by_a_live_check(self):
        for f in sorted(CASES.glob("*.yaml")):
            steps = vc.load_case(f)["steps"]
            for i, st in enumerate(steps):
                if "setupSession" in st["cmd"]:
                    self.assertLess(i + 1, len(steps), f.name)
                    self.assertIn("inSession", steps[i + 1]["cmd"], f"{f.name}: {st['name']}")

    def test_no_case_derives_a_session_id_from_a_subshell(self):
        # SID=$(sh -c ...) left $SID empty on the real image while its step still passed
        for f in sorted(CASES.glob("*.yaml")):
            for st in vc.load_case(f)["steps"]:
                # command substitution only: $((...)) is arithmetic, which is what is used now
                self.assertIsNone(re.search(r"SID2?=\$\((?!\()", st["cmd"]), f"{f.name}: {st['name']}")

    def test_the_diagnostic_probes_run_the_same_command_under_one_varied_condition(self):
        case = vc.load_case(CASES / "f6-diagnose.yaml")
        probes = [s for s in case["steps"] if s["name"].startswith("probe-") and "contrast" not in s["name"]]
        self.assertGreaterEqual(len(probes), 4)
        for s in probes:
            self.assertIn("cfgcli -print set system acm ruleset rule 1 path /system/login", s["cmd"], s["name"])
            self.assertTrue(any("authorization failed" in r.pattern for r in s["expect_not_regex"]), s["name"])


class HardenedInvocation(unittest.TestCase):
    def tool(self, d, extra, steps=None):
        p = write_case(d, steps or [{"name": "a", "basis": "x", "cmd": "true", "expect_exit": 0}])
        return run_tool(str(p), "--console", "127.0.0.1:9", *extra, "--junit", f"{d}/j.xml")

    def test_credentials_with_characters_the_cli_shell_binds_are_refused(self):
        for extra in (["--user", "ro?ot", "--password", "x"], ["--user", "root", "--password", "a!b"],
                      ["--user", "root", "--password", "a\tb"], ["--user", "root", "--password", "a\x01b"]):
            with tempfile.TemporaryDirectory() as d:
                rc, _, err = self.tool(d, extra)
                self.assertEqual(rc, 2, extra)
                self.assertIn("cannot be typed safely", err)

    def test_explicit_null_expect_exit_is_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            p = write_case(d, [{"name": "a", "basis": "x", "cmd": "true", "expect_exit": None,
                                "expect_regex": "x"}])
            rc, _, err = run_tool(str(p), "--exec", "local", "--junit", f"{d}/j.xml")
            self.assertEqual(rc, 2)
            self.assertIn("ambiguous", err)

    def test_regex_variables_are_escaped_with_re_prefix(self):
        with tempfile.TemporaryDirectory() as d:
            p = write_case(d, [{"name": "a", "basis": "x", "cmd": "echo 'a.b'; echo axb",
                                "expect_regex": "^{{re:v}}$"}], vars={"v": "a.b"})
            rc, *_ = run_tool(str(p), "--exec", "local", "--junit", f"{d}/j.xml")
            self.assertEqual(rc, 0)
            p = write_case(d, [{"name": "a", "basis": "x", "cmd": "echo axb", "expect_regex": "^{{re:v}}$"}],
                           vars={"v": "a.b"})
            rc, *_ = run_tool(str(p), "--exec", "local", "--junit", f"{d}/j.xml")
            self.assertEqual(rc, 1)                                           # axb must not match a\.b


class EvidenceProvenance(unittest.TestCase):
    def make(self, d, steps):
        subprocess.run(["git", "init", "-q", d], check=True)
        p = write_case(d, steps, suite_commit="auto")
        subprocess.run(["git", "-C", d, "add", "t.json"], check=True)
        subprocess.run(["git", "-C", d, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "c"], check=True)
        return p

    def test_evidence_names_the_fixture_that_produced_it(self):
        import hashlib
        with tempfile.TemporaryDirectory() as d:
            p = self.make(d, [{"name": "a", "basis": "x", "cmd": "true", "expect_exit": 0}])
            rc, out, err = run_tool(str(p), "--exec", "local", "--junit", f"{d}/r.xml", "--evidence", f"{d}/ev.json",
                                    "--iso-sha256", "a" * 64)
            self.assertEqual(rc, 0, out + err)
            rec = json.load(open(f"{d}/ev.json"))["records"][0]
            self.assertEqual(rec["tool_sha256"], hashlib.sha256(TOOL.read_bytes()).hexdigest())
            self.assertEqual(rec["console_py_sha256"], hashlib.sha256((HERE / "console.py").read_bytes()).hexdigest())
            self.assertIn(f'name="tool_sha256" value="{rec["tool_sha256"]}"', Path(f"{d}/r.xml").read_text())

    def test_a_case_that_changes_while_running_gets_no_evidence(self):
        with tempfile.TemporaryDirectory() as d:
            p = self.make(d, [{"name": "a", "basis": "x", "cmd": "echo ' ' >> {{case}}", "expect_exit": 0}])
            rc, _, err = run_tool(str(p), "--exec", "local", "--var", f"case={p}", "--junit", f"{d}/r.xml",
                                  "--evidence", f"{d}/ev.json", "--iso-sha256", "b" * 64, "--allow-dirty")
            self.assertEqual(rc, 2, err)
            self.assertIn("changed while it was running", err)
            self.assertFalse(Path(f"{d}/ev.json").exists())


class GoldenAgainstRealTranscripts(unittest.TestCase):
    """Every expectation was taken from real output; prove the regexes still match it."""

    def transcript(self, rel):
        p = EVIDENCE_DIR / rel
        if not p.is_file():
            # Never skip: a wrong path or a cleaned-up evidence directory must not turn the
            # check that the cases still match real output into silence.
            self.fail(f"recorded transcript {p} not found; the golden checks are mandatory "
                      "(set VC_EVIDENCE_DIR to the evidence directory)")
        t = vc.ANSI.sub(b"", p.read_bytes()).decode("utf-8", "replace").replace("\r", "")
        t, _ = vc.strip_noise(t, ["kernel", "systemd"])
        return t

    def check(self, case_file, transcript_rel, skip=(), minimum=5):
        text = self.transcript(transcript_rel)
        case = vc.load_case(CASES / case_file)
        checked = 0
        for st in case["steps"]:
            if st["name"] in skip:
                continue
            for rx in st["expect_regex"]:
                if "observed:" in st["basis"]:
                    checked += 1
                    self.assertTrue(rx.search(text), f"{st['name']}: {rx.pattern!r} not in the real transcript")
            for rx in st["expect_not_regex"]:
                if "observed:" in st["basis"]:
                    self.assertFalse(rx.search(text), f"{st['name']}: forbidden {rx.pattern!r} IS in the transcript")
        self.assertGreaterEqual(checked, minimum, "too few expectations were checked against the real transcript")

    def test_f6(self):
        # the journal checks print values from python that the original script did not
        self.check("f6.yaml", "f6-20261026/f6-transcript.txt",
                   skip={"services-active", "commit-succeeds", "session-after-restart"})

    def test_item12(self):
        self.check("item12.yaml", "item12-20261026/i12-transcript.txt",
                   skip={"injector-caught-the-runfile-write", "services-active", "install-injector",
                         "start-injector"}, minimum=4)

    def test_p2_observed_refusal_text(self):
        text = self.transcript("p2p4-20261026/p2-transcript.txt")
        case = vc.load_case(CASES / "p2p4.yaml")
        st = [s for s in case["steps"] if s["name"] == "commit-changing-acmd-is-refused-before-send-p2"][0]
        for rx in st["expect_regex"]:
            self.assertTrue(rx.search(text), rx.pattern)

    def test_real_journal_line_satisfies_the_f6_expect_json(self):
        p = EVIDENCE_DIR / "f6-20261026" / "serial-f6.log"
        if not p.is_file():
            self.fail(f"recorded log {p} not found; the golden checks are mandatory")
        docs = []
        for ln in p.read_text(errors="replace").splitlines():
            ln = ln.strip()
            if ln.startswith('{"version":1'):
                try:
                    docs.append(json.loads(ln))
                except ValueError:
                    pass
        self.assertGreaterEqual(len(docs), 2, "expected the post-commit and post-restart journal lines")
        case = vc.load_case(CASES / "f6.yaml")
        st = [x for x in case["steps"] if x["name"] == "journal-clean-after-commit"][0]
        for d in docs:
            self.assertEqual(vc.eval_json(st["expect_json"], json.dumps(d)), [])

    def test_no_step_depends_on_journald(self):
        for f in sorted(CASES.glob("*.yaml")):
            for st in vc.load_case(f)["steps"]:
                self.assertNotIn("journalctl", st["cmd"], f"{f.name}:{st['name']}")

    def test_design_derived_steps_are_labelled(self):
        case = vc.load_case(CASES / "p2p4.yaml")
        for st in case["steps"]:
            if st["name"].startswith(("reconcile-refuses", "reconcile-after-acmd")):
                self.assertIn("not yet observed", st["basis"])


class EvidenceDocument(unittest.TestCase):
    def make(self, d, steps):
        # a throwaway git repo so suite_commit 'auto' resolves and is clean
        subprocess.run(["git", "init", "-q", d], check=True)
        p = write_case(d, steps, suite_commit="auto")
        subprocess.run(["git", "-C", d, "add", "t.json"], check=True)
        subprocess.run(["git", "-C", d, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "c"], check=True)
        return p, subprocess.run(["git", "-C", d, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()

    def gate(self, d, ev, status_expected):
        """What mk-release.load_evidence says, with the signature step stubbed out (the
        document is unsigned) and the item registered (it is not in VERIFICATION_ITEMS yet)."""
        iso = json.load(open(ev))["records"][0]["iso_sha256"]
        mk.verify_signature = lambda *_: (True, "")
        mk.VERIFICATION_ITEMS = list(mk.VERIFICATION_ITEMS) + [("t", "t_item", "NOT_RUN", "")]
        items, _, errs = mk.load_suite_config(f"{d}/../suite.json") if False else ({}, None, [])
        return mk.load_evidence(ev, iso, trusted_key="ignored", suite_config=None)

    def test_passing_run_gives_a_record_the_gate_accepts_structurally(self):
        with tempfile.TemporaryDirectory() as d:
            p, head = self.make(d, [{"name": "a", "basis": "x", "cmd": "echo hi", "expect_exit": 0,
                                     "expect_regex": "^hi$"}])
            rc, out, err = run_tool(str(p), "--exec", "local", "--junit", f"{d}/r.xml", "--evidence", f"{d}/ev.json",
                                    "--iso-sha256", "a" * 64)
            self.assertEqual(rc, 0, out + err)
            rec = json.load(open(f"{d}/ev.json"))["records"][0]
            self.assertEqual(json.load(open(f"{d}/ev.json"))["format"], mk.EVIDENCE_FORMAT)
            self.assertEqual((rec["status"], rec["suite_commit"], rec["result_file"]), ("PASS", head, "r.xml"))
            self.assertEqual(rec["cases"], {"total": 2, "passed": 2, "failed": 0, "skipped": 0})
            # PASS needs the operator's suite config, exactly as the gate says
            acc, rej = self.gate(d, f"{d}/ev.json", "PASS")
            self.assertEqual(acc, {})
            self.assertIn("PASS needs a trusted suite definition", rej[0][1])
            # ...and with the config this tool can emit, it is accepted
            with tempfile.TemporaryDirectory() as cfgdir:
                cfg = f"{cfgdir}/suite.json"
                rc2, *_ = run_tool(str(p), "--validate", "--emit-suite-config", cfg)
                self.assertEqual(rc2, 0)
                items, _, errs = mk.load_suite_config(cfg, f"{d}/ev.json")
                self.assertEqual(errs, [])
                acc, rej = mk.load_evidence(f"{d}/ev.json", "a" * 64, trusted_key="ignored", suite_config=items)
                self.assertEqual((list(acc), rej), (["t_item"], []))

    def test_evidence_record_has_every_field_and_the_hash_is_of_the_real_file(self):
        import hashlib
        with tempfile.TemporaryDirectory() as d:
            p, head = self.make(d, [{"name": "a", "basis": "x", "cmd": "echo hi", "expect_exit": 0}])
            iso = Path(d) / "fake.iso"
            iso.write_bytes(b"not really an iso")
            rc, out, err = run_tool(str(p), "--exec", "local", "--junit", f"{d}/res/r.xml" if False else f"{d}/r.xml",
                                    "--evidence", f"{d}/ev.json", "--iso", str(iso))
            self.assertEqual(rc, 0, out + err)
            doc = json.load(open(f"{d}/ev.json"))
            self.assertEqual(doc["format"], "danos-verification-evidence-v2")
            rec = doc["records"][0]
            for k in ("item", "iso_sha256", "suite_commit", "status", "result_file", "result_sha256", "cases"):
                self.assertIn(k, rec)
            self.assertEqual(rec["iso_sha256"], hashlib.sha256(iso.read_bytes()).hexdigest())
            self.assertEqual(rec["suite_commit"], head)
            self.assertFalse(os.path.isabs(rec["result_file"]))
            self.assertEqual(rec["result_sha256"],
                             hashlib.sha256((Path(d) / rec["result_file"]).read_bytes()).hexdigest())
            self.assertEqual(rec["cases"]["total"], junit_counts(f"{d}/{rec['result_file']}")[0])

    def test_failing_run_is_recorded_as_fail(self):
        with tempfile.TemporaryDirectory() as d:
            p, _ = self.make(d, [{"name": "a", "basis": "x", "cmd": "echo hi", "expect_regex": "nope"}])
            rc, *_ = run_tool(str(p), "--exec", "local", "--junit", f"{d}/r.xml", "--evidence", f"{d}/ev.json",
                              "--iso-sha256", "b" * 64)
            self.assertEqual(rc, 1)
            self.assertEqual(json.load(open(f"{d}/ev.json"))["records"][0]["status"], "FAIL")
            acc, rej = self.gate(d, f"{d}/ev.json", "FAIL")
            self.assertEqual((list(acc), rej), (["t_item"], []))
            self.assertEqual(acc["t_item"]["status"], "FAIL")

    def test_tampered_result_file_is_rejected_by_the_gate(self):
        with tempfile.TemporaryDirectory() as d:
            p, _ = self.make(d, [{"name": "a", "basis": "x", "cmd": "echo hi", "expect_regex": "hi"}])
            run_tool(str(p), "--exec", "local", "--junit", f"{d}/r.xml", "--evidence", f"{d}/ev.json", "--iso-sha256", "c" * 64)
            Path(f"{d}/r.xml").write_text(Path(f"{d}/r.xml").read_text().replace("failures=\"0\"", "failures=\"0\" "))
            acc, rej = self.gate(d, f"{d}/ev.json", "PASS")
            self.assertEqual(acc, {})
            self.assertIn("sha256 mismatch", rej[0][1])

    def test_uncommitted_case_file_is_refused_unless_allowed(self):
        with tempfile.TemporaryDirectory() as d:
            p, _ = self.make(d, [{"name": "a", "basis": "x", "cmd": "true", "expect_exit": 0}])
            p.write_text(p.read_text().replace('"t_item"', '"t_item2"'))
            rc, _, err = run_tool(str(p), "--exec", "local", "--junit", f"{d}/r.xml", "--evidence", f"{d}/ev.json",
                                  "--iso-sha256", "d" * 64)
            self.assertEqual(rc, 2)
            self.assertIn("uncommitted", err)
            self.assertFalse(Path(f"{d}/ev.json").exists())
            rc, *_ = run_tool(str(p), "--exec", "local", "--junit", f"{d}/r.xml", "--evidence", f"{d}/ev.json",
                              "--iso-sha256", "d" * 64, "--allow-dirty")
            self.assertEqual(rc, 0)
            self.assertTrue(json.load(open(f"{d}/ev.json"))["records"][0]["suite_dirty"])

    def test_evidence_needs_an_iso_digest_and_a_contained_result(self):
        with tempfile.TemporaryDirectory() as d:
            p, _ = self.make(d, [{"name": "a", "basis": "x", "cmd": "true", "expect_exit": 0}])
            rc, *_ = run_tool(str(p), "--exec", "local", "--junit", f"{d}/r.xml", "--evidence", f"{d}/ev.json")
            self.assertEqual(rc, 2)
            os.makedirs(f"{d}/sub")
            rc, _, err = run_tool(str(p), "--exec", "local", "--junit", f"{d}/r.xml", "--evidence", f"{d}/sub/ev.json",
                                  "--iso-sha256", "e" * 64)
            self.assertEqual(rc, 2)
            self.assertIn("inside the evidence", err)


class ShippedCases(unittest.TestCase):
    def test_all_cases_validate_and_name_a_basis_for_every_step(self):
        for f in sorted(CASES.glob("*.yaml")):
            case = vc.load_case(f)
            self.assertTrue(case["steps"], f)

    def test_evidence_format_constant_matches_mk_release(self):
        self.assertEqual(vc.EVIDENCE_FORMAT, mk.EVIDENCE_FORMAT)
        self.assertEqual(vc.SUITE_CONFIG_FORMAT, mk.SUITE_CONFIG_FORMAT)


if __name__ == "__main__":
    unittest.main(verbosity=2)
