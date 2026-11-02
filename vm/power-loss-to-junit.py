#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-only
"""Turn a power-loss fixture log into one JUnit file and one evidence record (danos-verification-evidence-v2).

verify-power-loss.sh and verify-power-loss-more.sh print one block per trial:

    ===== trial 3: cut 1.8s after the commit is sent =====
    ... free-form lines ...
      PASS            (or FAIL / BLOCKED, alone on a line, ends the block)

Every trial becomes one test case named from its heading; PASS -> passed, FAIL -> failure, BLOCKED -> failure
(the case did not get to run, which is not a pass). A log with no trial block, a block with no verdict, or a
verdict line after which the run's own summary disagrees, is refused: this converter never invents a result.

Usage: power-loss-to-junit.py <item> <fixture.log> <iso_sha256> <outdir> <generated_by> <run-description> [--base-disk PATH]
Writes <outdir>/<item>.junit.xml and <outdir>/<item>.ev.json.
"""
import hashlib, json, re, subprocess, sys
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent


def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()


def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


def parse(log_text):
    """-> [(heading, verdict, body)]; raises ValueError on anything it cannot account for."""
    trials, cur = [], None
    for line in log_text.splitlines():
        m = re.match(r"^===== trial (\d+): (.*) =====\s*$", line)
        if m:
            if cur is not None and cur[1] is None:
                raise ValueError("trial %s has no verdict line" % cur[0])
            cur = [m.group(1) + ": " + m.group(2), None, []]
            trials.append(cur)
            continue
        if cur is None:
            continue
        if re.match(r"^===== ", line):
            if cur[1] is None:
                raise ValueError("trial %s ended without a verdict" % cur[0])
            cur = None
            continue
        v = line.strip()
        if v in ("PASS", "FAIL", "BLOCKED") and cur[1] is None:
            cur[1] = v
        else:
            cur[2].append(line)
    if not trials:
        raise ValueError("no '===== trial N: ... =====' block in the log")
    if trials[-1][1] is None:
        raise ValueError("trial %s has no verdict line (log truncated?)" % trials[-1][0])
    return [tuple(t) for t in trials]


def main():
    a = [x for x in sys.argv[1:] if not x.startswith("--base-disk")]
    base = None
    if "--base-disk" in sys.argv:
        base = sys.argv[sys.argv.index("--base-disk") + 1]
        a = [x for x in a if x != base]
    item, log, iso_sha, outdir, generated_by, run_desc = a
    text = Path(log).read_text(errors="replace")
    trials = parse(text)
    summ = re.search(r"^===== (\d+) passed, (\d+) failed of (\d+) cuts =====", text, re.M)
    npass = sum(1 for t in trials if t[1] == "PASS")
    nfail = len(trials) - npass
    if summ and (int(summ.group(1)), int(summ.group(2)), int(summ.group(3))) != (npass, nfail, len(trials)):
        sys.exit("the fixture's own summary (%s) disagrees with its trial blocks (%d pass, %d not)" % (summ.group(0), npass, nfail))
    suite = ET.Element("testsuite", name=item, tests=str(len(trials)), failures=str(nfail), errors="0", skipped="0")
    for heading, verdict, body in trials:
        tc = ET.SubElement(suite, "testcase", classname=item, name=slug(heading))
        out = "\n".join(l for l in body if l.strip())
        if verdict != "PASS":
            f = ET.SubElement(tc, "failure", message="fixture verdict " + verdict, type="AssertionError")
            f.text = out
        ET.SubElement(tc, "system-out").text = "verdict: %s\n%s" % (verdict, out)
    out_dir = Path(outdir)
    out_dir.mkdir(parents=True, exist_ok=True)
    junit = out_dir / (item + ".junit.xml")
    ET.ElementTree(suite).write(junit, encoding="utf-8", xml_declaration=True)
    head = subprocess.run(["git", "-C", str(REPO), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    dirty = bool(subprocess.run(["git", "-C", str(REPO), "status", "--porcelain", "--untracked-files=no", "vm", "release"],
                                capture_output=True, text=True).stdout.strip())
    rel = generated_by.split("/", 1)[1] if generated_by.startswith("toolkit/") else generated_by
    blob = subprocess.run(["git", "-C", str(REPO), "show", head + ":" + rel], capture_output=True).stdout
    rec = {
        "item": item, "iso_sha256": iso_sha, "suite_commit": head, "tool_commit": head,
        "status": "PASS" if nfail == 0 else "FAIL",
        "result_file": item + ".junit.xml", "result_sha256": sha256(junit),
        "cases": {"total": len(trials), "passed": npass, "failed": nfail, "skipped": 0},
        "suite_dirty": dirty, "generated_by": generated_by,
        "tool_sha256": hashlib.sha256(blob).hexdigest(),
        "fixture_log": Path(log).name, "fixture_log_sha256": sha256(log),
        "run": run_desc + (" Base disk sha256 " + sha256(base) + "." if base else ""),
    }
    doc = {"format": "danos-verification-evidence-v2", "iso": "i-danos_2608_20261030T0752-amd64.hybrid.iso",
           "note": "developer claim derived from the fixture log by toolkit/vm/power-loss-to-junit.py; the final status is recomputed by the orchestrator",
           "records": [rec]}
    (out_dir / (item + ".ev.json")).write_text(json.dumps(doc, indent=1) + "\n")
    print("%s: %d trials, %d pass, %d not; junit sha256 %s" % (item, len(trials), npass, nfail, rec["result_sha256"]))
    sys.exit(0 if nfail == 0 else 1)


if __name__ == "__main__":
    main()
