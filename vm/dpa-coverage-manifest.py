#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-only
"""The DPA object model's coverage, derived from source, not remembered.

This project has hit the same failure twice already: a check that cannot tell
"absent" from "not carried" reads one as the other. probe-dpa-coverage.sh
misreported the two QoS classes as enumerable because it matched the word
"dpa_objects" in the reply, which a class with no walker returns too (see
DEFECTS.md, "DPA object model: nexthop-group class, and a coverage-probe
defect"). dpa-drift.py's own header comment still says "the object view
enumerates six" -- true when nexthop-group and interface did not exist yet,
false since vyatta-dataplane 3.14.40/3.14.41 added them, and nothing forced
that comment to notice.

The second failure is why this file parses the two places coverage actually
lives instead of copying their answer once:

  - vyatta-dataplane's own dpa_classes[] table (src/dpa_object.c) is ground
    truth for which classes exist and which have a walker at all. A class
    added there and never mentioned here would otherwise be invisible to
    every tool that only asks a running box, which can only ever report on
    classes that box's build already knows about.
  - dpa-drift.py's own COMPARED set is ground truth for which of the walkable
    classes have a zebra-side "desired" view to compare against. Copying it
    by hand is exactly how it went stale in dpa-drift.py's own comment.

Per-class notes below (excluded sub-cases, keying caveats, what "compared"
does and does not mean for that class) are hand-authored, because they are
prose reasons no source table carries structurally -- each cites the document
it comes from. If a class in this file has no notes entry, that itself is the
finding: read from source and not yet written down anywhere.

Usage:
  dpa-coverage-manifest.py [--dataplane-src DIR] [--drift-script FILE] [--json]
  dpa-coverage-manifest.py --check-live <ssh-target> [...]
    Also queries a running router's own "dpa object show" and flags any
    disagreement with the source-derived table -- the build's advertised
    classes should never differ from what dpa_object.c on that same build
    would say, and if they do, this file's parsing or that build is stale,
    not the box.
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

DEFAULT_DP_SRC = "/home/aikon/danos/build-iso/danos-sources/vyatta-dataplane"
DEFAULT_DRIFT = str(Path(__file__).parent / "dpa-drift.py")

# Hand-authored, one entry per class the source table names. Each "notes" line
# cites where it was established; "sub_exclusions" are cases inside an
# enumerable, even compared, class where this project has found or documented
# that some objects are still not covered -- these do not show up in a
# whole-class enumerable/compared boolean at all.
CLASS_NOTES = {
    "route": {
        "sub_exclusions": [
            "a route's programmed state can be inherited from its next-hop "
            "group rather than carried on the route itself; how often that "
            "happens was not measured (FRR-ROUTE-REPAIR-DECISION.md, D3)",
        ],
        "notes": "keyed vrf/table/prefix/scope; case of the DPA state string "
                 "differs from route6's, normalized in dpa-drift.py",
    },
    "route6": {
        "sub_exclusions": [
            "same next-hop-group inheritance caveat as route (D3)",
        ],
        "notes": "same keying as route; DPA state string is lowercase where "
                 "route's is uppercase",
    },
    "mpls-route": {
        "sub_exclusions": [
            "reserved labels 0/1/2 report no ownership (owned=unknown) and "
            "are excluded from drift by the same rule as an unreadable "
            "image, not compared as real drift",
        ],
        "notes": "keyed by incoming label alone; zebra side is "
                 "'show mpls table json'",
    },
    "mroute": {
        "sub_exclusions": [],
        "notes": "keyed (source,group) per VRF; zebra's any-source '*' maps "
                 "to the data plane's unspecified-address form",
    },
    "mroute6": {
        "sub_exclusions": [],
        "notes": "same keying and source-address mapping as mroute",
    },
    "vrf": {
        "sub_exclusions": [],
        "notes": "enumerable but not compared: 'show vrf' has no JSON form "
                 "on the zebra side, so there is no desired-side view to "
                 "diff against at all -- not a gap in this class's walker",
    },
    "nexthop-group": {
        "sub_exclusions": [
            "indices 0-3 are the data plane's own reserved routes "
            "(reserved_routes in route.c), not zebra-sourced; fits but was "
            "not verified index-by-index",
        ],
        "notes": "coverage only, by design: zebra has no comparable "
                 "'desired' next-hop-group view, so this can never move into "
                 "COMPARED no matter how complete the walker is "
                 "(DEFECTS.md, nexthop-group section)",
    },
    "interface": {
        "sub_exclusions": [
            "only interfaces whose type defines ifop_l3_enable are ever "
            "listed -- dpdk-eth, gre, vlan. bridge, vxlan, macvlan, vti, "
            "l2tpeth, ppp, ipip and vrf interfaces are never listed even "
            "with an L3 address (verified for a bridge SVI on real "
            "hardware: absent whether the bridge is down or up with a live "
            "member; verified read-from-code only for the rest)",
            "lo, pimreg and pim6reg are not listed either, and are not yet "
            "explained beyond 'their type defines no ifop_l3_enable'",
            "GRE is wired the same way as vlan/dpdk-eth but was not "
            "exercised",
        ],
        "notes": "not compared against zebra at all; absence from this "
                 "class means only 'not one of the three walkable types', "
                 "never 'not routed' (DEFECTS.md, interface class sections)",
    },
    "qos-if": {
        "sub_exclusions": [],
        "notes": "walks software scheduler state, one object per port with "
                 "qos configured, key qos-if:<ifname>; hardware state is "
                 "consulted only on the FAL path; not compared against "
                 "anything; only the software path is unit-tested "
                 "(no hardware available)",
    },
    "qos-vlan": {
        "sub_exclusions": [],
        "notes": "walks software subport state, one object per vlan subport "
                 "(subport 0, the port default, is excluded), key "
                 "qos-vlan:<ifname>/<vlan>; not compared against anything; "
                 "only the software path is unit-tested",
    },
}


def parse_dpa_classes(dp_src):
    """Ground truth: the dpa_classes[] table in vyatta-dataplane's own source."""
    path = Path(dp_src) / "src" / "dpa_object.c"
    if not path.is_file():
        sys.exit(f"no such file: {path} -- pass --dataplane-src <vyatta-dataplane checkout>")
    text = path.read_text()
    m = re.search(r"static const struct dpa_obj_class dpa_classes\[\]\s*=\s*\{(.*?)\n\};",
                  text, re.S)
    if not m:
        sys.exit(f"could not find dpa_classes[] in {path} -- table renamed or moved?")
    body = m.group(1)
    classes = {}
    for line in body.splitlines():
        row = re.match(r'\s*\{\s*"([a-z0-9-]+)"\s*,\s*([A-Za-z0-9_]+|NULL)\s*,\s*(NULL|"[^"]*")\s*\}',
                        line)
        if not row:
            continue
        name, walker, no_walker_reason = row.groups()
        classes[name] = {
            "walkable": walker != "NULL",
            "walker_function": None if walker == "NULL" else walker,
            "no_walker_reason": None if no_walker_reason == "NULL" else no_walker_reason.strip('"'),
        }
    if not classes:
        sys.exit(f"dpa_classes[] in {path} matched but no rows parsed -- format changed?")
    return classes


def parse_compared_set(drift_script):
    """Ground truth: dpa-drift.py's own COMPARED set, not a copy of it."""
    text = Path(drift_script).read_text()
    m = re.search(r'^COMPARED\s*=\s*\{([^}]*)\}', text, re.M)
    if not m:
        sys.exit(f"could not find COMPARED = {{...}} in {drift_script}")
    return {tok.strip().strip('"').strip("'") for tok in m.group(1).split(",") if tok.strip()}


def build_manifest(dp_src, drift_script):
    classes = parse_dpa_classes(dp_src)
    compared = parse_compared_set(drift_script)
    unnoted = sorted(set(classes) - set(CLASS_NOTES))
    rows = []
    for name in sorted(classes):
        c = classes[name]
        note = CLASS_NOTES.get(name, {"sub_exclusions": [], "notes": None})
        rows.append({
            "class": name,
            "walkable": c["walkable"],
            "no_walker_reason": c["no_walker_reason"],
            "compared_against_zebra": name in compared,
            "sub_exclusions": note["sub_exclusions"],
            "notes": note["notes"],
        })
    return {
        "schema_version": 1,
        "source": {
            "dpa_classes_table": str(Path(dp_src) / "src" / "dpa_object.c"),
            "compared_set": str(drift_script),
        },
        "classes": rows,
        "unnoted_classes": unnoted,  # present in source, no CLASS_NOTES entry
    }


def check_live(target, manifest, port="22"):
    """Cross-check the manifest's walkable set against what a running box says.

    Run through the danos-robot container, like every other script here that
    talks to a test router -- sshpass lives there, not on the host, and a
    plain ssh from the host to a hostfwd port has nowhere to get vyatta's
    password from either.
    """
    # sudo needs -S with the password piped in, same as every other script
    # here that runs a root command over this same non-interactive ssh --
    # a bare "sudo ..." just fails with "a terminal is required".
    remote_cmd = "echo vyatta | sudo -S -p '' /opt/vyatta/bin/vplsh -l -c 'dpa object show'"
    cmd = ["docker", "exec", "danos-robot", "timeout", "20", "sshpass", "-p", "vyatta",
           "ssh", "-p", port, "-o", "StrictHostKeyChecking=no",
           "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=10",
           target, remote_cmd]
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    if p.returncode != 0 or not p.stdout.strip():
        return {"reachable": False, "detail": p.stderr.strip() or "no output"}
    try:
        text = p.stdout
        doc = json.loads(text[text.index("{"):])
        live = {c["class"]: c["enumerable"] for c in doc["dpa_objects"]["classes"]}
    except Exception as e:
        return {"reachable": False, "detail": f"could not parse reply: {e}"}
    disagreements = []
    src = {r["class"]: r["walkable"] for r in manifest["classes"]}
    for name, live_enumerable in live.items():
        if name not in src:
            disagreements.append(f"{name}: live box reports it, not in source table "
                                  f"({manifest['source']['dpa_classes_table']}) -- "
                                  f"source is stale or from a different build")
        elif live_enumerable != src[name]:
            disagreements.append(f"{name}: source says walkable={src[name]}, "
                                  f"live box says enumerable={live_enumerable}")
    for name in src:
        if name not in live:
            disagreements.append(f"{name}: in source table, absent from the live "
                                  f"reply entirely")
    return {"reachable": True, "live_classes": sorted(live), "disagreements": disagreements}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--dataplane-src", default=DEFAULT_DP_SRC)
    ap.add_argument("--drift-script", default=DEFAULT_DRIFT)
    ap.add_argument("--check-live", metavar="ssh-target",
                     help="e.g. vyatta@192.168.203.155 -- reached through the "
                          "danos-robot container, like every other test script here")
    ap.add_argument("--check-live-port", default="22",
                     help="ssh port on the target (default 22; a single "
                          "boot-vm.sh router reached via its hostfwd, e.g. "
                          "vyatta@192.168.203.1, needs its mapped port here)")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    manifest = build_manifest(args.dataplane_src, args.drift_script)

    if args.check_live:
        manifest["live_check"] = check_live(args.check_live, manifest, args.check_live_port)

    if args.json:
        print(json.dumps(manifest, indent=2))
        return 1 if manifest.get("live_check", {}).get("disagreements") else 0

    walkable = [r for r in manifest["classes"] if r["walkable"]]
    unwalkable = [r for r in manifest["classes"] if not r["walkable"]]
    print(f"{len(manifest['classes'])} classes ({len(walkable)} walkable, "
          f"{len(unwalkable)} not), from {manifest['source']['dpa_classes_table']}")
    for r in walkable:
        cmp_ = "compared" if r["compared_against_zebra"] else "not compared"
        print(f"  {r['class']:<16} walkable, {cmp_}")
        if r["notes"]:
            print(f"    {r['notes']}")
        for exc in r["sub_exclusions"]:
            print(f"    - {exc}")
    for r in unwalkable:
        print(f"  {r['class']:<16} no walker ({r['no_walker_reason']})")
    if manifest["unnoted_classes"]:
        print(f"\nUNNOTED (in source, no entry in this script's CLASS_NOTES): "
              f"{', '.join(manifest['unnoted_classes'])}")
    if "live_check" in manifest:
        lc = manifest["live_check"]
        print(f"\nlive check against {args.check_live}:")
        if not lc["reachable"]:
            print(f"  UNREACHABLE: {lc['detail']}")
        elif lc["disagreements"]:
            for d in lc["disagreements"]:
                print(f"  DISAGREEMENT: {d}")
        else:
            print("  agrees with source table")
    return 1 if manifest["unnoted_classes"] else 0


if __name__ == "__main__":
    sys.exit(main())
