#!/usr/bin/env python3
"""Correlate dpa-drift-history.py's events against the dataplane's own
netlink route log.

The rest of P1 item 3. dpa-drift-correlate.py answers "did a config commit
happen right before this" from configd's log, which is on by default. This
answers "did the dataplane actually see a netlink route add/delete for this
exact prefix" -- a stronger, more specific signal, but one that turned out to
be gated: vyatta-dataplane logs "ROUTE: RTM_NEWROUTE/RTM_DELROUTE ... dst
<prefix> ..." lines (one per netlink route event, syslog local6, readable via
journalctl -u vyatta-dataplane -o json for a precise __REALTIME_TIMESTAMP),
but only once its "nl_route" debug category is turned on -- off by default
(checked live: `vplsh -c debug` on an untouched box reports
{"0x13":["init","link","nl_interface"]}, no nl_route).

Checked before writing this, not assumed: `vplsh -c 'debug nl_route'` turns
the category on at runtime, no restart, and `vplsh -c 'debug -nl_route'`
turns it back off just as cleanly -- confirmed both ways on a live box, a
real route committed with the flag on produced exactly the RTM_NEWROUTE line
this parses, and turning the flag off afterwards left the debug set exactly
as it started (0x13). So the signal is "already there" in the same sense
configd's commit log was, just off by default -- enabling it is this
project's decision to make, not a design this script imposes, which is why
enabling and disabling it live outside this script rather than inside it:
a read-only correlator has no business changing what the dataplane logs.

Correlates by *prefix*, not by VRF -- the netlink log line carries a routing
table number, not a VRF name, and mapping tables back to VRF names reliably
is exactly the kind of guess dpa-drift.py's own key-space guard exists to
avoid making. A prefix match across all tables is looser than an exact
(vrf, prefix) match would be, and is stated as a limitation rather than
silently assumed away.
"""
import json
import re
import subprocess
import sys
from datetime import datetime, timezone

JOURNAL = ["sudo", "journalctl", "-u", "vyatta-dataplane", "-o", "json", "--no-pager"]

ROUTE_LINE = re.compile(
    r"^ROUTE: RTM_(?P<verb>NEWROUTE|DELROUTE) table (?P<table>\d+) "
    r"type (?P<type>\S+) dst (?P<prefix>\S+) ")

# Same rationale as dpa-drift-correlate.py's window: generous against a
# pipeline already measured to take several seconds end to end.
DEFAULT_WINDOW_SECONDS = 120


def netlink_route_events():
    """[(epoch_seconds, verb, table, prefix), ...] sorted, or None if unreadable.

    None means the journal itself could not be read -- distinct from an
    empty list, which means it read fine and simply found no RTM_*ROUTE
    lines (most likely because nl_route debug was never turned on for this
    capture window).
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
        m = ROUTE_LINE.match(row.get("MESSAGE", ""))
        if not m:
            continue
        ts = row.get("__REALTIME_TIMESTAMP")
        if ts is None:
            continue
        out.append((int(ts) / 1_000_000, m.group("verb"), m.group("table"),
                     m.group("prefix")))
    out.sort()
    return out


def nearest_before(events, prefix, when, window):
    """Latest (verb, table) for `prefix` at or before `when`, within `window`."""
    best = None
    for t, verb, table, p in events:
        if p != prefix or t > when:
            continue
        if best is None or t > best[0]:
            best = (t, verb, table)
    if best is None or when - best[0] > window:
        return None
    return best


def event_timestamp(e):
    ts = e.get("first_timestamp", e.get("timestamp"))
    if ts is None:
        return None
    try:
        return datetime.fromisoformat(ts).timestamp()
    except ValueError:
        return None


def correlate(events_doc, window):
    nl = netlink_route_events()
    out = []
    for e in events_doc.get("events", []):
        e = dict(e)
        prefix = e.get("prefix")
        when = event_timestamp(e)
        if nl is None:
            e["correlated_netlink_route"] = None
            e["netlink_correlation_note"] = (
                "journalctl -u vyatta-dataplane unreadable")
        elif not nl:
            e["correlated_netlink_route"] = None
            e["netlink_correlation_note"] = (
                "no RTM_*ROUTE lines in the log -- nl_route debug was "
                "likely not enabled for this capture window "
                "(vplsh -c 'debug nl_route')")
        elif prefix is None or when is None:
            e["correlated_netlink_route"] = None
            e["netlink_correlation_note"] = "event has no usable prefix/timestamp"
        else:
            best = nearest_before(nl, prefix, when, window)
            if best is None:
                e["correlated_netlink_route"] = None
                e["netlink_correlation_note"] = (
                    f"no RTM_*ROUTE for {prefix} within {window}s before "
                    "this event started")
            else:
                t, verb, table = best
                e["correlated_netlink_route"] = {
                    "verb": verb,
                    "table": table,
                    "event_timestamp": datetime.fromtimestamp(
                        t, tz=timezone.utc).isoformat(),
                    "gap_seconds": round(when - t, 3),
                }
        out.append(e)
    return out


def main():
    if len(sys.argv) < 2:
        raise SystemExit(
            "usage: dpa-drift-correlate-netlink.py <events.json> [--window SECONDS]")
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
