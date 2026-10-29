#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-only
"""Tests for the SIGCONT trap in induce-drift-{mpls,mcast}.sh.

The scripts SIGSTOP a daemon on R2; if they are interrupted it must be resumed,
and the resume must never signal a process that is not that daemon.

A fake `docker` stands in for `docker exec danos-robot sshpass ... ssh`. It does
not just log: for commands aimed at R2 it RUNS the remote shell text under bash
with fake pgrep / sudo / cat, so the real remote logic (marker line, comm check,
pgrep fallback) is what is being tested. A stub that printed nothing would leave
STOPPED_PID empty and make every case pass vacuously.

Run: python3 -m unittest -v toolkit/vm/test_induce_drift_trap.py   (or run this file)
"""

import os
import re
import signal
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent

DOCKER = r"""#!/bin/bash
# args: exec danos-robot sshpass -p vyatta ssh -o .. -o .. <host> <command>
cmd="${@: -1}"; host="${@: -2:1}"
echo "REMOTE $host $cmd" >> "$FAKE_LOG"
case "$host" in *.156) ;; *) echo stub; exit 0;; esac
case "$cmd" in *pgrep*) ;; *) echo stub; exit 0;; esac
exec bash -c "$cmd"
"""
PGREP = r"""#!/bin/bash
# first call answers FAKE_PGREP_FIRST, later calls FAKE_PGREP (so "pgrep misses once" is expressible)
n=$(cat "$FAKE_DIR/pgrep.n" 2>/dev/null || echo 0); echo $((n + 1)) > "$FAKE_DIR/pgrep.n"
if [ "$n" = 0 ] && [ -n "${FAKE_PGREP_FIRST+x}" ]; then echo "$FAKE_PGREP_FIRST"; else echo "$FAKE_PGREP"; fi
exit 0
"""
SUDO = r"""#!/bin/bash
echo "SUDO $*" >> "$FAKE_LOG"
exit 0
"""
CAT = r"""#!/bin/bash
case "$1" in /proc/*/comm) echo "$FAKE_COMM";; *) exec /bin/cat "$@";; esac
"""
SLEEP = r"""#!/bin/bash
# instant, except once the stop step has been issued and the case wants to be interrupted
if [ -n "$FAKE_BLOCK" ] && grep -q 'INDUCE_STOPPED_PID' "$FAKE_LOG"; then exec /bin/sleep 60; fi
exit 0
"""


class Trap:
    def __init__(self, script, proc, **env):
        self.script, self.proc, self.env = script, proc, env

    def run(self, sig=None):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            bindir = d / "bin"
            bindir.mkdir()
            for name, body in (("docker", DOCKER), ("pgrep", PGREP), ("sudo", SUDO), ("cat", CAT), ("sleep", SLEEP)):
                p = bindir / name
                p.write_text(body)
                p.chmod(p.stat().st_mode | stat.S_IXUSR)
            log = d / "log"
            log.write_text("")
            env = dict(os.environ, PATH=f"{bindir}:{os.environ['PATH']}", FAKE_LOG=str(log), FAKE_DIR=str(d),
                       FAKE_COMM=self.proc, FAKE_PGREP="4242", FAKE_BLOCK="1" if sig else "")
            env.update(self.env)
            p = subprocess.Popen(["bash", str(HERE / self.script)], env=env, start_new_session=True,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            if sig:
                deadline = time.time() + 20
                while "INDUCE_STOPPED_PID" not in log.read_text() and time.time() < deadline:
                    if p.poll() is not None:
                        break
                    time.sleep(0.05)
                time.sleep(0.3)
                os.killpg(p.pid, sig)  # whole group, so the blocked sleep dies too
            try:
                out, _ = p.communicate(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL)
                raise
            sudo = [l[5:] for l in log.read_text().splitlines() if l.startswith("SUDO ")]
            return p.returncode, out, sudo


def conts(sudo):
    return [m.group(1) for l in sudo if (m := re.fullmatch(r"kill -CONT (\S+)", l))]


class Mixin:
    def test_term_resumes_the_stopped_pid_exactly_once(self):
        rc, out, sudo = Trap(self.script, self.proc).run(signal.SIGTERM)
        self.assertEqual(rc, 143, out)
        self.assertEqual(conts(sudo), ["4242"], out)
        self.assertIn("[trap] resumed %s 4242" % self.proc, out)

    def test_int_exits_130_with_the_same_single_cont(self):
        rc, out, sudo = Trap(self.script, self.proc).run(signal.SIGINT)
        self.assertEqual(rc, 130, out)
        self.assertEqual(conts(sudo), ["4242"], out)

    def test_pgrep_miss_at_stop_time_falls_back_to_a_checked_pgrep(self):
        # first pgrep (stop step) finds nothing -> no pid in the marker; the trap looks again
        rc, out, sudo = Trap(self.script, self.proc, FAKE_PGREP_FIRST="").run(signal.SIGTERM)
        self.assertEqual(rc, 143, out)
        self.assertNotIn("kill -STOP", " ".join(sudo))
        self.assertEqual(conts(sudo), ["4242"], out)

    def test_pgrep_miss_at_stop_time_with_a_small_pid_never_invents_a_pid(self):
        # the r1 bug: STOPPED line "… 4 04:17:50" glued into 4041750 and CONT went to that pid
        rc, out, sudo = Trap(self.script, self.proc, FAKE_PGREP_FIRST="", FAKE_PGREP="4").run(signal.SIGTERM)
        self.assertEqual(conts(sudo), ["4"], out)
        self.assertEqual([c for c in conts(sudo) if c != "4"], [])

    def test_nothing_found_means_no_cont_and_a_message(self):
        rc, out, sudo = Trap(self.script, self.proc, FAKE_PGREP="").run(signal.SIGTERM)
        self.assertEqual(rc, 143, out)
        self.assertEqual(conts(sudo), [], out)
        self.assertIn("nothing to resume", out)

    def test_wrong_comm_is_never_signalled(self):
        rc, out, sudo = Trap(self.script, self.proc, FAKE_COMM="sshd").run(signal.SIGTERM)
        self.assertEqual(rc, 143, out)
        self.assertEqual(conts(sudo), [], out)
        self.assertNotIn("kill -STOP", " ".join(sudo))
        self.assertIn("not resuming 4242: comm mismatch", out)

    def test_normal_run_clears_the_pid_so_exit_sends_no_second_cont(self):
        rc, out, sudo = Trap(self.script, self.proc).run(None)
        self.assertEqual(rc, 0, out)
        self.assertEqual(len(conts(sudo)), 1, out)  # the script's own RESUMED, nothing from the trap
        self.assertNotIn("[trap]", out)
        self.assertIn("RESUMED", out)


class MplsBrokerd(Mixin, unittest.TestCase):
    script, proc = "induce-drift-mpls.sh", "brokerd"


class McastVplaned(Mixin, unittest.TestCase):
    script, proc = "induce-drift-mcast.sh", "vplaned"


if __name__ == "__main__":
    unittest.main()
