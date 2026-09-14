#!/usr/bin/env python3
"""Compare what was asked for against what is programmed.

Usage: dpa-drift.py [--json]

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

VTYSH = ["sudo", "vtysh", "-c", "show ip route json"]
VPLSH = ["sudo", "/opt/vyatta/bin/vplsh", "-l", "-c", "dpa object show route"]


def run(cmd):
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    if p.returncode != 0 or not p.stdout.strip():
        return None
    try:
        return json.loads(p.stdout)
    except json.JSONDecodeError:
        return None


def desired():
    """(vrf_name, table, prefix) for every route zebra actually pushed down."""
    rib = run(VTYSH)
    if rib is None:
        return None
    out = {}
    for prefix, entries in rib.items():
        for e in entries:
            # The whole point: only what was selected *and* installed.
            if not (e.get("selected") and e.get("installed")):
                continue
            # vrfName, not vrfId. The numbers are separate namespaces --
            # DANOS's default VRF is 1 and zebra's is 0 -- and comparing them
            # made every route on a healthy box look like drift.
            out[(e.get("vrfName", "default"), e.get("table", 254), prefix)] = \
                e.get("protocol", "?")
    return out


def programmed():
    """(vrf_name, table, prefix) -> (state, backend, owned), and any duplicates.

    Duplicates are returned rather than silently collapsed. The data plane's
    LPM keys on (prefix, depth, scope) while this key has no scope in it,
    because zebra has no comparable notion -- so two LPM entries for one prefix
    at different scopes land on one key here. That has not been observed, and
    the reason to detect it rather than assume it cannot happen is that the
    symptom would be a route quietly disappearing from one side of a
    comparison whose whole job is to notice routes disappearing.
    """
    doc = run(VPLSH)
    if doc is None:
        return None, None
    out = {}
    dupes = []
    for o in doc.get("dpa_objects", {}).get("objects", []):
        # "vrf:default/table:254/10.73.0.0/24"
        parts = o["key"].split("/")
        if len(parts) < 3 or not parts[0].startswith("vrf:"):
            continue
        vrf = parts[0][4:]
        table = int(parts[1][6:])
        prefix = "/".join(parts[2:])
        k = (vrf, table, prefix)
        if k in out:
            dupes.append(k)
        out[k] = (o.get("state"), o.get("backend"),
                  o.get("dataplane_owned", False))
    return out, dupes


def main():
    as_json = "--json" in sys.argv

    d = desired()
    p, dupes = programmed()

    if d is None:
        print("UNREADABLE desired (vtysh)", file=sys.stderr)
        return 2
    if p is None:
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
    extra = sorted(k for k in set(p) - set(d) if not p[k][2])
    owned = sorted(k for k in set(p) - set(d) if p[k][2])

    # The guard. Nothing in common while both sides hold routes means the two
    # identity schemes disagree, not that the data plane lost everything.
    keyspace_broken = bool(d) and bool(p) and not matched

    result = {
        "desired": len(d),
        "programmed": len(p),
        "matched": len(matched),
        "desired_not_programmed": [
            {"vrf": k[0], "table": k[1], "prefix": k[2], "protocol": d[k]}
            for k in missing
        ],
        "programmed_not_desired": [
            {"vrf": k[0], "table": k[1], "prefix": k[2],
             "state": p[k][0], "backend": p[k][1]}
            for k in extra
        ],
        "dataplane_owned": [
            {"vrf": k[0], "table": k[1], "prefix": k[2]} for k in owned
        ],
        "duplicate_keys": [
            {"vrf": k[0], "table": k[1], "prefix": k[2]} for k in dupes
        ],
        "keyspace_mismatch": keyspace_broken,
    }

    if as_json:
        print(json.dumps(result))
    else:
        print("desired %d  programmed %d  matched %d" %
              (result["desired"], result["programmed"], result["matched"]))
        if keyspace_broken:
            print("KEY SPACE MISMATCH: the two sides share no identity, which "
                  "is a formatting disagreement rather than drift")
            for k in sorted(d)[:3]:
                print("  desired    %s" % (k,))
            for k in sorted(p)[:3]:
                print("  programmed %s" % (k,))
        else:
            for e in result["desired_not_programmed"]:
                print("  DESIRED NOT PROGRAMMED  vrf:%(vrf)s/table:%(table)s/"
                      "%(prefix)s  from %(protocol)s" % e)
            for e in result["programmed_not_desired"]:
                print("  PROGRAMMED NOT DESIRED  vrf:%(vrf)s/table:%(table)s/"
                      "%(prefix)s  %(state)s on %(backend)s" % e)
            for e in result["dataplane_owned"]:
                print("  dataplane-owned, not drift  vrf:%(vrf)s/"
                      "table:%(table)s/%(prefix)s" % e)
        for e in result["duplicate_keys"]:
            print("  DUPLICATE KEY  vrf:%(vrf)s/table:%(table)s/%(prefix)s  "
                  "-- one side of a comparison lost an object to collapsing"
                  % e)

    if keyspace_broken:
        return 3
    if dupes:
        return 4
    return 1 if (missing or extra) else 0


sys.exit(main())
