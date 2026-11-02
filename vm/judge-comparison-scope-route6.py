#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-only
"""comparison_scope_route6: does dpa-drift compare IPv6 routes, and do the two sides agree on them?

Usage: judge-comparison-scope-route6.py <dpa-drift.json> <zebra-ipv6-routes.json> --prefix P [--prefix P ...]

<dpa-drift.json>         `dpa-drift.py --json` taken on a settled box (wait at least 10 s after the last config change)
<zebra-ipv6-routes.json> `vtysh -c 'show ipv6 route json'` from the same moment
--prefix                 IPv6 prefixes the scenario configured (static routes); each one is a witness that route6 is really
                         compared: it must be selected+installed in zebra and absent from every disagreement list.

PASS needs: a usable snapshot, route6 in coverage.compared, every witness prefix installed in zebra, no route6
disagreement of any kind (missing, extra, next-hop mismatch) other than objects the data plane owns by design.
"""
import sys
from judgelib import disagreements, drift_snapshot, fail, passed, read_json, run


def main():
    args = sys.argv[1:]
    prefixes = [args[i + 1] for i, a in enumerate(args) if a == "--prefix" and i + 1 < len(args)]
    files = [a for i, a in enumerate(args) if not a.startswith("--") and (i == 0 or args[i - 1] != "--prefix")]
    if len(files) != 2 or not prefixes:
        fail("usage: judge-comparison-scope-route6.py <dpa-drift.json> <zebra-ipv6.json> --prefix P [--prefix P ...] (at least one witness prefix is required)")
    d, compared = drift_snapshot(files[0])
    if "route6" not in compared:
        fail("route6 is not in coverage.compared (%s)" % ",".join(compared))
    zebra = read_json(files[1], "zebra ipv6 routes")
    if not isinstance(zebra, dict):
        fail("zebra ipv6 routes: not a prefix -> routes object")
    bad = disagreements(d, {"route6"})
    if bad:
        n, e = bad[0]
        fail("%d route6 disagreement(s); first: %s %s %s" % (len(bad), n, e.get("vrf"), e.get("prefix")))
    for p in prefixes:
        installed = [r for r in zebra.get(p, []) if r.get("selected") and r.get("installed")]
        if not installed:
            fail("witness %s is not selected+installed in zebra: the scenario did not put it in the desired side" % p)
    if int(d.get("matched", 0)) <= 0:
        fail("matched is %s: nothing was compared" % d.get("matched"))
    passed("route6 compared; %d witness prefix(es) installed in zebra and in no disagreement list; matched=%s" % (len(prefixes), d.get("matched")))


if __name__ == "__main__":
    run(main)
