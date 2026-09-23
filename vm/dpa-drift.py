#!/usr/bin/env python3
"""Compare what was asked for against what is programmed.

Usage: dpa-drift.py [--json]
       dpa-drift.py --watch <seconds> [--cycles N] [--json]
                     [--stale-after N] [--confirm-after N]

Desired is zebra's RIB, read with "vtysh -c 'show ip route json'".
Programmed is the data plane's object view, "vplsh -c 'dpa object show route'".

Both run on the box, because both views are only readable there. Nothing new is
plumbed: this exists precisely because the comparison turned out not to need
any. An earlier plan assumed the data plane would have to read zebra, and a
later one assumed brokerd was the natural place to compare -- brokerd keeps
only objects it has not yet delivered, deleting each on delivery, so it holds
no desired state at all.

Two things decide whether this is right or merely plausible.

**"In the RIB" is not "asked for."** zebra keeps every route it has learned,
including the ones that lost the distance contest. Only entries with both
`selected` and `installed` were actually pushed downstream, and comparing
against the rest would report drift for routes that were never meant to be
programmed. That distinction is not cosmetic: it is most of the RIB on a box
running several protocols.

**A key-space mismatch must not read as total drift.** Both sides key on the
VRF *name*, and the first version did not -- it compared numeric ids, and the
numbers are separate namespaces that merely happen to both be integers. DANOS's
default VRF is VRF_DEFAULT_ID (1), zebra's is 0, and for non-default VRFs one
is the operator's id while the other is zebra's own numbering.

The guard caught it on a healthy box: four desired routes, six programmed, the
same prefixes, the same table, and zero matches. Reported as drift that would
have read as the data plane having lost its entire route table and grown six
stale entries. Reported as a key-space mismatch it says what it is, and the fix
was to key on the name at both ends.

The guard stays, because the failure it catches is the one this tool is most
likely to have and the one that would be most convincing if it were reported
wrong.
"""

import json
import subprocess
import sys
import time
from datetime import datetime, timezone

# "vrf all", not the default VRF alone.
#
# The Programmed side sees every VRF the data plane holds. Asking zebra about
# one of them does not make the others invisible -- it makes their routes
# appear as "programmed but not desired", which is a false drift report for
# every route in every non-default VRF. Measured on a box with one routing
# instance: three ordinary routes reported as programmed-and-unwanted.
VTYSH = ["sudo", "vtysh", "-c", "show ip route vrf all json"]
VPLSH = ["sudo", "/opt/vyatta/bin/vplsh", "-l", "-c", "dpa object show route"]
VPLSH_CLASSES = ["sudo", "/opt/vyatta/bin/vplsh", "-l", "-c", "dpa object show"]

# The only class compared. The object view enumerates six.
#
# Stated because "clean" would otherwise be read as "everything programmed was
# checked", and it is one class of six. That is the same shape as the VRF gap
# this tool had until it was measured: a scope smaller than the report implies,
# invisible in the numbers.
#
# route6 has a Desired source and is not yet wired. mpls-route, mroute and
# mroute6 have one -- "show mpls table json", "show ip mroute json", "show ipv6
# mroute json" all answer -- but each needs a topology that exercises it before
# a comparison can be verified rather than merely written. "show vrf" has no
# JSON form at all.
COMPARED = {"route"}


def run(cmd):
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    if p.returncode != 0 or not p.stdout.strip():
        return None
    try:
        return json.loads(p.stdout)
    except json.JSONDecodeError:
        return None


def desired():
    """(vrf_name, table, prefix) for every route zebra actually pushed down.

    "show ip route vrf all json" nests by VRF name, where the single-VRF form
    is a flat map of prefixes. Both shapes are accepted so the tool works
    against either, and so that an image or FRR that answers the old shape does
    not silently produce an empty Desired side -- which would read as every
    route having drifted.
    """
    rib = run(VTYSH)
    if rib is None:
        return None
    # Flatten {vrf: {prefix: [...]}} and {prefix: [...]} to one prefix map.
    flat = {}
    for k, v in rib.items():
        if isinstance(v, dict):
            for prefix, entries in v.items():
                flat.setdefault(prefix, []).extend(entries)
        elif isinstance(v, list):
            flat.setdefault(k, []).extend(v)
    out = {}
    for prefix, entries in flat.items():
        for e in entries:
            # The whole point: only what was selected *and* installed.
            if not (e.get("selected") and e.get("installed")):
                continue
            # vrfName, not vrfId. The numbers are separate namespaces --
            # DANOS's default VRF is 1 and zebra's is 0 -- and comparing them
            # made every route on a healthy box look like drift.
            # (vrf, prefix). The table is deliberately not in the compared
            # key.
            #
            # "table 254 in VRF RED" and "table 256 in vrfRED" are the same
            # table: DANOS numbers a table per VRF and each VRF's main table is
            # 254, while the kernel numbers them globally and gives vrfRED 256.
            # Comparing the numbers reports every route in every non-default
            # VRF as drift, which is what was measured before this changed.
            # The number is kept as an attribute so it can still be read.
            out[(e.get("vrfName", "default"), prefix)] = {
                "protocol": e.get("protocol", "?"),
                "table": e.get("table"),
                "scope": e.get("scope"),
                "next_hop_group": e.get("nexthopGroup", e.get("nextHopGroup")),
                "source": e.get("source", e.get("protocol", "?")),
            }
    return out


def programmed():
    """(vrf_name, table, prefix) -> list of programmed entries.

    A *list*, because the data plane can legitimately hold more than one entry
    for one compared key. Its LPM keys on (prefix, depth, scope) and the
    Desired side has no comparable notion of scope, so the key carries the
    scope and this splits it off before comparing.

    The first version used a dict and lost whichever entry came second. Eight
    objects arrived as six, `matched 4` looked entirely normal, and the two
    that vanished were the reserved reject default and zebra's real default
    sharing a prefix. A comparison that silently drops objects cannot be the
    basis for repairing them, which is why the duplicate-key guard was written
    before it had ever fired -- and it fired on its first run against a real
    box.
    """
    doc = run(VPLSH)
    if doc is None:
        return None
    out = {}
    for o in doc.get("dpa_objects", {}).get("objects", []):
        # "vrf:default/table:254/10.73.0.0/24/scope:0"
        parts = o["key"].split("/")
        if len(parts) < 3 or not parts[0].startswith("vrf:"):
            continue
        vrf = parts[0][4:]
        table = int(parts[1][6:])
        scope = None
        body = parts[2:]
        if body and body[-1].startswith("scope:"):
            scope = int(body[-1][6:])
            body = body[:-1]
        prefix = "/".join(body)
        # Absent is not False.
        #
        # An image built before the data plane reported ownership has no such
        # field, and defaulting it to False turns "this image cannot say" into
        # "this object is not owned" -- which then reports every reserved route
        # as drift. That is the same confusion the producing side avoids by
        # emitting the field on every object, reintroduced here by a default
        # argument. None means unknown and is handled as its own case.
        out.setdefault((vrf, prefix), []).append(
            {"table": table, "scope": scope, "state": o.get("state"),
             "backend": o.get("backend"),
             "owned": o.get("dataplane_owned"),
             "protocol": o.get("protocol"),
             "source": o.get("source"),
             "next_hop_group": o.get("nexthop_group", o.get("next_hop_group")),
             "dependencies": o.get("dependencies", [])})
    return out


def ownership_known(p):
    """Does this image's object view report ownership at all?"""
    return any(e["owned"] is not None for v in p.values() for e in v)


def unowned(p, k):
    """True when every entry under k is known *not* to be dataplane-owned.

    Unknown counts as not-drift rather than as drift. On an image that cannot
    say, the honest answer is to report nothing rather than to report the
    reserved routes as missing objects -- an over-report here would be acted on
    by whatever reads it.
    """
    return all(e["owned"] is False for e in p[k])


def classify_extra(p, k, cov):
    """Why a programmed-not-desired key is programmed, if there's a reason.

    Five of this project's eight named drift states are "this is programmed,
    and here is the legitimate reason it isn't upstream" -- computed once
    here, not duplicated between the single-snapshot comparison in main() and
    the persistence-tracking state machine in watch(). Returns one of:

        reserved_owned        the data plane made this for itself
        transient_in_flight   PARTIAL or NOT_NEEDED -- a program still moving
        unsupported_or_unreadable
                               NO_RESOURCE/NO_SUPPORT, or this object's class
                               is not enumerable on this image at all
        next_hop_dependency   waiting on something else to program first
        source_mismatch       none of the above -- programmed for a reason
                               this tool cannot see, which is itself the
                               category: not explained, but not yet a
                               candidate for "gone missing" either, since it
                               unambiguously *is* there
    """
    if unowned(p, k):
        return "reserved_owned"
    e = p[k][0]
    if e["state"] in ("PARTIAL", "NOT_NEEDED"):
        return "transient_in_flight"
    if e["state"] in ("NO_RESOURCE", "NO_SUPPORT"):
        return "unsupported_or_unreadable"
    if e["dependencies"]:
        return "next_hop_dependency"
    return "source_mismatch"


def classify_missing(cov):
    """Why a desired-not-programmed key might not be programmed yet.

    The programmed side has nothing under this key at all -- no DPA state to
    read a reason from, unlike classify_extra(). "unsupported_or_unreadable"
    is the one reason this function *can* still give, when the route class
    itself isn't enumerable on this image; every other case starts as plain
    "observed" and it is the state machine's job, not a single snapshot's, to
    tell a route still in flight from one that is never coming.
    """
    if cov and "route" not in cov.get("enumerable", []):
        return "unsupported_or_unreadable"
    return "observed"


def coverage():
    """Which object classes exist, and which of them this compares."""
    doc = run(VPLSH_CLASSES)
    if doc is None:
        return None
    classes = doc.get("dpa_objects", {}).get("classes", [])
    have = [c["class"] for c in classes if c.get("enumerable")]
    unavailable = [c["class"] for c in classes if not c.get("enumerable")]
    return {"enumerable": have, "not_enumerable": unavailable,
            "compared": sorted(COMPARED & set(have)),
            "not_compared": sorted(set(have) - COMPARED)}


def main():
    as_json = "--json" in sys.argv

    d = desired()
    p = programmed()

    if d is None:
        if as_json:
            print(json.dumps({"status": "unreadable", "unreadable": ["desired"],
                              "reason": "vtysh returned no valid JSON"}))
        else:
            print("UNREADABLE desired (vtysh)", file=sys.stderr)
        return 2
    if p is None:
        if as_json:
            print(json.dumps({"status": "unreadable", "unreadable": ["programmed"],
                              "reason": "vplsh dpa object show returned no valid JSON"}))
        else:
            print("UNREADABLE programmed (vplsh dpa object show)", file=sys.stderr)
        return 2

    matched = sorted(set(d) & set(p))
    missing = sorted(set(d) - set(p))

    # Objects the data plane made for itself -- the reserved routes, 127/8 and
    # 255.255.255.255/32 and the reject default. They are correctly absent
    # upstream, so they are not drift, and a reconciliation loop that treated
    # them as drift would try to repair them by asking zebra for routes zebra
    # was never going to have. The data plane says which they are; this does
    # not carry its own list of prefixes it believes are special.
    #
    # A key is "owned" only if *every* entry under it is. One prefix can carry
    # a reserved entry and a real one at different scopes -- 0.0.0.0/0 does --
    # and calling the whole key owned would hide a real route behind a
    # reserved one.
    extra = sorted(k for k in set(p) - set(d) if unowned(p, k))
    owned = sorted(k for k in set(p) - set(d) if not unowned(p, k))

    # The guard. Nothing in common while both sides hold routes means the two
    # identity schemes disagree, not that the data plane lost everything.
    keyspace_broken = bool(d) and bool(p) and not matched

    cov = coverage()
    result = {
        "status": "diagnostic",
        "schema_version": 2,
        "coverage": cov,
        "desired": len(d),
        "programmed": len(p),
        "programmed_entries": sum(len(v) for v in p.values()),
        "matched": len(matched),
        "desired_not_programmed": [
            {"vrf": k[0], "prefix": k[1], "protocol": d[k]["protocol"],
             "table": d[k]["table"], "scope": d[k]["scope"],
             "next_hop_group": d[k]["next_hop_group"], "source": d[k]["source"],
             "classification": classify_missing(cov)}
            for k in missing
        ],
        "programmed_not_desired": [
            {"vrf": k[0], "prefix": k[1],
             "state": p[k][0]["state"], "backend": p[k][0]["backend"],
             "table": p[k][0]["table"],
             "scope": p[k][0]["scope"],
             "next_hop_group": p[k][0]["next_hop_group"],
             "protocol": p[k][0]["protocol"],
             "source": p[k][0]["source"],
             "dependencies": p[k][0]["dependencies"],
             "classification": classify_extra(p, k, cov)}
            for k in extra
        ],
        "dataplane_owned": [
            {"vrf": k[0], "prefix": k[1], "classification": "source_mismatch"}
            for k in owned
        ],
        # No longer a fault: more than one entry under a compared key is a
        # legitimate state the data plane can be in. Reported so that the
        # count on each side is explainable rather than merely consistent.
        "multi_entry": [
            {"vrf": k[0], "prefix": k[1],
             "scopes": sorted(e["scope"] for e in p[k] if e["scope"] is not None)}
            for k in sorted(p) if len(p[k]) > 1
        ],
        "keyspace_mismatch": keyspace_broken,
    }

    if as_json:
        print(json.dumps(result))
    else:
        print("desired %d  programmed %d keys / %d entries  matched %d" %
              (result["desired"], result["programmed"],
               result["programmed_entries"], result["matched"]))
        if cov and cov["not_compared"]:
            print("  scope: comparing %s; NOT compared: %s"
                  % (", ".join(cov["compared"]),
                     ", ".join(cov["not_compared"])))
        if keyspace_broken:
            print("KEY SPACE MISMATCH: the two sides share no identity, which "
                  "is a formatting disagreement rather than drift")
            for k in sorted(d)[:3]:
                print("  desired    %s" % (k,))
            for k in sorted(p)[:3]:
                print("  programmed %s" % (k,))
        else:
            for e in result["desired_not_programmed"]:
                print("  DESIRED NOT PROGRAMMED  vrf:%(vrf)s/%(prefix)s  "
                      "from %(protocol)s, zebra table %(table)s" % e)
            for e in result["programmed_not_desired"]:
                print("  PROGRAMMED NOT DESIRED  vrf:%(vrf)s/%(prefix)s  "
                      "%(state)s on %(backend)s, dp table %(table)s" % e)
            for e in result["dataplane_owned"]:
                print("  dataplane-owned, not drift  vrf:%(vrf)s/%(prefix)s"
                      % e)
        for e in result["multi_entry"]:
            print("  %d entries under one key  vrf:%s/%s  scopes %s"
                  % (len(e["scopes"]), e["vrf"], e["prefix"], e["scopes"]))

    if keyspace_broken:
        return 3
    return 1 if (missing or extra) else 0


# Classifications that already have an explanation. An item carrying one of
# these is not "unexplained absence/presence waiting to be judged" -- it is
# accounted for, and it stays whatever it is for as long as the classifier
# keeps saying so. Only the residual category, "observed" (nothing about it
# explains why it disagrees), is eligible to be promoted toward
# confirmed_stale -- that is the whole point of naming the other five:
# separating "drift" from "drift-shaped but actually fine" before a
# persistence counter ever runs, not after.
EXPLAINED = {"reserved_owned", "transient_in_flight", "unsupported_or_unreadable",
             "next_hop_dependency", "source_mismatch"}


def advance_state(prior, classification, stale_after, confirm_after):
    """One item's state machine, one cycle.

    prior is None (never seen before) or the dict this function returned last
    cycle for the same key. Returns the new tracking dict; its "state" field
    is one of this project's eight named values.

    An EXPLAINED classification is reported as itself, every cycle, and does
    not accumulate a streak -- there is nothing to confirm about a route this
    tool already knows the reason for. Only "observed" counts a streak, and
    only a streak of the *same* classification: a route that was
    next_hop_dependency last cycle and is unexplained this cycle has not been
    unexplained for two cycles, it has been unexplained for one, because
    whatever was true of it changed.
    """
    if classification in EXPLAINED:
        return {"classification": classification, "state": classification,
                "streak": 0}

    streak = 1
    if prior and prior["classification"] == classification:
        streak = prior["streak"] + 1

    if streak >= stale_after + confirm_after:
        state = "confirmed_stale"
    elif streak >= stale_after:
        state = "stale_candidate"
    else:
        state = "observed"
    return {"classification": classification, "state": state, "streak": streak}


def watch(interval, cycles, as_json, stale_after=3, confirm_after=3):
    """Compare repeatedly and run each disagreement through the state machine.

    A single comparison cannot tell drift from a route in flight. The path is
    asynchronous -- zebra pushes, brokerd queues, the data plane programs --
    so a route added a moment ago is legitimately "desired not programmed" for
    as long as that takes. Every probe written against this pipeline has slept
    for several seconds before reading, for exactly that reason.

    So what is reported per item is not just whether a disagreement exists but
    which of the eight named states it is in: five explained ones from
    classify_extra()/classify_missing(), computed fresh every cycle, and the
    progression observed -> stale_candidate -> confirmed_stale for the
    residual that none of the five explain -- see advance_state(). Reaching
    confirmed_stale needs `stale_after + confirm_after` *consecutive* cycles
    of that same unexplained classification: no in-flight transaction, no
    dependency, not reserved, not a source mismatch, the whole time.

    Still not a repair loop, on purpose: the thresholds above are exactly the
    unknown this collects evidence for, and a loop that acts on an unproven
    threshold with a whole-session repair would reset the routing plane on a
    schedule instead of when something is actually wrong.
    """
    seen = {}
    cycle = 0

    while cycles is None or cycle < cycles:
        cycle += 1
        d = desired()
        p = programmed()
        if d is None or p is None:
            # Refuse rather than record a cycle of total drift. An unreadable
            # side looks exactly like an empty one.
            print(json.dumps({"cycle": cycle, "timestamp": datetime.now(timezone.utc).isoformat(), "status": "unreadable", "error": "unreadable"})
                  if as_json else
                  "cycle %d: a side is unreadable, not counted" % cycle)
            time.sleep(interval)
            continue

        if cycle == 1 and not ownership_known(p):
            msg = ("this image's object view does not report ownership; "
                   "reserved routes cannot be told from drift and are "
                   "excluded rather than reported")
            print(json.dumps({"cycle": 0, "note": msg}) if as_json
                  else "note: " + msg)

        cov = coverage()
        missing = set(d) - set(p)
        extra = set(k for k in set(p) - set(d) if unowned(p, k))
        now = {("missing",) + k: classify_missing(cov) for k in missing}
        now.update({("extra",) + k: classify_extra(p, k, cov) for k in extra})

        for key, classification in now.items():
            seen[key] = advance_state(seen.get(key), classification,
                                       stale_after, confirm_after)
        for key in list(seen):
            if key not in now:
                del seen[key]

        persistent = sorted(
            ((v["streak"], k, v) for k, v in seen.items()), reverse=True)
        if as_json:
            print(json.dumps({
                "cycle": cycle,
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "status": "diagnostic",
                "desired": len(d),
                "programmed_keys": len(p),
                "disagreements": [
                    {"kind": k[0], "vrf": k[1], "prefix": k[2],
                     "cycles": n, "classification": v["classification"],
                     "state": v["state"]}
                    for n, k, v in persistent
                ],
            }))
        else:
            print("cycle %d  desired %d  programmed %d  disagreements %d"
                  % (cycle, len(d), len(p), len(persistent)))
            for n, k, v in persistent:
                print("    %-8s vrf:%s/%s  %s (%s)  %d cycle%s"
                      % (k[0], k[1], k[2], v["state"], v["classification"],
                         n, "" if n == 1 else "s"))
            confirmed = [k for _, k, v in persistent if v["state"] == "confirmed_stale"]
            if confirmed:
                print("    repair, if this persists: vtysh -c 'configure "
                      "terminal' -c 'no fpm address 127.0.0.1' then set it "
                      "again -- whole-session, not per route")

        if cycles is None or cycle < cycles:
            time.sleep(interval)

    return 0


if "--watch" in sys.argv:
    i = sys.argv.index("--watch")
    interval = float(sys.argv[i + 1])
    cycles = None
    if "--cycles" in sys.argv:
        cycles = int(sys.argv[sys.argv.index("--cycles") + 1])
    stale_after = 3
    if "--stale-after" in sys.argv:
        stale_after = int(sys.argv[sys.argv.index("--stale-after") + 1])
    confirm_after = 3
    if "--confirm-after" in sys.argv:
        confirm_after = int(sys.argv[sys.argv.index("--confirm-after") + 1])
    sys.exit(watch(interval, cycles, "--json" in sys.argv,
                    stale_after, confirm_after))

sys.exit(main())
