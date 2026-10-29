#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-only
"""Turn a fixture's raw acceptance log into a *-result.json.

The accept-*.sh harnesses write the same JSON themselves at the end of a run.
When only the log survives (the run was cut short, or the JSON was lost), this
rebuilds it with the same schema -- and refuses any log it cannot account for:
no check lines, no summary line, a check name used twice, a summary that disagrees with the
per-check lines, or a Result section that disagrees with the live lines.

Log grammar (what record() prints):
    "  <STATUS>  <check name>[ -- <detail>]"     one per check, then
    "===== Result ====="                           an echo of names and statuses
    "  <N> of <M>"                                 the summary

Usage: fixture-log-to-result.py LOG --gate TEXT --image NAME [--out FILE]
                                [--timestamp ISO8601] [--read-only]
                                [--allow-missing-summary]
Exit: 0 written, 2 rejected (nothing is written).
"""

import argparse
import datetime
import json
import re
import sys

CHECK = re.compile(r"^  (PASS|FAIL|BLOCKED|SKIP)\s+(\S.*?)\s*$")
SUMMARY = re.compile(r"^  (\d+) of (\d+)\s*$")
RESULT_HDR = re.compile(r"^===== Result =====\s*$")


class Rejected(Exception):
    pass


def parse(text, allow_missing_summary=False):
    """Return [{"check","status","detail"}] after validating the log."""
    if not text.strip():
        raise Rejected("log is empty")
    live, echo, summaries = [], [], []
    in_result = False
    for raw in text.replace("\r", "").split("\n"):
        if RESULT_HDR.match(raw):
            in_result = True
            continue
        m = CHECK.match(raw)
        if m:
            status, rest = m.groups()
            name, _, detail = rest.partition(" -- ")
            row = {"check": name.strip(), "status": status, "detail": detail.strip()}
            (echo if in_result else live).append(row)
            continue
        m = SUMMARY.match(raw)
        if m:
            summaries.append((int(m[1]), int(m[2])))
    # With a Result section the echo is the authoritative list; the live lines
    # only contribute the detail text the echo drops.
    rows = echo or live
    if not rows:
        raise Rejected("no check lines")
    names = [r["check"] for r in rows]
    dups = sorted({n for n in names if names.count(n) > 1})
    if dups:
        raise Rejected("duplicate check name: " + "; ".join(dups))
    if echo and live:
        if [(r["check"], r["status"]) for r in live] != [(r["check"], r["status"]) for r in echo]:
            raise Rejected("Result section does not match the live check lines")
        for e, l in zip(echo, live):
            e["detail"] = e["detail"] or l["detail"]
    if not summaries and not allow_missing_summary:
        raise Rejected("no 'N of M' summary line (a truncated log?); --allow-missing-summary to accept")
    npass = sum(r["status"] == "PASS" for r in rows)
    for n, t in summaries:
        if (n, t) != (npass, len(rows)):
            raise Rejected(f"summary says {n} of {t}, check lines give {npass} of {len(rows)}")
    return rows


def build(rows, gate, image, timestamp, read_only):
    npass = sum(r["status"] == "PASS" for r in rows)
    return {
        "schema_version": 1, "read_only": read_only, "gate": gate,
        "image": image.rsplit("/", 1)[-1], "timestamp": timestamp,
        "passed": npass, "total": len(rows),
        "status": "PASS" if npass == len(rows) else "INCOMPLETE",
        "checks": rows,
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("log")
    ap.add_argument("--gate", required=True)
    ap.add_argument("--image", required=True)
    ap.add_argument("--out")
    ap.add_argument("--timestamp")
    ap.add_argument("--read-only", action="store_true")
    ap.add_argument("--allow-missing-summary", action="store_true",
                    help="accept a log with no 'N of M' line (default: reject, it may be truncated)")
    a = ap.parse_args(argv)
    try:
        with open(a.log, encoding="utf-8", errors="replace") as f:
            rows = parse(f.read(), a.allow_missing_summary)
    except (Rejected, OSError) as e:
        print(f"fixture-log-to-result: rejected: {e}", file=sys.stderr)
        return 2
    ts = a.timestamp or datetime.datetime.now(datetime.timezone.utc).isoformat()
    out = json.dumps(build(rows, a.gate, a.image, ts, a.read_only), indent=2)
    if a.out:
        with open(a.out, "w") as f:
            f.write(out)
    else:
        print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
