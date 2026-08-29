# Dataplane segfault in rte_acl_classify_scalar on the crypto policy path

Status: **resolved.** The cause was the ACL trie being rebuilt while forwarding
threads were still traversing it, which became possible when retiring the DANOS
DPDK fork replaced `rte_acl_rcu_qsbr_add` with a stub. Fixed in
`vyatta-dataplane` 3.14.33, with the related rule-deletion stubs fixed in
3.14.34. See defects 6 and 7 in `DEFECTS.md`.

The rest of this file is kept as written *before* the cause was known. It is
worth reading for the wrong turns rather than the conclusion — in particular the
gdb `Cannot access memory` that looked like a use-after-free and was a hugepage
the core simply did not capture.

## Signature

```
dataplane/slow[…]: segfault at 0 ip …4db error 4
    in librte_acl.so.25.0[54db,…+11000]
```

Symbolised, on vyatta-dataplane 3.14.32, DANOS 2608, DPDK 24.11:

```
#0  rte_acl_classify_scalar+299   mov (%r8),%ecx      with %r8 == 0
#1  npf_rte_acl_trie_match        npf_rte_acl.c:1543
#2  npf_rte_acl_match
#3  rldb_match
#4  crypto_policy_check_outbound
#5  shadow_crypto_output
#6  shadow_feature_if_output
#7  shadow_output
#8  tap_reader                    shadow.c
```

Frame 1 locals: `af=2`, `m_trie=0x128d48b00`, `npc=0x0`.

`%r8 == 0` at that instruction is a null ACL runtime — `rte_acl_classify()`
reached a context whose `trans_table` is not set, which happens when the
context was created but `rte_acl_build()` has not (successfully) run on it, or
when its runtime was released underneath the caller.

## Reproduction

Not deterministic. The DANOS `IPSEC_VPN_DANOS.robot` suite against a
three-router topology produced it on one router (r3) in two runs out of four.
The other two runs of the same suite on the same build produced no crash. Suite
results were 3–4 passed of 10 in every run, with and without the crash, so the
pass count is not a proxy for it.

A single-machine harness — configure a site-to-site policy, delete it, restart
the dataplane — does **not** reproduce this one. It reproduces a different
defect (see "Not this defect" below).

## What has been ruled out

**Not a missing "is it built" check.** `npf_rte_acl_trie_match()` originally
gated only on `m_trie->num_rules`, which counts a rule as soon as it is added
while the runtime is built later. An `acl_built` flag was added (3.14.29),
cleared at every point the rule set changes and again before `rte_acl_reset()`
(3.14.30). Crash rate fell — 566 in one early run, then 13, then 1 — and the
crash remained. Narrowing a window is not closing it.

**Not the trie being destroyed without a grace period.** 3.14.32 changed
`npf_rte_acl_delete_trie()` from

```c
cds_list_del(&m_trie->trie_link);
npf_rte_acl_trie_destroy(ctx->af, m_trie);
```

to `cds_list_del_rcu()` plus `call_rcu()`, and moved `npf_rte_acl_match()` to
the `_rcu` list walk. The readers are RCU-visible — `tap_reader()` brackets
`shadow_output()` with `dp_rcu_thread_online()`/`offline()` — so the deferral
does apply to them. The crash survived unchanged.

**Not a use-after-free of the trie structure, on the evidence available.** In
gdb, `p *m_trie` reports

```
Cannot access memory at address 0x128d48b00
```

which reads like freed memory and was initially taken that way. It is not.
`info proc mappings` on the same core places that address inside

```
0x128c00000  0x128e00000  0x200000  0x0  /dev/hugepages/rtemap_325
```

a live hugepage mapping. systemd-coredump does not capture file-backed huge
pages by default (`coredump_filter` is `0x23`), so the pages are absent from
the core and gdb cannot read them. **The trie contents at the moment of the
crash are simply unknown**, not known-bad. Any conclusion drawn from that gdb
message is unsound.

## Not this defect

A second, distinct crash shares the area and should not be confused with it:

| | this defect | the rldb one |
|---|---|---|
| thread | `dataplane/slow` | `dataplane/rcu` |
| library | `librte_acl.so.25.0` | `liburcu-cds.so.8.1.0` |
| fault address | `0` | page-aligned, previously mapped |
| offset | `54db` | `603e` |

The rldb one is fixed and verified: `rldb_cleanup()` set `rldb_disabled` after
its destroy loop instead of before, leaving the whole teardown open to a
`crypto_vrf_free()` RCU callback holding the same four database handles. With
that fix (3.14.31) it did not recur in two full suite runs, and a single-machine
harness put it at 2 crashes in 2 valid rounds before the fix and 0 in 4 after.

## Where to start

**Get the hugepages into the core.** Without them nothing about the trie's
state can be read, and this defect cannot be diagnosed — only guessed at, which
is what the two failed attempts were. `coredump_filter` must be `0xff` and must
survive the restarts:

```
/etc/systemd/system/vyatta-dataplane.service.d/coredump.conf
[Service]
ExecStartPost=/bin/sh -c 'for p in $(pidof dataplane); do echo 0xff > /proc/$p/coredump_filter; done'
```

Setting it on a live pid is not enough — the dataplane restarted eleven times
during one suite run, and each new process gets the default back.

Then reproduce and read, in frame 1: `m_trie->acl_built`, `m_trie->num_rules`,
`m_trie->trie_state`, `m_trie->flags`, and `m_trie->acl_ctx`. Those four
distinguish the remaining hypotheses:

- `acl_built` false → the guard is being bypassed, or the compiler hoisted the
  `acl_ctx` load above it
- `acl_built` true and `num_rules` non-zero → `rte_acl_build()` returned success
  without producing a runtime, or the runtime was released after the check
- trie in the pool free-ring while still reachable → the pool hand-back in
  `npf_rte_acl_put_trie()` races the reader

Worth noting for the third: the trie structures come from a DPDK mempool and
are handed back with `rte_mempool_put()`. Nothing in that path waits for
readers. It has not been shown to be involved, but it is the one lifetime
question the two attempted fixes did not touch.
