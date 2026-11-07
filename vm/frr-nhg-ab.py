#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-only
"""A/B measurement of zebra's "stuck kernel nexthop group" on a QEMU topology with two parallel links (boot-topo.sh TOPO=nhg).

The defect (toolkit/frr-patches/README.md, docs/DEFECTS.md 2026-10-04/05): after a link failure zebra can leave the KERNEL route pointing at
an equal-cost nexthop group that still contains the dead member, for 18-62 s; router-originated flows whose (source, destination) address
pair hashes to that member are blackholed, while forwarded traffic is not affected because the data plane's table is right.

Topology (r1 is the router under test):   r3 --(dp0s8)-- r1 ==(dp0s9, dp0s10: two parallel links)== r2.
OSPF on all three, 8 loopback addresses per router (10.255.<n>.1-8) used as probe sources. Three kinds of flow, 8 each:
  F   r3 -> 10.255.2.1   FORWARDED through r1 (data plane)
  O1  r1 -> 10.255.2.1   ORIGINATED by r1 (kernel route)
  O2  r2 -> 10.255.1.1   ORIGINATED by r2 (kernel route)
The cut is a cable pull: QEMU `set_link <id> off` on BOTH ends of one link, so both routers see carrier loss at once (taking the carrier
down on one end only leaves the peer unaware and measures OSPF dead timers instead).

Per run: wait until every router holds a 2-member group, start frr-nhg-guest.sh on the three routers, cut link A or B at +5 s (alternating),
restore after --cut seconds, collect the guests' files, wait for the topology to converge again. Measured per run, in each guest's own clock:
  (a) kernel_move_s   time from the link loss (operstate leaving 'up') to the first kernel route whose nexthop group no longer contains the dead interface
                      (None = it never did before the link came back = stuck for the whole cut)
  (b) F   longest silence of a forwarded flow after the cut
  (c) O1/O2 longest silence of a router-originated flow after the cut
A flow is "affected" when its longest silence exceeds 1 s. Nothing is estimated: every number comes from the raw files kept under OUT/.

Usage:  frr-nhg-ab.py configure
        frr-nhg-ab.py install-frr DEBDIR                     (group B: dpkg -i frr*.deb on the three routers; do it BEFORE configure)
        frr-nhg-ab.py run --group A|B --n N --out DIR [--first-run K] [--cut 75] [--total 108]
        frr-nhg-ab.py analyze DIR [DIR...]                    -> results.jsonl and summary.json next to each DIR
"""
import argparse
import io
import json
import os
import re
import socket
import statistics
import subprocess
import sys
import tarfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
RUN = Path(os.environ.get("OBS_DIR", "/home/aikon/danos/.obs")) / "run"
ADDR = {"r1": 155, "r2": 156, "r3": 157}
SSH = ["docker", "exec", "-i", "danos-robot", "sshpass", "-p", "vyatta", "ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
       "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=8"]
LINKS = {"A": "dp0s9", "B": "dp0s10"}          # link A is r1.dp0s9<->r2.dp0s9 (netdev id "la"), link B is dp0s10 (id "lb")
NETDEV = {"A": "la", "B": "lb"}
PEER_LO = {"r1": "10.255.2.1", "r2": "10.255.1.1"}


def ssh(r, cmd, inp=None, timeout=120):
    p = subprocess.run(SSH + ["vyatta@192.168.203.%d" % ADDR[r], cmd], input=inp, capture_output=True, timeout=timeout)
    return p.returncode, p.stdout.decode(errors="replace"), p.stderr.decode(errors="replace")


def monitor(r, cmd):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(5)
    s.connect(str(RUN / r / "monitor.sock"))
    try:
        s.recv(4096)
    except socket.timeout:
        pass
    s.sendall((cmd + "\n").encode())
    time.sleep(0.25)
    try:
        s.recv(4096)
    except socket.timeout:
        pass
    s.close()


def set_link(link, state):
    t0 = time.time()
    for r in ("r1", "r2"):
        monitor(r, "set_link %s %s" % (NETDEV[link], state))
    return t0, time.time()


# ---------------------------------------------------------------- configuration
def config_commands():
    c = {"r1": ["set interfaces dataplane dp0s8 address 10.0.1.1/24", "set interfaces dataplane dp0s9 address 10.0.2.1/24",
                "set interfaces dataplane dp0s10 address 10.0.3.1/24"],
         "r2": ["set interfaces dataplane dp0s9 address 10.0.2.2/24", "set interfaces dataplane dp0s10 address 10.0.3.2/24"],
         "r3": ["set interfaces dataplane dp0s8 address 10.0.1.3/24"]}
    for n, r in ((1, "r1"), (2, "r2"), (3, "r3")):
        for i in range(1, 9):
            c[r].append("set interfaces loopback lo%d address 10.255.%d.%d/32" % (i, n, i))
        c[r] += ["set protocols ospf parameters router-id 10.255.%d.1" % n, "set protocols ospf area 0 network 10.0.0.0/16",
                 "set protocols ospf area 0 network 10.255.0.0/16"]
    return c


def cli(r, cmds):
    body = "SID=$$\neval \"$(cli-shell-api getSessionEnv $SID)\"\ncli-shell-api setupSession\n"
    for c in cmds:
        body += "o=$(vcli -s $SID -c '%s' 2>&1 | grep -v 'Node exists'); [ -n \"$o\" ] && echo \"CFG: %s => $o\"\n" % (c, c)
    body += "vcli -s $SID -c commit 2>&1\necho COMMIT_DONE\ncli-shell-api teardownSession\n"
    return ssh(r, "bash -s", inp=body.encode(), timeout=300)


def configure(p2p):
    for r, cmds in config_commands().items():
        extra = []
        if p2p:
            extra = ["set interfaces dataplane %s ip ospf network point-to-point" % i for i in {"r1": ["dp0s8", "dp0s9", "dp0s10"], "r2": ["dp0s9", "dp0s10"], "r3": ["dp0s8"]}[r]]
        rc, out, err = cli(r, cmds + extra)
        print("%s: rc=%d %s" % (r, rc, " | ".join(l for l in out.splitlines() if "CFG" in l or "ail" in l or "rror" in l or "COMMIT" in l)[:300]))
        if "COMMIT_DONE" not in out:
            print(out[-400:], err[-300:])
            return 1
    return 0


def install_frr(debdir):
    debs = sorted(Path(debdir).glob("frr*.deb"))
    debs = [d for d in debs if "dbgsym" not in d.name]
    if not debs:
        print("no frr*.deb in", debdir); return 1
    for r in ("r1", "r2", "r3"):
        for d in debs:
            rc, _, err = ssh(r, "cat > /tmp/%s" % d.name, inp=d.read_bytes(), timeout=300)
            if rc != 0:
                print(r, "copy failed", err[:200]); return 1
        rc, out, err = ssh(r, "sudo -n dpkg -i %s 2>&1 | tail -4; dpkg-query -W -f='${Package} ${Version}\\n' frr" % " ".join("/tmp/" + d.name for d in debs), timeout=600)
        print("%s: %s" % (r, " | ".join(out.strip().splitlines()[-3:])))
        if "danos" not in out:
            return 1
    return 0


# ---------------------------------------------------------------- state parsing
def parse_nh(lines):
    """`ip nexthop show` -> {id: {'group': [ids]} | {'dev': dev}}"""
    t = {}
    for ln in lines:
        m = re.match(r"id (\d+) group ([\d/,]+)", ln)
        if m:
            t[int(m[1])] = {"group": [int(x.split(",")[0]) for x in m[2].split("/")]}      # "17,2/25,1": member id, then its weight
            continue
        m = re.match(r"id (\d+) .*? dev (\S+)", ln)
        if m:
            t[int(m[1])] = {"dev": m[2]}
    return t


def devs_of_route(rt, table):
    """The set of interfaces the kernel route would use, from `ip route show` text and a nexthop table."""
    m = re.search(r"nhid (\d+)", rt)
    if m:
        def devs(i, depth=0):
            e = table.get(i)
            if e is None or depth > 3:
                return None
            if "dev" in e:
                return {e["dev"]}
            out = set()
            for g in e["group"]:
                d = devs(g, depth + 1)
                if d is None:
                    return None
                out |= d
            return out
        return devs(int(m[1]))
    ds = set(re.findall(r"dev (\S+)", rt))
    return ds or set()


def two_members(r):
    rc, out, _ = ssh(r, "ip route show %s; ip nexthop show" % PEER_LO[r], timeout=20)
    lines = out.splitlines()
    rt = "\n".join(l for l in lines if not l.startswith("id "))
    d = devs_of_route(rt, parse_nh([l for l in lines if l.startswith("id ")]))
    return d is not None and d >= {"dp0s9", "dp0s10"}


def converged(timeout):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            if two_members("r1") and two_members("r2"):
                rc, out, _ = ssh("r3", "ping -c1 -W1 10.255.2.1 >/dev/null 2>&1 && echo OK", timeout=20)
                if "OK" in out:
                    return round(time.time() - t0, 1)
        except subprocess.TimeoutExpired:
            pass
        time.sleep(3)
    return None


# ---------------------------------------------------------------- one run
def one_run(link, outdir, cut, total):
    outdir.mkdir(parents=True, exist_ok=True)
    meta = {"link": link, "dead_if": LINKS[link], "cut_s": cut, "total_s": total}
    pre = converged(150)
    meta["precondition_converged_s"] = pre
    if pre is None:
        meta["error"] = "topology not converged before the run"
        (outdir / "run.json").write_text(json.dumps(meta, indent=1))
        return meta
    script = (HERE / "frr-nhg-guest.sh").read_bytes()
    for r in ("r1", "r2", "r3"):
        ssh(r, "cat > /tmp/nhg-guest.sh", inp=script)
    meta["start_host"] = time.time()
    for r in ("r1", "r2", "r3"):
        ssh(r, "sudo -n setsid bash -c 'nohup bash /tmp/nhg-guest.sh %s %d </dev/null >/tmp/nhg-guest.out 2>&1 &'" % (r, total), timeout=30)
    time.sleep(5)
    meta["cut_host"] = set_link(link, "off")
    time.sleep(cut)
    meta["restore_host"] = set_link(link, "on")
    time.sleep(max(0, total - 5 - cut) + 6)
    for r in ("r1", "r2", "r3"):
        rc2 = subprocess.run(SSH + ["vyatta@192.168.203.%d" % ADDR[r], "sudo -n tar -C /tmp -czf - nhg"], capture_output=True, timeout=120)
        tarfile.open(fileobj=io.BytesIO(rc2.stdout)).extractall(outdir / r)
    meta["restore_converged_s"] = converged(150)
    if meta["restore_converged_s"] is None:
        meta["error"] = "topology did not converge after the link came back (within 150 s)"
    (outdir / "run.json").write_text(json.dumps(meta, indent=1))
    return meta


# ---------------------------------------------------------------- analysis
def read_route_log(path):
    rows = []
    for ln in Path(path).read_text(errors="replace").splitlines():
        p = ln.split("|", 3)
        if len(p) == 4:
            try:
                rows.append((float(p[0]), p[1], p[2], p[3]))
            except ValueError:
                pass
    return rows


def read_nh_log(path):
    dumps, cur = [], None
    if not Path(path).exists():
        return dumps
    for ln in Path(path).read_text(errors="replace").splitlines():
        if ln.startswith("N|") and "nhid=" in ln:
            t = float(ln.split("|")[1])
            cur = (t, [])
            dumps.append(cur)
        elif ln.startswith("N|") and cur:
            cur[1].append(ln[2:])
    return [(t, parse_nh(l)) for t, l in dumps]


def table_at(dumps, t):
    best = {}
    for dt, tab in dumps:
        if dt <= t:
            best = tab
    return best


def start_time(d):
    m = re.search(r"S0=([\d.]+)", (Path(d) / "nhg" / "start.txt").read_text())
    return float(m[1])


def kernel_view(rdir, dead_if):
    rows = read_route_log(rdir / "nhg" / "route.log")
    dumps = read_nh_log(rdir / "nhg" / "nh.log")
    col = 1 if dead_if == "dp0s9" else 2
    t_cut = t_restore = None
    prev_up = False
    for row in rows:
        c = row[col]                      # operstate: "up" is up; "dormant" (the data plane's way to say no carrier), "down", "x" are not
        if c == "up":
            prev_up = True
            if t_cut is not None and t_restore is None:
                t_restore = row[0]
        elif prev_up and t_cut is None:
            t_cut = row[0]
    out = {"t_cut": t_cut, "t_restore": t_restore, "dead_if": dead_if}
    if t_cut is None:
        out["error"] = "no operstate change away from up seen on %s" % dead_if
        return out
    end = t_restore or rows[-1][0]
    moved = None
    empty_since = None
    for t, c9, c10, rt in rows:
        if t < t_cut or t > end:
            continue
        ds = devs_of_route(rt, table_at(dumps, t))
        if ds is None:
            continue
        if not ds:
            empty_since = empty_since or t
            continue
        if dead_if not in ds:
            moved = t
            break
    out["kernel_move_s"] = round(moved - t_cut, 3) if moved else None
    out["window_s"] = round(end - t_cut, 3)
    out["route_empty_s"] = round(empty_since - t_cut, 3) if empty_since else None
    return out


def flow_gaps(rdir, ref_cut, ref_restore, s0_guest, total):
    """Longest silence per flow: gaps between consecutive replies whose start lies in [cut-0.5, restore]. A flow that never answers again is
    measured to the end of its log (S0 + total - 1). ref_cut/ref_restore are offsets from the guest's S0."""
    res = {}
    lo, hi, end = s0_guest + ref_cut - 0.5, s0_guest + ref_restore, s0_guest + total - 1
    for f in sorted((rdir / "nhg").glob("ping-*.log")):
        ts = [float(m[1]) for m in (re.match(r"\[([\d.]+)\] .*bytes from", ln) for ln in f.read_text(errors="replace").splitlines()) if m]
        if len(ts) < 10:
            res[f.name] = {"replies": len(ts), "max_gap_s": None}
            continue
        n = len(ts)
        if ts[-1] < end - 1:
            ts.append(end)
        gaps = [b - a for a, b in zip(ts, ts[1:]) if lo <= a <= hi]
        res[f.name] = {"replies": n, "max_gap_s": round(max(gaps, default=0.05), 3)}
    return res


def analyze_run(rundir):
    rundir = Path(rundir)
    meta = json.loads((rundir / "run.json").read_text())
    out = {"run": rundir.name, "link": meta.get("link"), "error": meta.get("error")}
    if not (rundir / "r1" / "nhg" / "route.log").exists():
        return out
    dead = meta["dead_if"]
    k1, k2 = kernel_view(rundir / "r1", dead), kernel_view(rundir / "r2", dead)
    out["r1"], out["r2"] = k1, k2
    if k1.get("t_cut") is None or k2.get("t_cut") is None:
        out["error"] = out.get("error") or "link loss (operstate) not seen on both routers"
        return out
    off_cut = k1["t_cut"] - start_time(rundir / "r1")
    off_restore = (k1["t_restore"] or (k1["t_cut"] + meta["cut_s"])) - start_time(rundir / "r1")
    out["flows"] = {}
    for r, tag in (("r1", "O1"), ("r2", "O2"), ("r3", "F")):
        g = flow_gaps(rundir / r, off_cut, off_restore, start_time(rundir / r), meta["total_s"])
        out["flows"][tag] = g
    frr = (rundir / "r1" / "nhg" / "start.txt").read_text()
    out["frr_pkg"] = (re.search(r"frr_pkg=(\S+)", frr) or [None, None])[1]
    out["restore_converged_s"] = meta.get("restore_converged_s")
    return out


def summarise(rows):
    def stat(vals):
        v = [x for x in vals if x is not None]
        return {"n": len(v), "median": round(statistics.median(v), 2) if v else None, "max": round(max(v), 2) if v else None}
    ok = [r for r in rows if "flows" in r]
    s = {"runs": len(rows), "runs_analysed": len(ok), "errors": [(r["run"], r["error"]) for r in rows if r.get("error")]}
    kms = []
    for r in ok:
        for rt in ("r1", "r2"):
            v = r[rt].get("kernel_move_s")
            kms.append(r[rt]["window_s"] if v is None else v)        # never moved: at least the whole cut window
    s["kernel_move_s_per_router_run"] = stat(kms)
    s["kernel_never_moved_in_window"] = sum(1 for r in ok for rt in ("r1", "r2") if r[rt].get("kernel_move_s") is None)
    s["kernel_move_over_5s"] = sum(1 for v in kms if v > 5)
    s["runs_with_a_stuck_kernel_group_on_either_router"] = sum(1 for r in ok if any((r[rt].get("kernel_move_s") is None or r[rt]["kernel_move_s"] > 5) for rt in ("r1", "r2")))
    for tag in ("F", "O1", "O2"):
        worst = [max((f["max_gap_s"] or 0) for f in r["flows"][tag].values()) for r in ok]
        aff = [sum(1 for f in r["flows"][tag].values() if (f["max_gap_s"] or 0) > 1.0) for r in ok]
        s["flow_%s" % tag] = {"worst_silence_per_run_s": stat(worst), "affected_flows_of_8_per_run": stat(aff),
                              "runs_with_any_flow_over_1s": sum(1 for a in aff if a > 0), "runs_with_any_flow_over_10s": sum(1 for w in worst if w > 10)}
    s["restore_not_converged_in_150s"] = sum(1 for r in rows if r.get("error") and "did not converge" in (r["error"] or ""))
    return s


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("configure"); c.add_argument("--no-p2p", action="store_true")
    i = sub.add_parser("install-frr"); i.add_argument("debdir")
    r = sub.add_parser("run"); r.add_argument("--group", required=True); r.add_argument("--n", type=int, required=True); r.add_argument("--out", required=True)
    r.add_argument("--first-run", type=int, default=1); r.add_argument("--cut", type=int, default=75); r.add_argument("--total", type=int, default=108)
    a = sub.add_parser("analyze"); a.add_argument("dirs", nargs="+")
    x = ap.parse_args()
    if x.cmd == "configure":
        return configure(not x.no_p2p)
    if x.cmd == "install-frr":
        return install_frr(x.debdir)
    if x.cmd == "run":
        out = Path(x.out)
        for k in range(x.first_run, x.first_run + x.n):
            link = "AB"[(k - 1) % 2]
            m = one_run(link, out / ("run%02d" % k), x.cut, x.total)
            print("run%02d link=%s %s" % (k, link, m.get("error") or "ok (restore converged in %ss)" % m.get("restore_converged_s")), flush=True)
        return 0
    for d in x.dirs:
        d = Path(d)
        rows = [analyze_run(p) for p in sorted(d.glob("run*")) if (p / "run.json").exists()]
        (d / "results.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
        s = summarise(rows)
        (d / "summary.json").write_text(json.dumps(s, indent=1) + "\n")
        print(d, json.dumps(s))
    return 0


if __name__ == "__main__":
    sys.exit(main())
