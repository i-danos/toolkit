#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-only
"""dpa_object_model_interface_vlan: a VLAN sub-interface is enumerated as an interface object, survives a data-plane restart, and matches the CLI.

Usage: judge-dpa-object-model-interface-vlan.py <before.json> <after-config.json> <after-restart.json> <show-interfaces.txt> --parent dp0s4 --vid 100

The three JSON files are `dpa object show interface` (vplsh -c, JSON) captured before the sub-interface exists, after
`set interfaces dataplane <parent> vif <vid>` is committed, and after the data plane was restarted. <show-interfaces.txt> is the
operational `show interfaces` output taken with the sub-interface configured.

PASS needs: in every file the interface class is enumerable; the key if:<parent>.<vid> is absent before, present after the commit
and after the restart, with the same state and backend both times, and backend sw-dataplane; the parent object is present in
all three; and <parent>.<vid> appears in `show interfaces`.
"""
import re
import sys
from judgelib import fail, need, passed, read_json, read_text, run


def objects(path, what):
    d = read_json(path, what)
    o = need(d, "dpa_objects", what)
    cls = [c for c in need(o, "classes", what) if c.get("class") == "interface"]
    if not cls or not cls[0].get("enumerable"):
        fail("%s: the interface class is not enumerable" % what)
    return {x.get("key"): x for x in need(o, "objects", what) if x.get("class") == "interface"}


def main():
    args = sys.argv[1:]
    opts = {}
    for k in ("--parent", "--vid"):
        if k in args:
            i = args.index(k)
            opts[k] = args[i + 1]
            del args[i:i + 2]
    files = args
    if len(files) != 4 or "--parent" not in opts or "--vid" not in opts:
        fail("usage: judge-dpa-object-model-interface-vlan.py <before> <after-config> <after-restart> <show-interfaces.txt> --parent P --vid N")
    parent, vid = opts["--parent"], opts["--vid"]
    sub = "if:%s.%s" % (parent, vid)
    before, after, restart = (objects(f, w) for f, w in zip(files[:3], ("before", "after-config", "after-restart")))
    for name, o in (("before", before), ("after-config", after), ("after-restart", restart)):
        if "if:" + parent not in o:
            fail("%s: parent object if:%s is missing" % (name, parent))
    if sub in before:
        fail("before: %s is already enumerated, so the scenario proves nothing" % sub)
    if sub not in after:
        fail("after-config: %s is not enumerated" % sub)
    if sub not in restart:
        fail("after-restart: %s disappeared after the data plane restarted" % sub)
    a, r = after[sub], restart[sub]
    if (a.get("state"), a.get("backend")) != (r.get("state"), r.get("backend")):
        fail("%s changed across the restart: %s/%s -> %s/%s" % (sub, a.get("state"), a.get("backend"), r.get("state"), r.get("backend")))
    if a.get("backend") != "sw-dataplane":
        fail("%s backend is %r, expected sw-dataplane" % (sub, a.get("backend")))
    cli = read_text(files[3], "show interfaces")
    if not re.search(r"(?<![\w.])%s\.%s(?![\w.])" % (re.escape(parent), re.escape(vid)), cli):
        fail("%s.%s is not listed in `show interfaces`" % (parent, vid))
    passed("%s absent before, enumerated (%s/%s) after commit and after restart, listed in show interfaces" % (sub, a.get("state"), a.get("backend")))


if __name__ == "__main__":
    run(main)
