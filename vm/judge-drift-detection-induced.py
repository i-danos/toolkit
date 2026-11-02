#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-only
"""drift_detection_induced: a deviation that was injected is detected, under the right key, and clears when the injection stops.

Usage: judge-drift-detection-induced.py <before.json> <during.json> <after.json> --key CLASS:VRF:PREFIX [--key ...]

The three files are `dpa-drift.py --json` snapshots of the same router: before the injection (induce-drift-*.sh not yet run),
while the delivery process is stopped and the scenario's change has been made, and after it was resumed and settled.
--key names what the injection must have produced, as the comparison would key it (for example route:default:10.91.0.0/24).

PASS needs, for every --key: absent from before (a clean baseline), present in during's desired_not_programmed (detected, under
exactly that class/vrf/prefix, not merely "some drift"), and absent from after (the deviation cleared and was not left behind).
"""
import sys
from judgelib import drift_snapshot, fail, passed, run


def keys_of(d, lists=("desired_not_programmed", "programmed_not_desired")):
    out = {}
    for name in lists:
        for e in d.get(name, []) or []:
            out.setdefault((e.get("class"), e.get("vrf"), e.get("prefix")), name)
    return out


def main():
    args = sys.argv[1:]
    keys = [args[i + 1] for i, a in enumerate(args) if a == "--key" and i + 1 < len(args)]
    files = [a for i, a in enumerate(args) if not a.startswith("--") and (i == 0 or args[i - 1] != "--key")]
    if len(files) != 3 or not keys:
        fail("usage: judge-drift-detection-induced.py <before.json> <during.json> <after.json> --key CLASS:VRF:PREFIX [...] (at least one key)")
    snaps = [drift_snapshot(f, w)[0] for f, w in zip(files, ("before", "during", "after"))]
    b, d, a = (keys_of(s) for s in snaps)
    for k in keys:
        try:
            cls, vrf, prefix = k.split(":", 2)
        except ValueError:
            fail("--key %r is not CLASS:VRF:PREFIX" % k)
        t = (cls, vrf, prefix)
        if t in b:
            fail("baseline is not clean: %s already disagrees before the injection" % k)
        if t not in d:
            fail("injected deviation %s was not detected (during snapshot lists %d other disagreement(s))" % (k, len(d)))
        if t in a:
            fail("deviation %s is still reported after the injection stopped" % k)
    passed("%d injected deviation(s) clean before, detected under the right key during, cleared after" % len(keys))


if __name__ == "__main__":
    run(main)
