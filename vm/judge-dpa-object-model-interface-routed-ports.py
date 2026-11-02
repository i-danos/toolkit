#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-only
"""dpa_object_model_interface_routed_ports: every routed physical port is an interface object, reported as not needed by the offload backend, and the set matches the CLI.

Usage: judge-dpa-object-model-interface-routed-ports.py <interface-class.json> <show-interfaces.txt> --port dp0s3 [--port dp0s4 ...]

<interface-class.json> `dpa object show interface` (JSON); <show-interfaces.txt> the operational `show interfaces`.
--port                 the routed data-plane ports the scenario has (at least one)

PASS needs: the interface class enumerable; each --port present as if:<port> with state not_needed and backend sw-dataplane;
no loopback object; every dpNsM port the CLI lists is an object and every plain dpNsM object is listed by the CLI (no sub-interface
is counted as a port); and no object in an error state.
"""
import re
import sys
from judgelib import fail, need, passed, read_json, read_text, run

PORT = re.compile(r"^dp\d+s\d+$")


def main():
    args = sys.argv[1:]
    ports = [args[i + 1] for i, a in enumerate(args) if a == "--port" and i + 1 < len(args)]
    files = [a for i, a in enumerate(args) if not a.startswith("--") and (i == 0 or args[i - 1] != "--port")]
    if len(files) != 2 or not ports:
        fail("usage: judge-dpa-object-model-interface-routed-ports.py <interface-class.json> <show-interfaces.txt> --port P [--port P ...]")
    d = read_json(files[0], "interface class")
    o = need(d, "dpa_objects", "interface class")
    cls = [c for c in need(o, "classes", "interface class") if c.get("class") == "interface"]
    if not cls or not cls[0].get("enumerable"):
        fail("the interface class is not enumerable")
    objs = {x.get("key"): x for x in need(o, "objects", "interface class") if x.get("class") == "interface"}
    for p in ports:
        x = objs.get("if:" + p)
        if x is None:
            fail("port %s is not enumerated as an interface object" % p)
        if x.get("state") != "not_needed" or x.get("backend") != "sw-dataplane":
            fail("port %s is %s/%s, expected not_needed/sw-dataplane" % (p, x.get("state"), x.get("backend")))
    if "if:lo" in objs:
        fail("the loopback is enumerated as an interface object")
    bad = [k for k, x in objs.items() if x.get("state") == "error"]
    if bad:
        fail("object(s) in an error state: %s" % ", ".join(bad))
    obj_ports = {k[3:] for k in objs if PORT.match(k[3:])}
    cli = read_text(files[1], "show interfaces")
    cli_ports = {m for m in re.findall(r"(?<![\w.])(dp\d+s\d+)(?![\w.])", cli)}
    if cli_ports - obj_ports:
        fail("`show interfaces` lists port(s) with no object: %s" % ", ".join(sorted(cli_ports - obj_ports)))
    if obj_ports - cli_ports:
        fail("object(s) for port(s) `show interfaces` does not list: %s" % ", ".join(sorted(obj_ports - cli_ports)))
    passed("%d routed port(s) enumerated not_needed/sw-dataplane, no loopback, objects and CLI list the same ports %s" % (len(ports), sorted(obj_ports)))


if __name__ == "__main__":
    run(main)
