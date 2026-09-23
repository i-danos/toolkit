#!/usr/bin/env python3
"""Aggregate dpa-drift --watch JSONL without taking repair actions."""
import json, sys
from collections import defaultdict

def main(path):
    active = {}
    events = []
    for line in open(path):
        try: row=json.loads(line)
        except json.JSONDecodeError: continue
        if row.get('status') == 'unreadable' or row.get('error'):
            events.append({'type':'unreadable','cycle':row.get('cycle'),'timestamp':row.get('timestamp')})
            continue
        ts=row.get('timestamp'); cycle=row.get('cycle')
        current={}
        for item in row.get('disagreements',[]):
            key=(item.get('kind'),item.get('vrf'),item.get('prefix'))
            current[key]=item
            if key not in active:
                active[key]={'kind':key[0],'vrf':key[1],'prefix':key[2],
                             'first_cycle':cycle,'first_timestamp':ts}
            active[key]['last_cycle']=cycle; active[key]['last_timestamp']=ts
            active[key]['cycles']=item.get('cycles',1)
            # Carried through, not recomputed: dpa-drift.py's own state
            # machine already decided these, and an aggregator second-guessing
            # them from cycle counts alone would drop the reason a route
            # stopped mattering (source_mismatch, say) the moment it also
            # happened to persist long enough to look like drift.
            active[key]['classification']=item.get('classification')
            active[key]['state']=item.get('state')
        for key in list(active):
            if key not in current:
                event=dict(active.pop(key)); event['type']='resolved'; events.append(event)
    for event in active.values():
        event=dict(event); event['type']='active'; events.append(event)
    print(json.dumps({'schema_version':1,'events':events,'read_only':True},indent=2))

if __name__ == '__main__':
    if len(sys.argv)!=2: raise SystemExit('usage: dpa-drift-history.py <watch.jsonl>')
    main(sys.argv[1])
