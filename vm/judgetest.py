# SPDX-License-Identifier: LGPL-2.1-only
"""Helpers for test_judge_*.py: run a judge script the way the orchestrator would and read its one-line verdict."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
DATA = HERE / "testdata" / "judge"


def judge(script, *args):
    r = subprocess.run([sys.executable, str(HERE / script), *map(str, args)], capture_output=True, text=True)
    lines = r.stdout.strip().splitlines()
    return r.returncode, (lines[-1] if lines else "")


class JudgeCase(unittest.TestCase):
    script = None

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(self.tmp, ignore_errors=True))

    def write(self, name, obj):
        p = self.tmp / name
        p.write_text(obj if isinstance(obj, str) else json.dumps(obj))
        return p

    def run_judge(self, *args):
        return judge(self.script, *args)

    def assertPass(self, *args):
        rc, line = self.run_judge(*args)
        self.assertEqual((rc, line[:5]), (0, "PASS:"), line)
        return line

    def assertFail(self, *args, contains=""):
        rc, line = self.run_judge(*args)
        self.assertEqual((rc, line[:5]), (1, "FAIL:"), line)
        self.assertIn(contains, line)
        return line


def drift(compared=("route", "route6"), matched=3, missing=(), extra=(), nh_mismatch=(), keyspace=False, status="diagnostic"):
    """A dpa-drift.py --json result in the real schema (version 2); built from the field list of the real capture."""
    return {
        "status": status, "schema_version": 2,
        "coverage": {"enumerable": list(compared), "not_enumerable": [], "compared": list(compared), "not_compared": []},
        "desired": matched + len(missing), "programmed": matched + len(extra), "programmed_entries": matched + len(extra),
        "matched": matched,
        "desired_not_programmed": [{"class": c, "vrf": "default", "prefix": p, "classification": "observed"} for c, p in missing],
        "programmed_not_desired": [{"class": c, "vrf": "default", "prefix": p, "classification": "observed"} for c, p in extra],
        "kernel_local": [], "not_programmable": [], "dataplane_owned": [], "multi_entry": [],
        "keyspace_mismatch": keyspace,
        "next_hop_mismatch": [{"class": c, "vrf": "default", "prefix": p} for c, p in nh_mismatch],
        "next_hops_not_comparable": 0, "next_hops_not_reported": 0,
    }
