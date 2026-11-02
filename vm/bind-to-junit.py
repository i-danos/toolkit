#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-only
"""Wrap one judge run into a JUnit file and an evidence record (danos-verification-evidence-v2).

The judge's own exit code and one-line verdict are recorded verbatim; this tool decides nothing.
Usage: bind-to-junit.py <item> <judge-slug> <exit-code> <judge-output-file> <iso_sha256> <outdir> <witness-text> <raw-file>...
Writes <outdir>/<item>.junit.xml and <outdir>/<item>.ev.json.
"""
import hashlib, json, subprocess, sys
import xml.etree.ElementTree as ET
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def main():
    item, slug, rc, outf, iso, outdir, witness, *raws = sys.argv[1:]
    line = Path(outf).read_text().strip()
    ok = int(rc) == 0 and line.startswith("PASS:")
    suite = ET.Element("testsuite", name=item, tests="1", failures="0" if ok else "1", errors="0", skipped="0")
    tc = ET.SubElement(suite, "testcase", classname=item, name=item + "." + slug)
    if not ok:
        ET.SubElement(tc, "failure", message="judge exit %s" % rc, type="AssertionError").text = line
    ET.SubElement(tc, "system-out").text = "witness: %s\nexit=%s\n%s" % (witness, rc, line)
    d = Path(outdir); d.mkdir(parents=True, exist_ok=True)
    junit = d / (item + ".junit.xml")
    ET.ElementTree(suite).write(junit, encoding="utf-8", xml_declaration=True)
    head = subprocess.run(["git", "-C", str(REPO), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    dirty = bool(subprocess.run(["git", "-C", str(REPO), "status", "--porcelain", "--untracked-files=no", "vm", "release"],
                                capture_output=True, text=True).stdout.strip())
    blob = subprocess.run(["git", "-C", str(REPO), "show", head + ":vm/bind-to-junit.py"], capture_output=True).stdout
    rec = {"item": item, "iso_sha256": iso, "suite_commit": head, "tool_commit": head,
           "status": "PASS" if ok else "FAIL", "result_file": item + ".junit.xml", "result_sha256": sha(junit),
           "cases": {"total": 1, "passed": 1 if ok else 0, "failed": 0 if ok else 1, "skipped": 0},
           "suite_dirty": dirty, "generated_by": "toolkit/vm/bind-to-junit.py",
           "tool_sha256": hashlib.sha256(blob).hexdigest(), "judge": "judge-" + slug + ".py", "judge_exit": int(rc),
           "judge_line": line, "witness": witness,
           "raw_files": {str(Path(r).name): sha(r) for r in raws}}
    doc = {"format": "danos-verification-evidence-v2", "iso": "i-danos_2608_20261030T0752-amd64.hybrid.iso",
           "note": "developer claim: real capture from TOPO=ipsec boot, judge run unmodified; final status is recomputed by the orchestrator",
           "records": [rec]}
    (d / (item + ".ev.json")).write_text(json.dumps(doc, indent=1) + "\n")
    print(item, rec["status"])
    sys.exit(0)


if __name__ == "__main__":
    main()
