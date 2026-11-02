#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-only
"""drift_event_correlation_broker_dp_transactions: brokerd's deliveries are matched by data-plane COMPLETION records.

PRODUCT-SIDE DEPENDENCY: today the data plane logs nothing when it finishes programming a delivered route (DP_DEBUG(ROUTE,
NOTICE) fires only on failure) and brokerd's journal is empty, so there is no completion record to read. This judge states what
a passing capture would have to contain; against a real capture from the current product it FAILs, and the item stays NOT_RUN
until vyatta-dataplane emits a success/completion record. A netlink "delivery" row is not a substitute (that is the
drift_event_correlation_netlink item).

Usage: judge-drift-event-correlation-broker-dp-transactions.py <transactions.json>

<transactions.json> {"transactions": [{"prefix": P, "delivery": {...timestamp...}, "completion": {...timestamp, "result": "ok"}|null}]}
                    -- a format PROPOSED for the future correlator, not produced by any tool today.

PASS needs: at least one transaction; each has a delivery and a completion whose result is "ok"; completion not before delivery.
"""
import sys
from judgelib import fail, need, passed, read_json, run


def main():
    if len(sys.argv) != 2:
        fail("usage: judge-drift-event-correlation-broker-dp-transactions.py <transactions.json>")
    doc = read_json(sys.argv[1], "broker/data-plane transactions")
    tx = need(doc, "transactions", "broker/data-plane transactions")
    if not tx:
        fail("no transactions in the capture (the product currently emits no completion record to build them from)")
    for t in tx:
        d, c = t.get("delivery"), t.get("completion")
        if not d:
            fail("transaction %s has no delivery record" % t.get("prefix"))
        if not c:
            fail("transaction %s was delivered but has no completion record" % t.get("prefix"))
        if c.get("result") != "ok":
            fail("transaction %s completed with result %r" % (t.get("prefix"), c.get("result")))
        if float(c.get("timestamp", -1)) < float(d.get("timestamp", 0)):
            fail("transaction %s completed before it was delivered" % t.get("prefix"))
    passed("%d transaction(s), every delivery matched by an ok completion" % len(tx))


if __name__ == "__main__":
    run(main)
