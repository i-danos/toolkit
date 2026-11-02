#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-only
"""dpa_object_model_extension: the object classes the model is meant to be extended with are enumerable.

PRODUCT-SIDE DEPENDENCY: vyatta-dataplane's dpa_classes[] (src/dpa_object.c) has no tunnel and no ACL/firewall class at all, and
mk-release.py records the two QoS classes as not enumerable. Until the data plane makes those classes enumerable this judge
FAILs on any real capture and the item stays NOT_RUN. It does not change when the product does not.

Usage: judge-dpa-object-model-extension.py <classes.json> [--require tunnel,acl,qos-if,qos-vlan]

<classes.json> `dpa object show` JSON (the "classes" array is what is read). --require: class names that must be enumerable
(default tunnel,acl,qos-if,qos-vlan; the orchestrator fixes the real names when the product defines them).

PASS needs: every required class present in "classes" with enumerable true.
"""
import sys
from judgelib import fail, need, passed, read_json, run

DEFAULT = ["tunnel", "acl", "qos-if", "qos-vlan"]


def main():
    args = sys.argv[1:]
    req = DEFAULT
    if "--require" in args:
        i = args.index("--require")
        req = [x for x in args[i + 1].split(",") if x]
        del args[i:i + 2]
    if len(args) != 1 or not req:
        fail("usage: judge-dpa-object-model-extension.py <classes.json> [--require a,b,c]")
    d = read_json(args[0], "dpa object classes")
    classes = {c.get("class"): c for c in need(need(d, "dpa_objects", "dpa object classes"), "classes", "dpa object classes")}
    missing = [c for c in req if c not in classes]
    if missing:
        fail("class(es) not defined by the data plane: %s" % ", ".join(missing))
    off = [c for c in req if not classes[c].get("enumerable")]
    if off:
        fail("class(es) defined but not enumerable: %s" % ", ".join(off))
    passed("all of %s are enumerable" % ", ".join(req))


if __name__ == "__main__":
    run(main)
