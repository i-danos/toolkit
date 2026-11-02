#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-only
"""comparison_scope_mcast: multicast routes (IPv4 and IPv6) are compared, and after SSM/PIM6 forwarding the sides agree.

Usage: judge-comparison-scope-mcast.py <dpa-drift.json> <verify-multicast-forwarding.log>

<dpa-drift.json>  `dpa-drift.py --json` taken on the RP/transit router (R2) after verify-multicast-forwarding.sh, settled
<log>             raw output of verify-multicast-forwarding.sh (it prints no PASS/FAIL of its own)

PASS needs: a usable snapshot, mroute and mroute6 both in coverage.compared, no mroute/mroute6 disagreement, the log complete
('===== Done ====='), the IPv4 forwarding entry showing packets > 0 with wrong_if = 0, and the IPv6 section showing packets > 0.
"""
import re
import sys
from judgelib import disagreements, drift_snapshot, fail, passed, read_text, run


def main():
    if len(sys.argv) != 3:
        fail("usage: judge-comparison-scope-mcast.py <dpa-drift.json> <verify-multicast-forwarding.log>")
    d, compared = drift_snapshot(sys.argv[1])
    for c in ("mroute", "mroute6"):
        if c not in compared:
            fail("%s is not in coverage.compared (%s)" % (c, ",".join(compared)))
    bad = disagreements(d, {"mroute", "mroute6"})
    if bad:
        n, e = bad[0]
        fail("%d multicast disagreement(s); first: %s %s %s" % (len(bad), n, e.get("class"), e.get("prefix")))
    log = read_text(sys.argv[2], "multicast forwarding log")
    if "===== Done =====" not in log:
        fail("log has no '===== Done =====' line: the run was cut short")
    v4 = re.findall(r"packets=(\d+) bytes=\d+ wrong_if=(\d+)", log)
    if not v4:
        fail("no IPv4 fcstat line (packets=… wrong_if=…) in the log")
    if not any(int(p) > 0 and int(w) == 0 for p, w in v4):
        fail("IPv4 forwarding: no entry with packets > 0 and wrong_if = 0 (%s)" % v4)
    part = log.split("===== 10.", 1)
    if len(part) < 2:
        fail("log has no IPv6 'after sending' section (section 10)")
    v6 = [int(x) for x in re.findall(r'"packets"\s*:\s*(\d+)', part[1])]
    if not any(x > 0 for x in v6):
        fail("IPv6 forwarding: no fcstat6 packet count above 0 in section 10 (%s)" % v6)
    if int(d.get("matched", 0)) <= 0:
        fail("matched is %s: nothing was compared" % d.get("matched"))
    passed("mroute and mroute6 compared, no disagreement; IPv4 forwarded %s, IPv6 saw packets" % [p for p, _ in v4])


if __name__ == "__main__":
    run(main)
