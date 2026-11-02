#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-only
"""drift_event_correlation_config_commits: every drift event that follows a configuration commit is tied to a commit.

Usage: judge-drift-event-correlation-config-commits.py <correlated.json> [--expect-commits N]

<correlated.json> output of dpa-drift-correlate.py (dpa-drift-history.py's events plus a correlated_commit per event), taken
                  from a scenario in which the only changes made were configuration commits
--expect-commits  the number of commits the scenario made; the distinct commits the events correlate to must be exactly that

PASS needs: at least one event; no event with correlated_commit null (an orphan means the correlation did not explain it);
every gap_seconds within the document's window_seconds and not negative (an event cannot precede its commit); and, when asked,
the right number of distinct commits.
"""
import sys
from judgelib import fail, need, passed, read_json, run


def main():
    args = sys.argv[1:]
    expect = None
    if "--expect-commits" in args:
        i = args.index("--expect-commits")
        expect = int(args[i + 1])
        del args[i:i + 2]
    if len(args) != 1:
        fail("usage: judge-drift-event-correlation-config-commits.py <correlated.json> [--expect-commits N]")
    doc = read_json(args[0], "correlated events")
    events = need(doc, "events", "correlated events")
    window = float(need(doc, "window_seconds", "correlated events"))
    if not events:
        fail("no events: nothing was correlated, so nothing was shown")
    commits = set()
    for e in events:
        c = e.get("correlated_commit")
        if not c:
            fail("orphan event %s %s %s: correlated_commit is null (%s)" % (e.get("class"), e.get("vrf"), e.get("prefix"), e.get("correlation_note") or e.get("reason") or "no reason given"))
        gap = c.get("gap_seconds")
        if gap is None or gap < 0 or gap > window:
            fail("event %s: gap_seconds %r is outside 0..%s" % (e.get("prefix"), gap, window))
        commits.add(c.get("commit_timestamp") or c.get("timestamp") or c.get("event_timestamp") or repr(sorted(c.items())))
    if expect is not None and len(commits) != expect:
        fail("events correlate to %d distinct commit(s), the scenario made %d" % (len(commits), expect))
    passed("%d event(s), none orphaned, all within %ss of a commit, %d distinct commit(s)" % (len(events), window, len(commits)))


if __name__ == "__main__":
    run(main)
