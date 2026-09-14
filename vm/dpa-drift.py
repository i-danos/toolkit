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
    """(vrf_name, table, prefix) -> (state, backend) from the DPA object view."""
    doc = run(VPLSH)
    if doc is None:
        return None
    out = {}
    for o in doc.get("dpa_objects", {}).get("objects", []):
        # "vrf:default/table:254/10.73.0.0/24"
        parts = o["key"].split("/")
        if len(parts) < 3 or not parts[0].startswith("vrf:"):
            continue
        vrf = parts[0][4:]
        table = int(parts[1][6:])
        prefix = "/".join(parts[2:])
        out[(vrf, table, prefix)] = (o.get("state"), o.get("backend"))
    return out


def main():
    as_json = "--json" in sys.argv

    d = desired()
    p = programmed()

    if d is None:
        print("UNREADABLE desired (vtysh)", file=sys.stderr)
        return 2
    if p is None:
        print("UNREADABLE programmed (vplsh dpa object show)", file=sys.stderr)
        return 2

    matched = sorted(set(d) & set(p))
    missing = sorted(set(d) - set(p))
    extra = sorted(set(p) - set(d))

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

    if keyspace_broken:
        return 3
    return 1 if (missing or extra) else 0


sys.exit(main())
