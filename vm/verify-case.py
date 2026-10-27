#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-only
"""Assertion-style verification of one case against a guest; JUnit + evidence out.

Every step of a case runs a command in a logged-in root shell and asserts on
what was MEASURED: the exit status (equality) and regexes over the command's
output. A step passes only if every assertion it declares holds. Timeouts, a
lost or refused console, an invalid case and steps that could not run are all
FAIL. Nothing in this file can produce a PASS that was not derived from
measured output; a case with no steps, or a step with no assertion, is
rejected before anything runs.

Usage:
  verify-case.py CASE (--exec local | --console HOST:PORT [--user U --password P])
                 --junit OUT.xml [--evidence OUT.json (--iso FILE | --iso-sha256 HEX)]
  verify-case.py CASE --validate

Both executors go through the same shell protocol and the same assertion code;
they differ only in how bytes reach a shell.

Exit status: 0 every step passed, 1 at least one step failed, 3 nothing failed but at
least one step was SKIPPED (a skip is never a pass: the release gate counts it as not
passed), 2 the case or the invocation is invalid (a JUnit file with one failing testcase is still written,
so a stale passing file cannot be mistaken for this run).
"""

import argparse
import base64
import hashlib
import importlib.util
import json
import os
import re
import select
import socket
import subprocess
import sys
import time
import uuid
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from console import ANSI  # noqa: E402  same ANSI/OSC stripping as the console driver

EVIDENCE_FORMAT = "danos-verification-evidence-v2"   # must equal mk-release.py's
SUITE_CONFIG_FORMAT = "danos-suite-config-v1"
HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
MAX_CMD = 2400          # bytes; base64 of it must fit one terminal line

CASE_KEYS = {"id", "item", "suite_commit", "description", "basis", "vars", "noise_filter", "steps"}
STEP_KEYS = {"name", "cmd", "basis", "timeout", "expect_exit", "expect_regex",
             "expect_not_regex", "expect_json", "abort_on_fail", "requires"}
REQUIRES_KEYS = {"cmd", "reason", "timeout"}
JSON_OPS = {"equals", "exists", "contains", "matches"}
NOISE = {
    # what the guest prints on the console by itself, interleaved with output
    "kernel": re.compile(r"^\[\s*\d+\.\d+\]\s"),
    "systemd": re.compile(r"^(\[\s*(OK|FAILED|DEPEND|SKIP|TIME)\s*\]|\s+(Starting|Stopping|Reloading|Restarting)\b.*\.\.\.\s*$)"),
}


class CaseError(Exception):
    def __init__(self, problems):
        super().__init__("; ".join(problems))
        self.problems = problems


class ShellError(Exception):
    pass


class StepTimeout(ShellError):
    def __init__(self, msg, partial=""):
        super().__init__(msg)
        self.partial = partial


class ConsoleLost(ShellError):
    pass


# ---- case definition --------------------------------------------------------

def _rx_list(v, where, problems):
    if v is None:
        return []
    items = [v] if isinstance(v, str) else v
    if not isinstance(items, list) or not all(isinstance(x, str) and x for x in items):
        problems.append(f"{where}: must be a non-empty string or a list of them")
        return []
    out = []
    for x in items:
        try:
            out.append(re.compile(x, re.MULTILINE))
        except re.error as e:
            problems.append(f"{where}: bad regex {x!r}: {e}")
    return out


def load_case(path, cli_vars=None):
    path = Path(path)
    problems = []
    try:
        text = path.read_text()
    except OSError as e:
        raise CaseError([f"cannot read case: {e}"])
    # JSON is valid YAML. Cases are written as JSON text so that nothing here
    # depends on a YAML parser (none is installed on the build hosts, and a
    # hand-rolled one inside an assertion tool could mis-read a case and weaken
    # it). With PyYAML present a .yaml file may use YAML syntax too.
    try:
        doc = json.loads(text)
    except ValueError as e:
        if path.suffix not in (".yaml", ".yml"):
            raise CaseError([f"not valid JSON: {e}"])
        try:
            import yaml
        except ImportError:
            raise CaseError([f"not JSON, and PyYAML is not installed to read YAML syntax: {e}"])
        try:
            doc = yaml.safe_load(text)
        except Exception as e2:  # noqa: BLE001
            raise CaseError([f"not valid YAML: {e2}"])
    if not isinstance(doc, dict):
        raise CaseError(["case must be an object"])
    for k in sorted(set(doc) - CASE_KEYS):
        problems.append(f"unknown case key {k!r} (a typo would silently weaken the case)")
    cid = doc.get("id")
    if not isinstance(cid, str) or not NAME.match(cid):
        problems.append("id must match [A-Za-z0-9][A-Za-z0-9._-]*")
    item = doc.get("item")
    if not isinstance(item, str) or not NAME.match(item or ""):
        problems.append("item must name a verification item")
    cbasis = doc.get("basis")
    if isinstance(cbasis, list) and cbasis and all(isinstance(x, str) and x.strip() for x in cbasis):
        cbasis = "\n".join(cbasis)
    if not isinstance(cbasis, str) or not cbasis.strip():
        problems.append("basis is required at case level: where the expected values come from "
                        "(design sections, recorded real output)")
    sc = doc.get("suite_commit")
    if sc != "auto" and not (isinstance(sc, str) and HEX40.match(sc)):
        problems.append("suite_commit must be 'auto' or a 40-hex commit")
    variables = doc.get("vars", {})
    if not isinstance(variables, dict) or not all(isinstance(k, str) and isinstance(v, str)
                                                   for k, v in variables.items()):
        problems.append("vars must be an object of strings")
        variables = {}
    variables = {**variables, **(cli_vars or {})}
    noise = doc.get("noise_filter", ["kernel", "systemd"])
    if not isinstance(noise, list) or not set(noise) <= set(NOISE):
        problems.append(f"noise_filter must be a list drawn from {sorted(NOISE)}")
        noise = []
    steps_in = doc.get("steps")
    if not isinstance(steps_in, list) or not steps_in:
        problems.append("steps must be a non-empty list (a case with no steps proves nothing)")
        steps_in = []

    def sub(s, where):
        # {{name}} inserts the value; {{re:name}} inserts it regex-escaped (for use in patterns)
        def rep(m):
            if m.group(2) not in variables:
                problems.append(f"{where}: unknown variable {{{{{m.group(2)}}}}}")
                return m.group(0)
            v = variables[m.group(2)]
            return re.escape(v) if m.group(1) else v
        return re.sub(r"\{\{(re:)?(\w+)\}\}", rep, s)

    steps, seen = [], set()
    for i, st in enumerate(steps_in):
        where = f"step[{i}]"
        if not isinstance(st, dict):
            problems.append(f"{where}: must be an object")
            continue
        name = st.get("name")
        where = f"step {name!r}" if isinstance(name, str) else where
        for k in sorted(set(st) - STEP_KEYS):
            problems.append(f"{where}: unknown key {k!r}")
        if not isinstance(name, str) or not NAME.match(name):
            problems.append(f"{where}: name must match [A-Za-z0-9][A-Za-z0-9._-]*")
            continue
        if name == "console-sync" or name in seen:
            problems.append(f"{where}: duplicate or reserved step name")
        seen.add(name)
        cmd = st.get("cmd")
        if isinstance(cmd, list) and all(isinstance(x, str) for x in cmd):
            cmd = "\n".join(cmd)
        if not isinstance(cmd, str) or not cmd.strip():
            problems.append(f"{where}: cmd must be a non-empty string or list of lines")
            continue
        cmd = sub(cmd, where)
        if len(cmd.encode()) > MAX_CMD:
            problems.append(f"{where}: cmd is {len(cmd.encode())} bytes, over {MAX_CMD}; split it")
        basis = st.get("basis")
        if not isinstance(basis, str) or not basis.strip():
            problems.append(f"{where}: basis is required: say where the expectation comes from "
                            "(observed:<document> or design:<reference>)")
        exp_exit = st.get("expect_exit")
        if "expect_exit" in st and exp_exit is None:
            problems.append(f"{where}: expect_exit: null is ambiguous; omit the key to not check the exit status")
        if exp_exit is not None and (not isinstance(exp_exit, int) or isinstance(exp_exit, bool)
                                     or not 0 <= exp_exit <= 255):
            problems.append(f"{where}: expect_exit must be an integer 0..255")
        rx = _rx_list(st.get("expect_regex"), f"{where}: expect_regex", problems)
        rx = [re.compile(sub(r.pattern, where), re.MULTILINE) for r in rx]
        nrx = _rx_list(st.get("expect_not_regex"), f"{where}: expect_not_regex", problems)
        nrx = [re.compile(sub(r.pattern, where), re.MULTILINE) for r in nrx]
        ejson = []
        raw_ej = st.get("expect_json")
        if raw_ej is not None:
            if not isinstance(raw_ej, list) or not raw_ej:
                problems.append(f"{where}: expect_json must be a non-empty list of assertions")
                raw_ej = []
            for j, a in enumerate(raw_ej):
                w = f"{where}: expect_json[{j}]"
                if not isinstance(a, dict):
                    problems.append(f"{w}: must be an object"); continue
                ops = set(a) & JSON_OPS
                for k in sorted(set(a) - JSON_OPS - {"path"}):
                    problems.append(f"{w}: unknown key {k!r}")
                if len(ops) != 1:
                    problems.append(f"{w}: needs exactly one of {sorted(JSON_OPS)}"); continue
                path_ = a.get("path")
                if not isinstance(path_, list) or not all(
                        (isinstance(x, str) or (isinstance(x, int) and not isinstance(x, bool)))
                        for x in path_):
                    problems.append(f"{w}: path must be a list of keys / indexes"); continue
                op = next(iter(ops))
                if op == "exists" and not isinstance(a["exists"], bool):
                    problems.append(f"{w}: exists must be true or false"); continue
                if op == "matches":
                    try:
                        a = {**a, "matches": re.compile(a["matches"])}
                    except (re.error, TypeError) as e:
                        problems.append(f"{w}: bad regex: {e}"); continue
                ejson.append(a)
        if exp_exit is None and not rx and not nrx and not ejson:
            problems.append(f"{where}: declares no assertion (expect_exit / expect_regex / "
                            "expect_not_regex / expect_json); a step that asserts nothing "
                            "cannot pass or fail")
        requires = None
        if st.get("requires") is not None:
            rq = st["requires"]
            if not isinstance(rq, dict):
                problems.append(f"{where}: requires must be an object with cmd and reason")
            else:
                for k in sorted(set(rq) - REQUIRES_KEYS):
                    problems.append(f"{where}: requires: unknown key {k!r}")
                rcmd, rreason, rto = rq.get("cmd"), rq.get("reason"), rq.get("timeout", 30)
                if not isinstance(rcmd, str) or not rcmd.strip():
                    problems.append(f"{where}: requires.cmd must be a non-empty string")
                elif len(rcmd.encode()) > MAX_CMD:
                    problems.append(f"{where}: requires.cmd is over {MAX_CMD} bytes")
                if not isinstance(rreason, str) or not rreason.strip():
                    problems.append(f"{where}: requires.reason is required: say what is unavailable when the probe fails")
                if isinstance(rto, bool) or not isinstance(rto, (int, float)) or rto <= 0:
                    problems.append(f"{where}: requires.timeout must be a positive number")
                    rto = 30
                if isinstance(rcmd, str) and isinstance(rreason, str):
                    requires = {"cmd": sub(rcmd, where), "reason": rreason, "timeout": float(rto)}
        timeout = st.get("timeout", 60)
        if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or timeout <= 0:
            problems.append(f"{where}: timeout must be a positive number")
            timeout = 60
        steps.append({"name": name, "cmd": cmd, "basis": basis or "", "timeout": float(timeout),
                      "expect_exit": exp_exit, "expect_regex": rx, "expect_not_regex": nrx,
                      "expect_json": ejson, "abort_on_fail": bool(st.get("abort_on_fail", False)),
                      "requires": requires})
    if problems:
        raise CaseError(problems)
    return {"id": cid, "item": item, "suite_commit": sc, "description": doc.get("description", ""),
            "basis": cbasis,
            "noise": noise, "steps": steps, "path": path,
            "sha256": hashlib.sha256(text.encode()).hexdigest()}


# ---- transports -------------------------------------------------------------

class SockTransport:
    eol = b"\r"

    def __init__(self, endpoint, connect_timeout=10, sock=None):
        self.endpoint = endpoint
        if sock is not None:
            self.s = sock
        elif endpoint.startswith("unix:"):
            self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.s.settimeout(connect_timeout)
            self.s.connect(endpoint[5:])
        else:
            host, _, port = endpoint.rpartition(":")
            self.s = socket.create_connection((host or "127.0.0.1", int(port)),
                                              timeout=connect_timeout)

    def write(self, data):
        self.s.sendall(data)

    def read(self, timeout):
        self.s.settimeout(timeout)
        try:
            d = self.s.recv(65536)
        except socket.timeout:
            return b""
        except OSError:
            return None
        return d if d else None

    def interrupt(self):
        self.s.sendall(b"\x03" + self.eol)

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


LOGIN_FORBIDDEN = re.compile(r"[?!\t\x00-\x1f\x7f]")


def check_login_chars(user, password):
    """The login handshake types these verbatim. console.py warns that the vyatta CLI shell
    binds ? and Tab (completion/help), and ! starts history expansion, so a credential
    containing one would be mangled on the wire and fail in a confusing way: refuse it."""
    bad = [n for n, v in (("--user", user), ("--password", password))
           if v is not None and LOGIN_FORBIDDEN.search(v)]
    return [f"{n} contains a character (?, !, Tab or a control character) that cannot be typed "
            "safely on the console" for n in bad]


def open_console(endpoint, connect_timeout, user=None, password=None):
    """A serial console as a transport; with user/password, log in first.

    The login handshake is console.py's own (Console.login): it copes with a
    console left at a login prompt, at Password:, or already in a shell.
    """
    if user is None:
        return SockTransport(endpoint, connect_timeout)
    from console import Console

    class TcpConsole(Console):          # console.py's reader, over TCP instead of a unix socket
        def __init__(self, ep):
            host, _, port = ep.rpartition(":")
            self.s = socket.create_connection((host or "127.0.0.1", int(port)), timeout=connect_timeout)
            self.s.settimeout(2)
            self.timeout, self.buf, self.transcript = 120, b"", b""

    c = TcpConsole(endpoint)
    try:
        c.login(user, password or "")
    except Exception as e:  # noqa: BLE001
        c.s.close()
        raise ConsoleLost(f"login as {user!r} failed: {type(e).__name__}: {e}")
    return SockTransport(endpoint, sock=c.s)


class LocalTransport:
    """A local bash on pipes: same marker protocol, no guest needed."""
    eol = b"\n"
    endpoint = "local"

    def __init__(self):
        self._start()

    def _start(self):
        self.p = subprocess.Popen(["bash", "--noprofile", "--norc"], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)

    def write(self, data):
        try:
            self.p.stdin.write(data)
        except OSError:
            raise ConsoleLost("local shell is gone")

    def read(self, timeout):
        r, _, _ = select.select([self.p.stdout], [], [], timeout)
        if not r:
            return b""
        d = os.read(self.p.stdout.fileno(), 65536)
        return d if d else None

    def interrupt(self):
        self.close()
        self._start()       # no tty to send ^C to: a fresh shell (state is lost)

    def close(self):
        try:
            self.p.kill()
            self.p.wait(timeout=5)
        except Exception:  # noqa: BLE001
            pass


# ---- the shell protocol -----------------------------------------------------

class Shell:
    """Run commands in one persistent shell and measure exit status and output.

    Each command is sent base64-encoded between two markers whose text never
    appears in the echoed command line (the quotes split them), so the
    terminal's echo cannot satisfy a marker. Only text strictly between the
    markers is output; the exit status is the one the shell printed.

    Nothing typed contains "?", Tab or "!": the vyatta CLI shell binds "?" and
    Tab to completion/help (console.py learned this the hard way), so the exit
    status is read with ${PIPESTATUS[0]} and the command itself travels as
    base64.
    """

    def __init__(self, transport, raw_log):
        self.t = transport
        self.raw = raw_log
        self.buf = b""

    def _clean(self):
        return ANSI.sub(b"", self.buf).replace(b"\r", b"")

    def _fill(self, wait):
        d = self.t.read(wait)
        if d is None:
            raise ConsoleLost("console connection closed")
        if d:
            self.buf += d
            self.raw.append(d)

    def run(self, cmd, timeout):
        nonce = uuid.uuid4().hex[:12]
        b64 = base64.b64encode(cmd.encode()).decode()
        line = (f"printf '\\n%s%s\\n' '@@VC-B-' '{nonce}'; "
                f"_vc=\"$(printf %s '{b64}' | base64 -d)\" && eval \"$_vc\" 2>&1; "
                f"printf '\\n%s%s:%s\\n' '@@VC-E-' '{nonce}' \"${{PIPESTATUS[0]}}\"").encode() + self.t.eol
        self.buf = b""      # anything before this command is not its output
        self.t.write(line)
        endre = re.compile(rb"@@VC-E-" + nonce.encode() + rb":(\d+)\n")
        begre = re.compile(rb"@@VC-B-" + nonce.encode() + rb"\n")
        deadline = time.monotonic() + timeout
        while True:
            clean = self._clean()
            e = endre.search(clean)
            if e:
                b = begre.search(clean)
                if not b or b.end() > e.start():
                    raise ShellError("end marker without a begin marker; output is untrustworthy")
                out = clean[b.end():e.start()]
                if out.endswith(b"\n"):
                    out = out[:-1]      # the newline our end-marker printf adds
                self.buf = b""
                return int(e.group(1)), out.decode("utf-8", "replace")
            if time.monotonic() >= deadline:
                b = begre.search(clean)
                partial = clean[b.end():] if b else clean
                raise StepTimeout(f"no end marker within {timeout:g}s",
                                  partial.decode("utf-8", "replace"))
            self._fill(min(1.0, max(0.05, deadline - time.monotonic())))

    def recover(self):
        """After a timeout: interrupt and prove the shell answers again."""
        for _ in range(2):
            try:
                self.t.interrupt()
                rc, out = self.run("echo vc-recovered", 20)
                if rc == 0 and "vc-recovered" in out:
                    return True
            except ShellError:
                continue
        return False


def strip_noise(text, kinds):
    if not kinds:
        return text, 0
    keep, dropped = [], 0
    for ln in text.split("\n"):
        if any(NOISE[k].search(ln) for k in kinds):
            dropped += 1
        else:
            keep.append(ln)
    return "\n".join(keep), dropped


# ---- running a case ---------------------------------------------------------

_MISSING = object()


def _canon(v):
    # json.dumps tells True from 1 and 1 from 1.0, which == does not
    return json.dumps(v, sort_keys=True)


def _walk(doc, path):
    node = doc
    for k in path:
        if isinstance(k, int) and isinstance(node, list) and -len(node) <= k < len(node):
            node = node[k]
        elif isinstance(k, str) and isinstance(node, dict) and k in node:
            node = node[k]
        else:
            return _MISSING
    return node


def eval_json(assertions, output):
    """The step output must be exactly one JSON document; assert on its fields."""
    text = output.strip()
    try:
        doc, end = json.JSONDecoder().raw_decode(text)
        if text[end:].strip():
            raise ValueError("text after the JSON document")
    except ValueError as e:
        return [f"expect_json: the step output is not a single JSON document ({e})"]
    fails = []
    for a in assertions:
        path = a["path"]
        shown = "/".join(str(x) for x in path) or "(root)"
        node = _walk(doc, path)
        if "exists" in a:
            if (node is not _MISSING) != a["exists"]:
                fails.append(f"expect_json {shown}: exists={node is not _MISSING}, expected {a['exists']}")
        elif node is _MISSING:
            fails.append(f"expect_json {shown}: no such field")
        elif "equals" in a:
            if _canon(node) != _canon(a["equals"]):
                fails.append(f"expect_json {shown}: {_canon(node)[:120]} != expected {_canon(a['equals'])[:120]}")
        elif "contains" in a:
            want = a["contains"]
            if isinstance(node, list):
                ok = any(_canon(x) == _canon(want) for x in node)
            elif isinstance(node, str) and isinstance(want, str):
                ok = want in node
            elif isinstance(node, dict) and isinstance(want, str):
                ok = want in node
            else:
                ok = False
            if not ok:
                fails.append(f"expect_json {shown}: does not contain {_canon(want)[:80]} (value {_canon(node)[:80]})")
        elif "matches" in a:
            if not (isinstance(node, str) and a["matches"].search(node)):
                fails.append(f"expect_json {shown}: {_canon(node)[:80]} does not match {a['matches'].pattern!r}")
    return fails


def evaluate(step, rc, output):
    fails = []
    if step["expect_exit"] is not None and rc != step["expect_exit"]:
        fails.append(f"exit status {rc}, expected {step['expect_exit']}")
    for rx in step["expect_regex"]:
        if not rx.search(output):
            fails.append(f"expected regex not found: {rx.pattern!r}")
    for rx in step["expect_not_regex"]:
        m = rx.search(output)
        if m:
            fails.append(f"forbidden regex found: {rx.pattern!r} (matched {m.group(0)[:80]!r})")
    if step.get("expect_json"):
        fails.extend(eval_json(step["expect_json"], output))
    return fails


def run_case(case, make_transport, raw_log):
    """Returns a list of result dicts: name, basis, elapsed, rc, output, noise, failures."""
    results = []

    def res(name, basis, t0, rc, out, noise, fails, skipped=None):
        results.append({"name": name, "basis": basis, "elapsed": time.monotonic() - t0,
                        "rc": rc, "output": out, "noise": noise, "failures": fails,
                        "skipped": skipped})

    def not_run(step, why):
        res(step["name"], step["basis"], time.monotonic(), None, "", 0, [f"not run: {why}"])

    sync_step = {"name": "console-sync", "basis": "fixture: the shell must answer a nonce round trip",
                 "expect_exit": 0, "expect_not_regex": [], "expect_json": []}
    nonce = uuid.uuid4().hex[:10]
    sync_step["expect_regex"] = [re.compile(rf"^vc-sync-{nonce}$", re.MULTILINE)]

    t0 = time.monotonic()
    try:
        transport = make_transport()
    except Exception as e:  # noqa: BLE001
        res("console-sync", sync_step["basis"], t0, None, "", 0,
            [f"connection failed: {type(e).__name__}: {e}"])
        for st in case["steps"]:
            not_run(st, "no console connection")
        return results
    shell = Shell(transport, raw_log)
    lost = None
    try:
        try:
            rc, out = shell.run(f"echo vc-sync-{nonce}", 30)
            res("console-sync", sync_step["basis"], t0, rc, out, 0, evaluate(sync_step, rc, out))
        except StepTimeout as e:
            res("console-sync", sync_step["basis"], t0, None, e.partial, 0,
                [f"timeout: {e}; the console did not answer (is a root shell logged in?)"])
            lost = "console-sync timed out"
        except ShellError as e:
            res("console-sync", sync_step["basis"], t0, None, "", 0, [f"console error: {e}"])
            lost = f"console error at sync: {e}"
        aborted = None
        for st in case["steps"]:
            if lost:
                not_run(st, lost)
                continue
            if aborted:
                not_run(st, f"aborted after failed step {aborted!r}")
                continue
            t0 = time.monotonic()
            rq = st.get("requires")
            if rq:
                # A precondition for MEASURING (e.g. journald is usable), not an assertion. If it does not hold the step
                # is skipped and recorded as skipped; it is never a pass. A probe that cannot even run is a lost console.
                try:
                    prc, pout = shell.run(rq["cmd"], rq["timeout"])
                    why = None if prc == 0 else f"{rq['reason']} (probe exit status {prc})"
                except StepTimeout:
                    pout = ""
                    why = f"{rq['reason']} (probe timed out after {rq['timeout']:g}s)"
                    if not shell.recover():
                        res(st["name"], st["basis"], t0, None, "", 0, [f"console unusable after the timeout of the precondition probe: {why}"])
                        lost = f"console unusable after the probe of step {st['name']!r}"
                        continue
                except ShellError as e:
                    res(st["name"], st["basis"], t0, None, "", 0, [f"console error during the precondition probe: {e}"])
                    lost = f"console lost during the probe of step {st['name']!r}: {e}"
                    continue
                if why:
                    res(st["name"], st["basis"], t0, None, pout, 0, [], skipped=why)
                    continue
            try:
                rc, raw_out = shell.run(st["cmd"], st["timeout"])
            except StepTimeout as e:
                out, noise = strip_noise(e.partial, case["noise"])
                res(st["name"], st["basis"], t0, None, out, noise,
                    [f"timeout: {e}"])
                if not shell.recover():
                    lost = f"console unusable after the timeout of step {st['name']!r}"
                elif st["abort_on_fail"]:
                    aborted = st["name"]
                continue
            except ShellError as e:
                res(st["name"], st["basis"], t0, None, "", 0, [f"console error: {e}"])
                lost = f"console lost during step {st['name']!r}: {e}"
                continue
            out, noise = strip_noise(raw_out, case["noise"])
            fails = evaluate(st, rc, out)
            res(st["name"], st["basis"], t0, rc, out, noise, fails)
            if fails and st["abort_on_fail"]:
                aborted = st["name"]
    finally:
        transport.close()
    return results


# ---- output -----------------------------------------------------------------

_BAD_XML = re.compile("[^\u0009\u000a\u000d -퟿-�\U00010000-\U0010ffff]")


def xml_text(s):
    return _BAD_XML.sub("?", s)


def excerpt(text, head=1500, tail=5000):
    if len(text) <= head + tail:
        return text
    return text[:head] + f"\n... [{len(text) - head - tail} characters omitted] ...\n" + text[-tail:]


def build_junit(case_id, results, props):
    failures = sum(1 for r in results if r["failures"])
    skipped = sum(1 for r in results if r.get("skipped") and not r["failures"])
    suite = ET.Element("testsuite", name=case_id, tests=str(len(results)),
                       failures=str(failures), errors="0", skipped=str(skipped),
                       time=f"{sum(r['elapsed'] for r in results):.3f}",
                       timestamp=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                       hostname=socket.gethostname())
    pe = ET.SubElement(suite, "properties")
    for k, v in props.items():
        ET.SubElement(pe, "property", name=k, value=xml_text(str(v)))
    for r in results:
        tc = ET.SubElement(suite, "testcase", classname=case_id, name=r["name"],
                           time=f"{r['elapsed']:.3f}")
        measured = (f"exit status: {r['rc']}\nkernel/systemd console lines stripped: {r['noise']}\n"
                    f"basis: {r['basis']}\n--- measured output ---\n{excerpt(r['output'])}")
        if r["failures"]:
            f = ET.SubElement(tc, "failure", message=xml_text(r["failures"][0][:200]),
                              type="AssertionError")
            f.text = xml_text("\n".join(r["failures"]) + "\n" + measured)
        elif r.get("skipped"):
            sk = ET.SubElement(tc, "skipped", message=xml_text(r["skipped"][:200]))
            sk.text = xml_text(f"SKIPPED, not passed: {r['skipped']}\nbasis: {r['basis']}\n--- precondition probe output ---\n{excerpt(r['output'])}")
        else:
            so = ET.SubElement(tc, "system-out")
            so.text = xml_text(measured)
    return ET.ElementTree(suite), failures


def counts_from_junit(path):
    """Recount from the written file, like a consumer would (never from our own tallies)."""
    root = ET.parse(path).getroot()
    tcs = list(root.iter("testcase"))
    failed = sum(1 for t in tcs if t.find("failure") is not None or t.find("error") is not None)
    skipped = sum(1 for t in tcs if t.find("skipped") is not None)
    return {"total": len(tcs), "passed": len(tcs) - failed - skipped, "failed": failed,
            "skipped": skipped}


def tool_provenance():
    """Which fixture produced a result: hashes of this file and of console.py (the login
    handshake), plus the commit/dirty state of the repository that holds them."""
    me = Path(__file__).resolve()
    prov = {"tool_sha256": sha256_file(me), "console_py_sha256": sha256_file(HERE / "console.py")}
    rc, head = git(me.parent, "rev-parse", "HEAD")
    if rc == 0 and HEX40.match(head):
        _, st = git(me.parent, "status", "--porcelain", "--", str(me), str(HERE / "console.py"))
        prov["tool_commit"], prov["tool_dirty"] = head, bool(st)
    return prov


def sha256_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def git(cwd, *args):
    r = subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True)
    return r.returncode, r.stdout.strip()


def resolve_suite_commit(case):
    """(commit, dirty). 'auto' = HEAD of the repository holding the case file."""
    if case["suite_commit"] != "auto":
        return case["suite_commit"], False
    d = case["path"].parent
    rc, head = git(d, "rev-parse", "HEAD")
    if rc != 0 or not HEX40.match(head):
        raise CaseError(["suite_commit is 'auto' but the case file is not in a git repository"])
    _, st = git(d, "status", "--porcelain", "--", str(case["path"]))
    return head, bool(st)


def registered_items():
    p = HERE.parent / "release" / "mk-release.py"
    if not p.is_file():
        return None
    try:
        spec = importlib.util.spec_from_file_location("mk_release_probe", p)
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        return {i for _, i, _, _ in m.VERIFICATION_ITEMS if i not in m.SCRIPT_OUTPUT_ROWS}
    except Exception:  # noqa: BLE001
        return None


def write_invalid(junit, case_id, problems):
    if not junit:
        return
    suite = ET.Element("testsuite", name=case_id or "invalid-case", tests="1", failures="1",
                       errors="0", skipped="0", time="0.000")
    tc = ET.SubElement(suite, "testcase", classname=case_id or "invalid-case",
                       name="case-definition-valid", time="0.000")
    f = ET.SubElement(tc, "failure", message=xml_text(problems[0][:200]), type="InvalidCase")
    f.text = xml_text("\n".join(problems))
    ET.ElementTree(suite).write(junit, encoding="utf-8", xml_declaration=True)


def emit_suite_config(cases, path):
    """One entry per item; cases that share an item contribute all their testcase names to it."""
    items = {}
    for case in cases:
        names = [f"{case['id']}.console-sync"] + [f"{case['id']}.{s['name']}" for s in case["steps"]]
        items.setdefault(case["item"], []).extend(names)
    doc = {"format": SUITE_CONFIG_FORMAT, "items": {
        item: {"min_cases": len(names), "required_cases": names, "suite_commit": None}
        for item, names in items.items()}}
    Path(path).write_text(json.dumps(doc, indent=2) + "\n")


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Run an assertion case against a guest shell; write JUnit XML and "
                    "verification evidence. PASS is derived only from measured output.")
    ap.add_argument("case", nargs="+", help="case definition (JSON; YAML if PyYAML is installed); "
                                            "several only with --validate or --emit-suite-config")
    where = ap.add_mutually_exclusive_group()
    where.add_argument("--console", metavar="HOST:PORT|unix:PATH",
                       help="serial console of a booted guest; give --user/--password unless a "
                            "shell is already logged in")
    where.add_argument("--exec", dest="exec_", choices=["local"],
                       help="run the steps in a local bash (selfcheck, unit tests)")
    ap.add_argument("--user", help="log in on the console as this user (console.py handshake)")
    ap.add_argument("--password", help="password for --user")
    ap.add_argument("--junit", metavar="FILE", help="write JUnit XML here")
    ap.add_argument("--evidence", metavar="FILE",
                    help="write a danos-verification-evidence-v2 document (needs --junit under "
                         "the same directory, and --iso or --iso-sha256)")
    ap.add_argument("--iso", metavar="FILE", help="the ISO under test (its sha256 is computed)")
    ap.add_argument("--iso-sha256", metavar="HEX")
    ap.add_argument("--allow-dirty", action="store_true",
                    help="allow evidence from a case file with uncommitted changes (recorded)")
    ap.add_argument("--var", action="append", default=[], metavar="K=V")
    ap.add_argument("--transcript", metavar="FILE", help="also save the raw console bytes")
    ap.add_argument("--connect-timeout", type=float, default=10)
    ap.add_argument("--validate", action="store_true", help="check the case and exit")
    ap.add_argument("--emit-suite-config", metavar="FILE",
                    help="write the danos-suite-config-v1 entry that requires every case of this "
                         "file (operator config: keep it OUT of the evidence directory)")
    a = ap.parse_args(argv)

    cli_vars = {}
    for kv in a.var:
        k, _, v = kv.partition("=")
        if not k or not _:
            print(f"error: --var wants K=V, got {kv!r}", file=sys.stderr)
            return 2
        cli_vars[k] = v
    if len(a.case) > 1 and not (a.validate or a.emit_suite_config):
        print("error: running needs exactly one case file", file=sys.stderr)
        return 2
    loaded = []
    for cf in a.case:
        try:
            loaded.append(load_case(cf, cli_vars))
        except CaseError as e:
            print(f"INVALID CASE {cf}:\n  " + "\n  ".join(e.problems), file=sys.stderr)
            write_invalid(a.junit, None, e.problems)
            return 2
    case = loaded[0]
    if a.emit_suite_config:
        emit_suite_config(loaded, a.emit_suite_config)
    if a.validate:
        for c in loaded:
            print(f"case {c['id']}: {len(c['steps'])} steps, item {c['item']}: valid")
        return 0
    if not (a.console or a.exec_):
        print("error: give --console HOST:PORT or --exec local", file=sys.stderr)
        return 2
    if (a.user is not None or a.password is not None) and not (a.console and a.user is not None):
        print("error: --user/--password apply to --console and need --user", file=sys.stderr)
        return 2
    cred_problems = check_login_chars(a.user, a.password)
    if cred_problems:
        print("error: " + "; ".join(cred_problems), file=sys.stderr)
        return 2
    if not a.junit:
        print("error: --junit is required (the JUnit file is the result)", file=sys.stderr)
        return 2

    iso_sha = a.iso_sha256
    if a.evidence:
        if a.iso:
            iso_sha = sha256_file(a.iso)
        if not iso_sha or not HEX64.match(iso_sha):
            print("error: --evidence needs --iso FILE or --iso-sha256 (64 hex)", file=sys.stderr)
            return 2
        ev_dir = Path(a.evidence).resolve().parent
        jpath = Path(a.junit).resolve()
        if ev_dir != jpath.parent and ev_dir not in jpath.parents:
            print("error: --junit must be inside the evidence file's directory", file=sys.stderr)
            return 2
        try:
            commit, dirty = resolve_suite_commit(case)
        except CaseError as e:
            print("error: " + e.problems[0], file=sys.stderr)
            return 2
        if dirty and not a.allow_dirty:
            print(f"error: {case['path']} has uncommitted changes, so no commit contains this "
                  "suite; commit it or pass --allow-dirty (recorded in the evidence)", file=sys.stderr)
            return 2
    else:
        commit, dirty = None, False

    known = registered_items()
    if known is not None and case["item"] not in known:
        print(f"warning: item {case['item']!r} is not a measured item in mk-release.py; its "
              "evidence will be rejected there until the item is added", file=sys.stderr)

    raw = []
    make = (lambda: LocalTransport()) if a.exec_ else \
        (lambda: open_console(a.console, a.connect_timeout, a.user, a.password))
    results = run_case(case, make, raw)
    if a.transcript:
        Path(a.transcript).write_bytes(b"".join(raw))

    prov = tool_provenance()
    props = {"case": case["id"], "item": case["item"], "case_sha256": case["sha256"],
             "endpoint": "local" if a.exec_ else a.console, "tool": "verify-case.py",
             "tool_sha256": prov["tool_sha256"], "basis": case["basis"]}
    if iso_sha:
        props["iso_sha256"] = iso_sha
    if commit:
        props["suite_commit"] = commit
    tree, failures = build_junit(case["id"], results, props)
    tree.write(a.junit, encoding="utf-8", xml_declaration=True)
    counts = counts_from_junit(a.junit)
    status = "PASS" if counts["total"] > 0 and counts["passed"] == counts["total"] else "FAIL"

    for r in results:
        mark = "FAIL" if r["failures"] else ("SKIP" if r.get("skipped") else "PASS")
        print(f"{mark}  {case['id']}.{r['name']}  ({r['elapsed']:.1f}s)")
        for f in r["failures"]:
            print(f"      {f}")
        if mark == "SKIP":
            print(f"      skipped, not passed: {r['skipped']}")
    print(f"{case['id']}: {counts['passed']}/{counts['total']} passed, {counts['failed']} failed, "
          f"{counts['skipped']} skipped -> {status}   junit={a.junit}")

    if a.evidence:
        now = hashlib.sha256(Path(case["path"]).read_text().encode()).hexdigest()   # same as load_case
        if now != case["sha256"]:
            print("error: the case file changed while it was running; the result belongs to no "
                  "single version of the case, so no evidence is written", file=sys.stderr)
            return 2
        rec = {"item": case["item"], "iso_sha256": iso_sha, "suite_commit": commit,
               "status": status,
               "result_file": os.path.relpath(Path(a.junit).resolve(), ev_dir),
               "result_sha256": sha256_file(a.junit), "cases": counts,
               "case_file_sha256": case["sha256"], "suite_dirty": dirty,
               "generated_by": "toolkit/vm/verify-case.py", **prov}
        Path(a.evidence).write_text(json.dumps(
            {"format": EVIDENCE_FORMAT, "records": [rec]}, indent=2) + "\n")
        print(f"evidence={a.evidence} (unsigned: sign it before it can be used as release input)")
    if counts["failed"]:
        return 1
    return 0 if status == "PASS" else 3


if __name__ == "__main__":
    sys.exit(main())
