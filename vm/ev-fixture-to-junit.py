#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-only
"""Split an accept-*.sh result JSON into per-item JUnit files and one evidence record per item.

The harness result lists named checks (check/status/detail). ITEMS maps each suite-config item key to
the checks that make it up; SETUP lists bookkeeping checks that belong to no item. A check that is in
neither table is an error (nothing is silently dropped), and an item with a missing check is FAIL, never
absent. A check that is not PASS becomes a <failure>, and the item's status is FAIL.

Usage: ev-fixture-to-junit.py <result.json> <iso_sha256> <outdir> <run-description> <raw-file>... [--items k1,k2,...]
Writes <outdir>/<item>.junit.xml and <outdir>/<item>.ev.json for every item that has at least one of its checks in the result.
Exit 0 if every written item is PASS, 1 otherwise, 2 if a check is unaccounted for.
"""
import hashlib, json, re, subprocess, sys
import xml.etree.ElementTree as ET
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

ITEMS = {
    "live_boot": ["the live vm started", "the live system accepts tmpuser"],
    "disk_install_unattended": ["the installer finished and wrote the disk"],
    "post_install_boot": ["the installed system started", "it booted; ssh needed configuring", "the kernel came from the disk's /boot",
                          "the root union is assembled from /boot", "a virtio disk partition is in use by the guest",
                          "the data plane runs on the installed system"],
    "reboot_persistence": ["it really restarted", "it came back on the same root", "the data plane came back", "the saved configuration survived"],
    "upgrade_add_image": ["a second image is registered", "the new image's files are on disk", "it booted the new image",
                          "the admin account survived the switch", "the new image runs a different version"],
    "rollback": ["it booted the original image again", "the admin account survived the rollback", "the rollback runs the old version again"],
    "cloud_init": ["the seed's hostname was applied, no stall"],
    "nic_naming_stability": ["dp0s3 keeps its name and mac across the image switches"],
    "no_network_boot": ["the machine was started with -nic none and no -netdev", "a login works with no network at all",
                        "the guest has no network device"],
}
SETUP = ["fresh 20 gib qcow2 created", "overlay created; the installed disk is not written", "baseline read", "old image version read",
         "the iso is being served", "the installed image is the old version"]


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


def main():
    a = sys.argv[1:]
    only = None
    if "--items" in a:
        i = a.index("--items"); only = a[i + 1].split(","); del a[i:i + 2]
    result, iso, outdir, run_desc, *raws = a
    doc = json.load(open(result))
    checks = [(c["check"], c["status"], c.get("detail", "")) for c in doc["checks"]]
    seen = {}
    for name, st, det in checks:
        seen.setdefault(name.lower(), []).append((name, st, det))
    known = {x for v in ITEMS.values() for x in v} | set(SETUP)
    stray = [n for n in seen if n not in known]
    if stray:
        print("unaccounted checks:", stray, file=sys.stderr); sys.exit(2)
    dup = [n for n, v in seen.items() if len(v) > 1 and n in {x for v in ITEMS.values() for x in v}]
    if dup:
        print("check names used more than once:", dup, file=sys.stderr); sys.exit(2)
    head = subprocess.run(["git", "-C", str(REPO), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    dirty = bool(subprocess.run(["git", "-C", str(REPO), "status", "--porcelain", "--untracked-files=no", "vm", "release"],
                                capture_output=True, text=True).stdout.strip())
    blob = subprocess.run(["git", "-C", str(REPO), "show", head + ":vm/ev-fixture-to-junit.py"], capture_output=True).stdout
    out = Path(outdir); out.mkdir(parents=True, exist_ok=True)
    worst = 0; records = {}
    for item, names in ITEMS.items():
        if only and item not in only: continue
        if not any(n in seen for n in names): continue
        suite = ET.Element("testsuite", name=item)
        npass = nfail = 0
        for n in names:
            tc = ET.SubElement(suite, "testcase", classname=item, name=slug(n))
            if n not in seen:
                nfail += 1
                ET.SubElement(tc, "failure", message="check missing from the result", type="AssertionError").text = "no result line for: " + n
                continue
            name, st, det = seen[n][0]
            if st == "PASS": npass += 1
            else:
                nfail += 1
                ET.SubElement(tc, "failure", message="fixture status " + st, type="AssertionError").text = det
            ET.SubElement(tc, "system-out").text = "%s: %s" % (st, det)
        suite.set("tests", str(npass + nfail)); suite.set("failures", str(nfail)); suite.set("errors", "0"); suite.set("skipped", "0")
        j = out / (item + ".junit.xml"); ET.ElementTree(suite).write(j, encoding="utf-8", xml_declaration=True)
        rec = {"item": item, "iso_sha256": iso, "suite_commit": head, "tool_commit": head,
               "status": "PASS" if nfail == 0 else "FAIL", "result_file": item + ".junit.xml", "result_sha256": sha(j),
               "cases": {"total": npass + nfail, "passed": npass, "failed": nfail, "skipped": 0},
               "suite_dirty": dirty, "generated_by": "toolkit/vm/ev-fixture-to-junit.py",
               "tool_sha256": hashlib.sha256(blob).hexdigest(), "run": run_desc,
               "fixture_result": Path(result).name, "fixture_result_sha256": sha(result),
               "raw_files": {Path(r).name: sha(r) for r in raws}}
        records[item] = rec
        (out / (item + ".ev.json")).write_text(json.dumps({"format": "danos-verification-evidence-v2", "iso": doc.get("image", ""),
            "note": "developer claim derived from the harness result by toolkit/vm/ev-fixture-to-junit.py; the final status is recomputed by the orchestrator",
            "records": [rec]}, indent=1) + "\n")
        print(item, rec["status"], "%d/%d" % (npass, npass + nfail))
        if nfail: worst = 1
    sys.exit(worst)


if __name__ == "__main__":
    main()
