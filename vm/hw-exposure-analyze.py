#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Per-flow loss inside each outage window, from the probe logs hw-exposure-flows.py leaves.

Reads flows/flow_*.txt (ping -D -O output), flows/offset (R2 clock minus R1 clock) and ctrl.log.
A flow is "partial" if it lost more than 2% of probes in a window after the first second, and
"BLACKHOLED" if it lost 50% or more. Equal loss fractions across flows in one cycle mean they were
blocked for the same period (a shared stuck group), not that they were hashed differently.
"""
import re,glob,os,collections
off=float(open("flows/offset").read())          # R2 clock minus R1 clock
cyc=[]; cur={}
for l in open("ctrl.log"):
    m=re.match(r"\S+ (DOWN|UP) cycle (\d+) r1_epoch=([\d.]+)",l)
    if m: cur.setdefault(int(m.group(2)),{})[m.group(1)]=float(m.group(3))
CY=[(k,cur[k]["DOWN"],cur[k]["UP"]) for k in sorted(cur)]
def parse(path):
    got={}; lost={}
    for l in open(path):
        m=re.match(r"\[([\d.]+)\] 64 bytes from \S+: icmp_seq=(\d+)",l)
        if m: got[int(m.group(2))]=float(m.group(1)); continue
        m=re.match(r"\[([\d.]+)\] no answer yet for icmp_seq=(\d+)",l)
        if m: lost[int(m.group(2))]=float(m.group(1))
    return got,lost
def window_stats(got,lost,t0,t1,shift):
    # probes whose send time falls in the window; lost = no reply ever
    ts=sorted((t-shift) for s,t in lost.items() if s not in got)
    inw=[t for t in ts if t0+1.0<=t<t1]            # ignore the first second (detection)
    nprobe=int((t1-t0-1.0)/0.2)
    # longest consecutive run (probes are 0.2 s apart)
    best=cur_run=0; prev=None
    for t in inw:
        cur_run=cur_run+1 if prev is not None and t-prev<0.45 else 1
        best=max(best,cur_run); prev=t
    return len(inw),nprobe,best*0.2
def classify(frac): return "BLACKHOLED" if frac>=0.5 else ("partial" if frac>0.02 else "ok")
rows=[]
for path in sorted(glob.glob("flows/flow_*.txt")):
    n,src,dst=re.match(r"flows/flow_(R\d)_(\S+)_(\S+)\.txt",path).groups()
    got,lost=parse(path); shift=off if n=="R2" else 0.0
    res=[]
    for k,d,u in CY:
        nl,np_,run=window_stats(got,lost,d,u,shift); frac=nl/np_ if np_ else 0
        res.append((classify(frac),frac,run))
    rows.append((n,src,dst,res))
print("== ICMP flows: per outage cycle (loss fraction inside the 80 s window; B=blackholed >=50%, p=partial, .=ok)")
print("%-3s %-14s -> %-13s  %s"%("rtr","source","dest","  ".join("c%d"%k for k,_,_ in CY)))
tot=collections.Counter()
for n,src,dst,res in rows:
    cells="  ".join(("B" if c=="BLACKHOLED" else ("p" if c=="partial" else "."))+"%3d%%"%round(f*100) for c,f,_ in res)
    print("%-3s %-14s -> %-13s  %s"%(n,src,dst,cells))
    for c,f,r_ in res: tot[(n,c)]+=1
print()
for n in ("R1","R2"):
    t=sum(v for (a,c),v in tot.items() if a==n)
    print("%s originated flow-cycles: %d  blackholed %d (%.0f%%)  partial %d  ok %d"%(n,t,tot[(n,"BLACKHOLED")],100*tot[(n,"BLACKHOLED")]/t,tot[(n,"partial")],tot[(n,"ok")]))
print()
print("== per cycle, fraction of flows blackholed")
for i,(k,d,u) in enumerate(CY):
    for n in ("R1","R2"):
        rr=[r[i] for (nn,s,dd,res) in rows if nn==n for r in [res[i]]]
        b=sum(1 for c,f,_ in rr if c=="BLACKHOLED"); print("cycle %d %s: %d/%d flows blackholed"%(k,n,b,len(rr)))
