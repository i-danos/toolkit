#!/usr/bin/env python3
"""Correlate dpa-drift-history.py's events against configd's own commit log.

P1 item 3: is a persistent disagreement explained by "a configuration commit
just changed something and the data plane hasn't caught up yet", or does it
have no such explanation at all? The state machine in dpa-drift.py already
tells stale_candidate/confirmed_stale apart from the five in-flight/reserved
classifications; this answers a different question about the same events --
not "is this still unexplained after N cycles" but "did something change
right before this first appeared."

The commit signal: journalctl -u configd already logs one line per completed
commit, "COMMIT: Commit OVERALL: <duration>", with a microsecond
__REALTIME_TIMESTAMP in its JSON form (-o json). Nothing new is plumbed here
either, same as dpa-drift.py's own opening note -- this exists because
configd already announces every commit's completion with a timestamp
precise enough to correlate against, and there was no need to read FRR's own
per-protocol commit-index.dat (checked: it exists, at
/var/lib/frr/commit-index.dat, but only records commits that touched
FRR-managed config, where configd's log covers every commit regardless of
which VCI component it touched).

Read-only, like dpa-drift-history.py: this takes an events.json (its output,
or an equivalent), queries the commit log, and adds a correlated_commit field
per event -- no verdict is drawn about whether a commit *justifies* the
disagreement, no action is taken.
"""
import json
import subprocess
import sys
from datetime import datetime, timezone

JOURNAL = ["sudo", "journalctl", "-u", "configd", "-o", "json", "--no-pager"]

# How far back before an event's first_timestamp a commit still counts as
# "this is probably why". Generous on purpose: the pipeline this project has
# measured before (zebra pushes, brokerd queues, the data plane programs) can
# itself take several seconds, and a commit that triggered a cascade of
# re-resolution downstream can lag further than the commit's own duration.
# Not tuned against a real slow-convergence case -- the arithmetic is
# straightforward interval matching, not a threshold this project has reason
# to believe is exactly right yet.
DEFAULT_WINDOW_SECONDS = 120


def commit_times():
    """[epoch_seconds, ...] for every "COMMIT: Commit OVERALL" line, sorted.

    None (not []) when the journal itself could not be read at all, so a
    caller can tell "queried, no commits in range" from "could not query" --
    the same distinction dpa-drift.py's own unreadable side keeps for exactly
    this reason.
    """
    try:
        p = subprocess.run(JOURNAL, capture_output=True, text=True, timeout=60)
    except (subprocess.TimeoutExpired, OSError):
        return None
    if p.returncode != 0:
        return None
    out = []
    for line in p.stdout.splitlines():
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not row.get("MESSAGE", "").startswith("COMMIT: Commit OVERALL:"):
            continue
        ts = row.get("__REALTIME_TIMESTAMP")
        if ts is None:
            continue
        out.append(int(ts) / 1_000_000)
    out.sort()
    return out


def nearest_before(times, when, window):
    """Latest entry in `times` at or before `when`, within `window` seconds.

    None if nothing qualifies -- either nothing precedes `when` at all, or
    the closest one is further back than `window` allows.
    """
    best = None
    for t in times:
        if t <= when and (best is None or t > best):
            best = t
    if best is None or when - best > window:
        return None
    return best


def event_timestamp(e):
    """The wall-clock moment an event is judged against.

    "active"/"resolved" events (dpa-drift-history.py's normal output) carry
    first_timestamp -- correlating at onset, not at whatever cycle happens to
    be current, because onset is the moment a commit would explain. The rarer
    "unreadable" event type carries a bare "timestamp" instead; both are ISO
    8601 with a UTC offset, as dpa-drift.py itself writes them.
    """
    ts = e.get("first_timestamp", e.get("timestamp"))
    if ts is None:
        return None
    try:
        return datetime.fromisoformat(ts).timestamp()
    except ValueError:
        return None


def correlate(events_doc, window):
    times = commit_times()
    out = []
    for e in events_doc.get("events", []):
        e = dict(e)
        when = event_timestamp(e)
        if times is None:
            e["correlated_commit"] = None
            e["correlation_note"] = "commit log unreadable (journalctl -u configd failed)"
        elif when is None:
            e["correlated_commit"] = None
            e["correlation_note"] = "event has no usable timestamp"
        else:
            nearest = nearest_before(times, when, window)
            if nearest is None:
                e["correlated_commit"] = None
                e["correlation_note"] = (
                    "no commit in the log" if not times else
                    f"nearest commit is more than {window}s before this event started"
                )
            else:
                e["correlated_commit"] = {
                    "commit_timestamp": datetime.fromtimestamp(
                        nearest, tz=timezone.utc).isoformat(),
                    "gap_seconds": round(when - nearest, 3),
                }
        out.append(e)
    return out


def main():
    if len(sys.argv) < 2:
        raise SystemExit(
            "usage: dpa-drift-correlate.py <events.json> [--window SECONDS]")
    window = DEFAULT_WINDOW_SECONDS
    if "--window" in sys.argv:
        window = float(sys.argv[sys.argv.index("--window") + 1])

    with open(sys.argv[1]) as f:
        events_doc = json.load(f)

    out = correlate(events_doc, window)
    print(json.dumps({
        "schema_version": 1,
        "window_seconds": window,
        "events": out,
        "read_only": True,
    }, indent=2))


if __name__ == "__main__":
    main()
