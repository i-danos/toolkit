#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-only
"""Turn the output of whole-dp-run.sh into summary.json, summary.tsv and report.md.

Usage: whole-dp-report.py OUTDIR [--src REPO]

Status of a suite is derived only from what the run recorded, and "did not run" is never "pass":

  pass       meson rc 0, meson Ok 1, the check XML lists at least one test and none of them failed or errored
  empty-run  rc 0 but the suite asserted nothing (check XML with 0 tests, or "Checks: 0, Failures: 0, Errors: 0")
  fail       meson reported a failure (or the check XML lists failed/errored tests) and the process did not die by signal
  crash      the test binary was killed by a signal (SIGSEGV, SIGABRT ...)
  timeout    meson's own timeout, or the wrapper's hard cap
  skipped    meson reported the test as skipped
  no-result  anything else: the line says what was seen, nothing is assumed
  mixed      the suite was run more than once (--repeat, or --resume over an old file) and the iterations did not all agree
  not-run    registered with meson but absent from results.jsonl (interrupted run, or --only)
  excluded   named in check_tests but deliberately not registered (meson.build `suites_not_run`)

Triage labels (product-defect / env / flaky / unknown) are NOT guessed here: they come from OUTDIR/triage.json, a mapping
{suite: {"label": ..., "evidence": ..., "note": ...}} written by whoever read the logs. A non-pass suite without a label is
reported as "unlabelled".
"""
import json
import re
import subprocess
import sys
from collections import Counter, OrderedDict
from pathlib import Path

ANSI = re.compile(r"\x1b\[[0-9;]*m")


def read_jsonl(p):
    rows, bad = [], 0
    for ln in Path(p).read_text().splitlines():
        if not ln.strip():
            continue
        try:
            rows.append(json.loads(ln))
        except json.JSONDecodeError:
            bad += 1
    return rows, bad


def classify(r):
    if r.get("wrapper_timeout") or r.get("meson_timeout", 0) > 0:
        return "timeout"
    if r.get("signal"):
        return "crash"
    if r.get("meson_skip", 0) > 0 and r.get("meson_ok", 0) == 0:
        return "skipped"
    if r["rc"] == 0 and r.get("meson_ok", 0) == 1 and r.get("meson_fail", 0) == 0:
        if r.get("checks_0_line") or not r.get("xml") or r.get("checks", 0) == 0:
            return "empty-run"
        if r.get("check_failures", 0) or r.get("check_errors", 0):
            return "fail"
        return "pass"
    if r.get("meson_fail", 0) > 0 or r.get("check_failures", 0) or r.get("check_errors", 0):
        return "fail"
    return "no-result"


def first_error(logfile):
    """The first assertion location and the lines after it, ANSI stripped; or the last meson lines when there is none."""
    try:
        lines = [ANSI.sub("", x.rstrip()) for x in Path(logfile).read_text(errors="replace").splitlines()]
    except OSError:
        return ""
    for i, ln in enumerate(lines):
        if re.search(r"\.c \d+\s*$|\.c \d+ ", ln) and "BEGIN" not in ln:
            return " | ".join(x.strip() for x in lines[i:i + 3] if x.strip())[:300]
    for i, ln in enumerate(lines):
        if "stderr:" in ln or "Assertion" in ln or "killed by signal" in ln or "dataplane_test:" in ln:
            return " | ".join(x.strip() for x in lines[i:i + 3] if x.strip())[:300]
    return " | ".join(x.strip() for x in lines[-4:] if x.strip())[:300]


def declared_suites(src, commit):
    try:
        txt = subprocess.run(["git", "-C", str(src), "show", commit + ":tests/whole_dp/meson.build"], capture_output=True, text=True, check=True).stdout
    except (subprocess.CalledProcessError, OSError):
        return None, None
    m = re.search(r"check_tests\s*=\s*\[(.*?)\n\]", txt, re.S)
    names = re.findall(r"'(dp_test_[A-Za-z0-9_]+\.c)'", m.group(1)) if m else []
    n = re.search(r"suites_not_run\s*=\s*\[(.*?)\n\]", txt, re.S)
    excluded = re.findall(r"'(dp_test_[A-Za-z0-9_]+\.c)'", n.group(1)) if n else []
    return names, excluded


def family(s):
    t = s[len("dp_test_"):-2].split("_")
    return t[0]


def main():
    a = sys.argv[1:]
    src = None
    if "--src" in a:
        i = a.index("--src"); src = Path(a[i + 1]); del a[i:i + 2]
    out = Path(a[0])
    rows, bad = read_jsonl(out / "results.jsonl")
    last = OrderedDict()
    iters = {}
    for r in rows:
        iters.setdefault(r["suite"], []).append(r)
        # the representative row of a suite: the first non-passing iteration if there is one, else the last one
        cur = last.get(r["suite"])
        if cur is None or classify(cur) == "pass":
            last[r["suite"]] = r
    registered = [x for x in (out / "registered.txt").read_text().split() if x] if (out / "registered.txt").exists() else sorted(last)
    env = dict(x.split("=", 1) for x in (out / "env.txt").read_text().splitlines() if "=" in x) if (out / "env.txt").exists() else {}
    srcline = (out / "source.txt").read_text().strip() if (out / "source.txt").exists() else ""
    commit = srcline.split()[0] if srcline else ""
    src = src or Path(__file__).resolve().parent.parent.parent / "vyatta-dataplane"
    declared, excluded = declared_suites(src, commit) if commit else (None, None)
    triage = json.loads((out / "triage.json").read_text()) if (out / "triage.json").exists() else {}

    suites = []
    for s in registered:
        r = last.get(s)
        if r is None:
            suites.append({"suite": s, "status": "not-run", "family": family(s)})
            continue
        sts = [classify(x) for x in iters[s]]
        st = sts[0] if len(set(sts)) == 1 else "mixed"
        d = {"suite": s, "status": st, "family": family(s), **{k: r[k] for k in ("rc", "seconds", "checks", "check_failures", "check_errors", "signal") if k in r}}
        d["meson"] = {k.replace("meson_", ""): r[k] for k in r if k.startswith("meson_")}
        if len(sts) > 1:
            d["iterations"] = {"n": len(sts), **dict(Counter(sts))}
            d["seconds_each"] = [x["seconds"] for x in iters[s]]
        if st != "pass":
            d["first_error"] = first_error(out / "logs" / ((r.get("log") or s) + ".log"))
            t = triage.get(s)
            d["triage"] = t.get("label") if t else "unlabelled"
            if t:
                d["triage_evidence"] = t.get("evidence", "")
                if t.get("note"):
                    d["triage_note"] = t["note"]
        suites.append(d)
    for s in (excluded or []):
        suites.append({"suite": s, "status": "excluded", "family": family(s)})

    counts = Counter(x["status"] for x in suites)
    secs = sum(r["seconds"] for rs in iters.values() for r in rs)
    fam = {}
    for x in suites:
        f = fam.setdefault(x["family"], Counter()); f[x["status"]] += 1
    loads = [(r["load1_start"], r["mem_avail_mb_start"]) for r in last.values()]
    summary = OrderedDict([
        ("commit", commit), ("source", srcline), ("env", env),
        ("declared_in_check_tests", len(declared) if declared is not None else None),
        ("registered_by_meson", len(registered)), ("excluded_by_design", excluded),
        ("ran", len(last)), ("result_lines", len(rows)), ("counts", dict(counts)),
        ("seconds_in_suites", round(secs, 1)), ("results_lines_unparseable", bad),
        ("mem_avail_mb_min_during_run", min((m for _, m in loads), default=None)),
        ("load1_max_during_run", max((l for l, _ in loads), default=None)),
        ("families", {k: dict(v) for k, v in sorted(fam.items())}),
        ("suites", suites)])
    (out / "summary.json").write_text(json.dumps(summary, indent=1) + "\n")
    with open(out / "summary.tsv", "w") as f:
        f.write("suite\tfamily\tstatus\ttriage\trc\tseconds\tchecks\tcheck_failures\tcheck_errors\tsignal\n")
        for x in suites:
            f.write("\t".join(str(x.get(k, "")) for k in ("suite", "family", "status", "triage", "rc", "seconds", "checks", "check_failures", "check_errors", "signal")) + "\n")

    L = ["# whole_dp 单测分诊报告（机器生成部分）", "",
         "- 数据面提交：`%s`" % (srcline or "?"),
         "- DPDK / check：" + ", ".join("%s %s" % (k.split(":", 1)[1], v) for k, v in env.items() if k.startswith("pkg:")),
         "- `check_tests` 声明 %s 个；meson 实际注册 %d 个；刻意不注册 %s" % (len(declared) if declared is not None else "?", len(registered), excluded),
         "- 已运行 %d / 注册 %d；套件内累计耗时 %.0f 秒" % (len(last), len(registered), secs), "",
         "## 计数", "", "| 状态 | 数量 |", "|---|---|"]
    for k in ("pass", "fail", "crash", "timeout", "mixed", "empty-run", "skipped", "no-result", "not-run", "excluded"):
        L.append("| %s | %d |" % (k, counts.get(k, 0)))
    bad_ones = [x for x in suites if x["status"] not in ("pass", "excluded")]
    L += ["", "## 非通过项（%d）" % len(bad_ones), "", "| 套件 | 状态 | 分诊 | 关键行 |", "|---|---|---|---|"]
    for x in bad_ones:
        L.append("| `%s` | %s | %s | %s |" % (x["suite"], x["status"], x.get("triage", ""), (x.get("first_error", "") or "").replace("|", "\\|")))
    L += ["", "## 按功能族", "", "| 族 | 通过 | 非通过 | 合计 |", "|---|---|---|---|"]
    for k, v in sorted(fam.items()):
        tot = sum(v.values()); p = v.get("pass", 0)
        L.append("| %s | %d | %d | %d |" % (k, p, tot - p, tot))
    slow = sorted((x for x in suites if "seconds" in x), key=lambda x: -x["seconds"])[:8]
    L += ["", "## 最慢的 8 个套件", ""] + ["- `%s` %.1f 秒" % (x["suite"], x["seconds"]) for x in slow]
    (out / "report.generated.md").write_text("\n".join(L) + "\n")
    print(json.dumps({"counts": dict(counts), "registered": len(registered), "ran": len(last)}))


if __name__ == "__main__":
    main()
