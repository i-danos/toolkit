# SPDX-License-Identifier: LGPL-2.1-only
"""Shared plumbing for the judge-*.py scripts.

A judge reads what a fixture left behind and prints exactly one line, "PASS: <why>" or "FAIL: <why>", exiting 0 or 1.
The rules every judge shares, so that none of them can pass by default:

  * an input file that is missing, empty or unreadable is a FAIL that says so;
  * a JSON input that does not parse (a truncated capture) is a FAIL that says so;
  * a field the judge needs that is absent is a FAIL, never a skipped check.
"""
import json
import os
import sys


class Verdict(Exception):
    def __init__(self, verdict, reason):
        super().__init__(reason)
        self.verdict, self.reason = verdict, reason


def fail(reason):
    raise Verdict("FAIL", reason)


def passed(reason):
    raise Verdict("PASS", reason)


def read_text(path, what):
    if not os.path.isfile(path):
        fail("%s: input missing (%s)" % (what, path))
    try:
        with open(path, errors="replace") as f:
            text = f.read()
    except OSError as e:
        fail("%s: input unreadable (%s)" % (what, e))
    if not text.strip():
        fail("%s: input empty (%s)" % (what, path))
    return text


def read_json(path, what):
    """The whole file as JSON; failing that, its last line that starts with '{' (a capture that logged before the JSON)."""
    text = read_text(path, what)
    try:
        return json.loads(text)
    except ValueError:
        pass
    for line in reversed(text.splitlines()):
        if line.lstrip().startswith("{"):
            try:
                return json.loads(line)
            except ValueError:
                break
    fail("%s: input truncated or not JSON (%s)" % (what, path))


def need(obj, key, what):
    if not isinstance(obj, dict) or key not in obj:
        fail("%s: field '%s' missing" % (what, key))
    return obj[key]


def run(main):
    try:
        main()
    except Verdict as v:
        print("%s: %s" % (v.verdict, v.reason))
        sys.exit(0 if v.verdict == "PASS" else 1)
    except SystemExit:
        raise
    except Exception as e:  # a judge that crashes must not read as a pass
        print("FAIL: judge error: %s: %s" % (type(e).__name__, e))
        sys.exit(1)
    print("FAIL: judge ended without a verdict")
    sys.exit(1)


def drift_snapshot(path, what="dpa-drift --json"):
    """A dpa-drift.py --json result that is usable at all: diagnostic status, schema 2, no key-space mismatch."""
    d = read_json(path, what)
    if need(d, "status", what) != "diagnostic":
        fail("%s: status is %r, not 'diagnostic' (a side was unreadable)" % (what, d.get("status")))
    if int(need(d, "schema_version", what)) < 2:
        fail("%s: schema_version %s is older than 2" % (what, d.get("schema_version")))
    if need(d, "keyspace_mismatch", what):
        fail("%s: keyspace_mismatch is true: the two sides do not use the same identity, so no comparison happened" % what)
    cov = need(d, "coverage", what)
    return d, list(need(cov, "compared", what + " coverage"))


def disagreements(d, classes, allowed=("reserved_owned", "source_mismatch")):
    """[(list-name, entry)] for entries of the given classes that are real disagreements.

    desired_not_programmed and programmed_not_desired entries count unless their classification says the data
    plane owns the object by design. next_hop_mismatch entries always count.
    """
    out = []
    for name in ("desired_not_programmed", "programmed_not_desired"):
        for e in d.get(name, []) or []:
            if e.get("class") in classes and e.get("classification") not in allowed:
                out.append((name, e))
    for e in d.get("next_hop_mismatch", []) or []:
        if (e.get("class") if isinstance(e, dict) else None) in classes:
            out.append(("next_hop_mismatch", e))
    return out
