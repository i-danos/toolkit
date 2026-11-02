#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-only
"""Turn regression.sh's Robot results into JUnit files and an evidence record for the item robot_81_cases.

regression.sh runs the SUITES table (read from the script itself at the commit being used, never remembered here) and leaves
results-<tag>-<suite>/output.xml per suite. This converter reads those files and writes

    <outdir>/robot_81_cases.<suite>.junit.xml   one per suite: classname robot_81_cases, one testcase per Robot test
    <outdir>/robot_81_cases.junit.xml           all suites together: what the evidence record binds to
    <outdir>/robot_81_cases.summary.txt         suite -> pass/fail, the total against the expected count, every failure by name
    <outdir>/robot_81_cases.ev.json             danos-verification-evidence-v2 record

The item key is historical (81 was the 2026-09-26 suite size); the expected total is the sum of the SUITES table.
A suite whose output.xml is missing, unparseable, or has a different number of tests than the table says is a failing
testcase of its own: cases that went missing never read as passed or as fewer.

Usage: robot-to-junit.py <results-dir> <tag> <outdir> <iso_sha256> <regression.log> [--vm-dir DIR]
"""
import hashlib
import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ITEM = "robot_81_cases"
HERE = Path(__file__).resolve().parent
REPO = HERE.parent


def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()


def read_suites(script_text):
    """The SUITES table of regression.sh -> [(key, topo, file, expected_cases)]."""
    m = re.search(r'^SUITES="\n(.*?)^"', script_text, re.M | re.S)
    if not m:
        raise ValueError("no SUITES table in regression.sh")
    rows = []
    for line in m.group(1).splitlines():
        parts = line.split()
        if len(parts) == 4:
            rows.append((parts[0], parts[1], parts[2], int(parts[3])))
    if not rows:
        raise ValueError("SUITES table is empty")
    return rows


def robot_tests(path):
    """output.xml -> [(longname, status, message)]; raises on anything that is not a Robot output.

    Robot counts every test of a suite as failed when that suite's TEARDOWN fails, while the test elements keep the
    status they had when they ran. The statistics are what Robot reports and what regression.sh totals, so a PASS under
    a suite whose teardown failed is reported as FAIL here (with the teardown message), and the result is then checked
    against <statistics><total><stat>: a disagreement is an error, never a quietly different number.
    """
    root = ET.parse(path).getroot()
    if root.tag != "robot":
        raise ValueError("not a Robot output.xml")
    out = []

    def walk(suite, prefix, teardown_failure):
        name = prefix + [suite.get("name", "")]
        st = suite.find("status")
        msg = (st.text or "").strip() if st is not None else ""
        if st is not None and st.get("status") == "FAIL" and msg.startswith("Suite teardown failed"):
            teardown_failure = teardown_failure or msg
        for t in suite.findall("test"):
            ts = t.find("status")
            if ts is None:
                raise ValueError("test %r has no status" % t.get("name"))
            status, text = ts.get("status"), (ts.text or "").strip()
            if status == "PASS" and teardown_failure:
                status, text = "FAIL", "counted as failed by Robot because the suite teardown failed (the test itself passed): " + teardown_failure
            out.append((".".join(name[1:] + [t.get("name", "")]) if len(name) > 1 else t.get("name", ""), status, text))
        for sub in suite.findall("suite"):
            walk(sub, name, teardown_failure)

    top = root.find("suite")
    if top is None:
        raise ValueError("no suite element")
    walk(top, [], "")
    stat = root.find("statistics/total/stat")
    if stat is None:
        raise ValueError("no statistics/total/stat: cannot check the counts against Robot's own")
    got = (sum(1 for _, s, _ in out if s == "PASS"), sum(1 for _, s, _ in out if s not in ("PASS", "SKIP")))
    want = (int(stat.get("pass")), int(stat.get("fail")))
    if got != want:
        raise ValueError("per-test statuses give pass/fail %s but Robot's statistics say %s" % (got, want))
    return out


def case_element(parent, name, status, message):
    tc = ET.SubElement(parent, "testcase", classname=ITEM, name=name)
    if status == "PASS":
        return tc
    if status == "SKIP":
        ET.SubElement(tc, "skipped", message=message[:300])
    else:
        f = ET.SubElement(tc, "failure", message=(message or status)[:300], type="AssertionError")
        f.text = message
    return tc


def suite_xml(name, cases):
    fails = sum(1 for _, s, _ in cases if s not in ("PASS", "SKIP"))
    skips = sum(1 for _, s, _ in cases if s == "SKIP")
    el = ET.Element("testsuite", name=name, tests=str(len(cases)), failures=str(fails), errors="0", skipped=str(skips))
    for n, s, m in cases:
        case_element(el, n, s, m)
    return el


def main():
    a = sys.argv[1:]
    vm = HERE
    if "--vm-dir" in a:
        i = a.index("--vm-dir")
        vm = Path(a[i + 1])
        del a[i:i + 2]
    results, tag, outdir, iso_sha, log = a
    out = Path(outdir)
    out.mkdir(parents=True, exist_ok=True)
    head = subprocess.run(["git", "-C", str(REPO), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    script = subprocess.run(["git", "-C", str(REPO), "show", head + ":vm/regression.sh"], capture_output=True, text=True).stdout
    suites = read_suites(script)
    expected = sum(r[3] for r in suites)
    all_cases, lines, failures = [], [], []
    for key, topo, file, want in suites:
        p = Path(results) / ("results-%s-%s" % (tag, key)) / "output.xml"
        try:
            tests = robot_tests(p)
            note = ""
        except (OSError, ET.ParseError, ValueError) as e:
            tests = [("suite-did-not-report", "FAIL", "%s: %s" % (p, e))]
            note = " (no usable output.xml)"
        if len(tests) != want and not note:
            tests.append(("suite-case-count", "FAIL", "ran %d cases, the SUITES table expects %d: cases went missing" % (len(tests), want)))
        named = [("%s/%s" % (key, n), s, m) for n, s, m in tests]
        ET.ElementTree(suite_xml("%s (%s)" % (key, file), named)).write(out / ("robot_81_cases.%s.junit.xml" % key), encoding="utf-8", xml_declaration=True)
        p_, f_ = sum(1 for _, s, _ in named if s == "PASS"), sum(1 for _, s, _ in named if s not in ("PASS", "SKIP"))
        lines.append("  %-6s %-6s pass=%-3d fail=%-3d expected=%d%s" % (key, topo, p_, f_, want, note))
        failures += ["    FAIL %s: %s" % (n, m[:200].replace("\n", " ")) for n, s, m in named if s not in ("PASS", "SKIP")]
        all_cases += named
    tot = len(all_cases)
    npass = sum(1 for _, s, _ in all_cases if s == "PASS")
    nfail = sum(1 for _, s, _ in all_cases if s not in ("PASS", "SKIP"))
    nskip = sum(1 for _, s, _ in all_cases if s == "SKIP")
    junit = out / (ITEM + ".junit.xml")
    ET.ElementTree(suite_xml(ITEM, all_cases)).write(junit, encoding="utf-8", xml_declaration=True)
    status = "PASS" if (nfail == 0 and nskip == 0 and npass == expected) else "FAIL"
    summary = ["robot regression, tag %s: %d passed, %d failed, %d skipped of %d expected" % (tag, npass, nfail, nskip, expected), *lines, *failures]
    (out / (ITEM + ".summary.txt")).write_text("\n".join(summary) + "\n")
    blob = subprocess.run(["git", "-C", str(REPO), "show", head + ":vm/regression.sh"], capture_output=True).stdout
    dirty = bool(subprocess.run(["git", "-C", str(REPO), "status", "--porcelain", "--untracked-files=no", "vm"], capture_output=True, text=True).stdout.strip())
    rec = {"item": ITEM, "iso_sha256": iso_sha, "suite_commit": head, "tool_commit": head, "status": status,
           "result_file": ITEM + ".junit.xml", "result_sha256": sha256(junit),
           "cases": {"total": tot, "passed": npass, "failed": nfail, "skipped": nskip},
           "suite_dirty": dirty, "generated_by": "toolkit/vm/regression.sh", "tool_sha256": hashlib.sha256(blob).hexdigest(),
           "fixture_log": Path(log).name, "fixture_log_sha256": sha256(log),
           "run": "regression.sh, tag %s, %d suites, %d cases expected (the SUITES table; 81 is the 2026-09-26 size)" % (tag, len(suites), expected)}
    (out / (ITEM + ".ev.json")).write_text(json.dumps({"format": "danos-verification-evidence-v2", "iso": "i-danos_2608_20261030T0752-amd64.hybrid.iso",
        "note": "developer claim derived from the Robot output.xml files by toolkit/vm/robot-to-junit.py; the final status is recomputed by the orchestrator",
        "records": [rec]}, indent=1) + "\n")
    print("\n".join(summary))
    sys.exit(0 if status == "PASS" else 1)


if __name__ == "__main__":
    main()
