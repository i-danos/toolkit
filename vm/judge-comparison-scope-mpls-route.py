#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-only
"""comparison_scope_mpls_route: MPLS label routes are compared, and after an L3VPN comes up the two sides agree.

Usage: judge-comparison-scope-mpls-route.py <dpa-drift.json> <verify-l3vpn.log> --label N [--label N ...]

<dpa-drift.json>   `dpa-drift.py --json` taken on PE1 or the P router after verify-l3vpn.sh, once settled
<verify-l3vpn.log> the raw output of verify-l3vpn.sh (it prints no PASS/FAIL of its own)
--label            labels the scenario is known to install (from "show mpls table"); each must appear in the log

PASS needs: a usable snapshot, mpls-route in coverage.compared, no mpls-route disagreement (reserved labels the data plane
owns by design excepted), every named label present in the log, and the log's forwarding step showing every probe answered.
"""
import re
import sys
from judgelib import disagreements, drift_snapshot, fail, passed, read_text, run


def main():
    args = sys.argv[1:]
    labels = [args[i + 1] for i, a in enumerate(args) if a == "--label" and i + 1 < len(args)]
    files = [a for i, a in enumerate(args) if not a.startswith("--") and (i == 0 or args[i - 1] != "--label")]
    if len(files) != 2 or not labels:
        fail("usage: judge-comparison-scope-mpls-route.py <dpa-drift.json> <verify-l3vpn.log> --label N [--label N ...] (at least one label is required)")
    d, compared = drift_snapshot(files[0])
    if "mpls-route" not in compared:
        fail("mpls-route is not in coverage.compared (%s)" % ",".join(compared))
    bad = disagreements(d, {"mpls-route"})
    if bad:
        n, e = bad[0]
        fail("%d mpls-route disagreement(s); first: %s %s" % (len(bad), n, e.get("prefix")))
    log = read_text(files[1], "verify-l3vpn log")
    if "===== Done =====" not in log:
        fail("verify-l3vpn log has no '===== Done =====' line: the run was cut short")
    for lab in labels:
        if not re.search(r"(?<![0-9])%s(?![0-9])" % re.escape(lab), log):
            fail("label %s does not appear in the verify-l3vpn log" % lab)
    sec = log.split("===== 6. Forwarding", 1)
    if len(sec) < 2:
        fail("verify-l3vpn log has no forwarding section")
    m = re.search(r"(\d+) packets transmitted, (\d+) (?:packets )?received", sec[1])
    if not m or int(m.group(1)) == 0 or m.group(1) != m.group(2):
        fail("forwarding step: %s" % (m.group(0) if m else "no ping summary line"))
    if int(d.get("matched", 0)) <= 0:
        fail("matched is %s: nothing was compared" % d.get("matched"))
    passed("mpls-route compared, no disagreement; labels %s in the log; ping %s/%s answered" % (",".join(labels), m.group(2), m.group(1)))


if __name__ == "__main__":
    run(main)
