#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-only
"""drift_event_correlation_netlink: every drift event is tied to a netlink route message that preceded it.

Usage: judge-drift-event-correlation-netlink.py <correlated-netlink.json> [--expect-prefix P ...]

<correlated-netlink.json> output of dpa-drift-correlate-netlink.py, run while `vplsh -l -c 'debug nl_route'` was on for the whole
                          capture (without it the log has no RTM_*ROUTE lines and every event carries a note saying so)
--expect-prefix           prefixes the scenario changed; each must have an event, correlated to a netlink message

PASS needs: at least one event; none with correlated_netlink_route null (the note is quoted in the FAIL); each gap_seconds within
0..window_seconds; each verb one of RTM_NEWROUTE / RTM_DELROUTE; and every --expect-prefix present among the events.
"""
import sys
from judgelib import fail, need, passed, read_json, run

VERBS = {"RTM_NEWROUTE", "RTM_DELROUTE"}


def main():
    args = sys.argv[1:]
    prefixes = [args[i + 1] for i, a in enumerate(args) if a == "--expect-prefix" and i + 1 < len(args)]
    files = [a for i, a in enumerate(args) if not a.startswith("--") and (i == 0 or args[i - 1] != "--expect-prefix")]
    if len(files) != 1:
        fail("usage: judge-drift-event-correlation-netlink.py <correlated-netlink.json> [--expect-prefix P ...]")
    doc = read_json(files[0], "netlink-correlated events")
    events = need(doc, "events", "netlink-correlated events")
    window = float(need(doc, "window_seconds", "netlink-correlated events"))
    if not events:
        fail("no events: nothing was correlated")
    for e in events:
        n = e.get("correlated_netlink_route")
        if not n:
            fail("event %s has no netlink route: %s" % (e.get("prefix"), e.get("netlink_correlation_note") or "no note"))
        gap = n.get("gap_seconds")
        if gap is None or gap < 0 or gap > window:
            fail("event %s: gap_seconds %r is outside 0..%s" % (e.get("prefix"), gap, window))
        if n.get("verb") not in VERBS:
            fail("event %s: verb %r is not one of %s" % (e.get("prefix"), n.get("verb"), sorted(VERBS)))
    seen = {e.get("prefix") for e in events}
    for p in prefixes:
        if p not in seen:
            fail("expected prefix %s has no event" % p)
    passed("%d event(s), each tied to a netlink route message within %ss" % (len(events), window))


if __name__ == "__main__":
    run(main)
