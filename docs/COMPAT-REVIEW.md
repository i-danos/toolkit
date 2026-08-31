# Review of the DPDK 24 compatibility shims

`vyatta-dataplane` commit `4e14d566` ("compat: add DPDK 24 compatibility
abstractions and URCU header") added 173 `#define`s to `src/compat.h` to make
the DANOS dataplane compile against Debian's stock DPDK 24.11 after the DANOS
DPDK fork was retired. It succeeded at that. The question this review asks is a
different one: where a shim had to *invent* something, is what it invented true?

Four defects had already come out of that commit by the time it was reviewed
(see `DEFECTS.md` 6–9), all of the same shape — a stub that returned success
while doing nothing. So the commit was gone through line by line.

## Method

Reading the shims is not enough, and the reason is worth stating plainly.

`RTA_MPLS_PAYLOAD` is defined in `compat.h` as 30. The kernel's real value is
33. Read as source, that is a serious defect: a netlink attribute parsed under
the wrong id. It is not a defect at all. The whole block sits under
`#ifndef _MPLS_H`, `linux/mpls.h` defines that guard, and the fallback is never
reached — a program compiled against the real headers prints 33.

So each candidate was checked by compiling a program that prints the constant's
**effective** value — what the compiler actually sees after every header has had
its say — and comparing that against the authoritative definition. The question
is not whether a shim's value is right. It is whether the shim is reached, and
then whether its value is right.

## The 173 definitions

| Kind | Count | Risk |
|---|---|---|
| Pure renames (`ETH_MQ_RX_RSS` → `RTE_ETH_MQ_RX_RSS`) | 119 | none — the compiler catches a wrong name |
| Other expression-style macros | 27 | low |
| Invented numeric constants | 17 | **this is where the defects are** |
| Stubs and constant-returns | 9 | **and here** |
| Argument-dropping wrappers | 1 | one, and it was wrong |

Of the 173, seven turned out to be wrong and three of those were reached at
run time. Every one of the seven is in the bottom three rows.

The 119 renames need no verification. A misspelled rename does not compile, and
DPDK 24.11's own deprecation notices name the replacements. Everything below is
from the other 54.

## Fixed before this review

Found while adapting QoS to DPDK's 21.05 scheduler model, all in the invented
-constant group:

| Shim | Was | Truth |
|---|---|---|
| `RTE_SCHED_TC_BITS` | defined twice, the dead copy as 4 | 2 — DANOS has four classes |
| `RTE_SCHED_WRR_BITS` | 2 | 3 — eight queues per class |
| `RTE_SCHED_QUEUES_PER_TRAFFIC_CLASS` | 4 | 8 |
| `rte_sched_port_pkt_write_v2` | passed `NULL` as `port` | the real port |

These were live. The geometry constants are what `dscp_map[64]` and the queue
arrays are sized from, so the shim halved DANOS's queue space silently.

## Fixed by this review

Three fallbacks whose value disagreed with the definition that actually wins.
All three are **dormant** — the real definition is present in every build we
make, and the fallback is not reached:

| Shim | Was | Truth | Why it is not reached |
|---|---|---|---|
| `RTMPT_IP` / `IPV4` / `IPV6` | 0, 1, 2 | 0x0000, 0x0004, 0x0006 | `linux/mpls.h` enumerators; block guarded on `_MPLS_H` |
| `RTA_MPLS_PAYLOAD` | 30 | 33 | same block |
| `IFF_META_HDR` | 0x0004 | 0x0080 | `linux-vyatta`'s patch to `linux/if_tun.h`, line 75 |

Note the MPLS values are not sequential — 0x0004 and 0x0006, not 1 and 2 — so
the placeholders were not even the right *shape*.

Commit `89c73006` had already been over this block: it added the `_MPLS_H`
guard, precisely because `#ifndef` cannot detect an enumerator and the shim was
both failing to compile and shadowing real values. It fixed the guard and left
the values inside. That is the easy half to miss — once a shim stops being
reached, nothing tests what is in it.

Corrected anyway, in `42b135fe`. A fallback is reached when a header is missing,
which is when nobody is watching, and a wrong value there still compiles.
`IFF_META_HDR 0x0004` is unassigned in `if_tun.h`, so `TUNSETIFF` would quietly
not enable the meta header rather than reject the request.

## Live, and now removed

Three stubs were reached on every build. None broke a build or a test, which is
why they survived; each degraded something real. All three are gone.

**`rte_sched_get_profile_for_pipe(port, qid)` → `0`** and
**`rte_red_queue_num_maps(port, qid) → 1`.** Both fed
`qos_dpdk_dscp_resgrp_json()`, and both asked DPDK a question only DANOS can
answer. `qos_red_init_q_params()` is what fills these structures in;
`sinfo->profile_map[pipe]` (`qos.h:170`) is what records a pipe's profile.
`qos_hw_dscp_resgrp_json()` has always read them directly, and the DPDK path
now does the same walk.

The lookup key was wrong underneath all of that, which is the part reading the
shims would not have found. WRED parameters are stored against the per-pipe
queue index `q_from_mask()` builds — `tc * 8 + q` — while what was passed in was
`qos_dpdk_qindex()`'s port-wide queue id, `(subport * pipes + pipe) * 16 + off`.
The two agree only on the first pipe of the first subport, so
`qos_red_find_q_params()` returned NULL and the loop broke on its first
iteration.

So the real behaviour was not "reports profile 0's groups" as the shim's value
suggested. It was an empty `"wred_map": []` on every queue — which reads as
"none configured" rather than as a defect, and would have been believed.

Effect: `show queuing` only. Forwarding was unaffected.

**`rte_red_set_scaling(max_len)` → `0`.** Called once, at `qos_sched.c:362`,
under `if (... != 0) rte_panic(...)` — so the stub also made that panic
unreachable.

This is the one with a forwarding consequence. `MAX_RED_QUEUE_LENGTH` is 8192
packets and `qos_sched.c:77` documents the configurable range as
`min_th 64..499999998`, `max_th 128..499999999`. Stock DPDK caps both at
`RTE_RED_MAX_TH_MAX` = 1023 (`rte_red.h:25`) and takes them as `uint16_t`. The
fork's scaling knob is what reconciled the two ranges.

Nothing checked them on the way, either: `qos_wred_threshold_get()`
range-checks only its `QOS_QUEUE_SIZE_USEC` branch, and clamps that no lower
than `MAX_QUEUE_LIMIT_BYTES` (500000000); the packets and bytes branches pass
the value straight through. The `(uint16_t)` cast in `qos_copy_red_params()`
then wrapped it, so a threshold of 70000 arrived as 4464 — not merely too large
but arbitrary, and smaller than a neighbour that had not wrapped.

`qos_red_clamp_th()` now clamps at `RTE_RED_MAX_TH_MAX` and logs it. Clamping
loses precision on queues longer than 1023; failing loses more, because
`rte_red_config_init()`'s error propagates out of `rte_sched_subport_config()`
and one over-long threshold would take the whole policy's shaping down with it.
The USEC branch already clamps-and-logs for its own limits, so this matches.

Never reproduced against a live configuration — it needs a `queue-limit` or
`wred-map` threshold above 1023 packets and `DEFAULT_QSIZE` is 64.

## Adjacent, not yet resolved

`qos_dpdk.c` casts `qos_sp_qsize_get()` to `uint16_t` when filling
`dpdk_params.qsize[]`. That is the same silent truncation as the RED thresholds
had — the source value reaches 500000000 in USEC mode and is unbounded in the
packets and bytes modes.

It is not fixed here because the correct clamp is not yet established. DPDK
validates `qsize` (`librte_sched` carries "Incorrect qsize" and "Incorrect
value for qsize or tc_rate"), and if it requires a power of two then clamping
to `UINT16_MAX` would turn a truncation into a rejected configuration —
trading a quiet wrong answer for a loud wrong one. DANOS does no power-of-two
alignment anywhere. Establish the requirement first, then clamp to whatever it
actually allows.

## Checked and sound

- `DEV_RX_OFFLOAD_JUMBO_FRAME` → `0x0`. The flag was removed in DPDK 24.11;
  jumbo frames follow `max_rx_pkt_len` now. Contributing no bits to an offload
  mask is the correct translation, not a stub.
- `SIZEOF_ID_STRUCT` → `1`. `ndpi.c:368,372` allocate `flow->src_id` and
  `flow->dest_id` with it. This looks like a heap overflow waiting to happen and
  is not: those two fields are allocated, null-checked and freed, and are passed
  to nDPI nowhere. Modern nDPI dropped the per-endpoint id structs from
  `ndpi_detection_process_packet()` entirely. Two pointless one-byte allocations
  per DPI flow — dead weight, not a defect.
- `rte_red_free_q_params(pp, i)` → `(void)0`. Zero callers.
- `RTE_SCHED_PIPE_PROFILES_PER_PORT` 256, `RTE_NUM_DSCP_MAPS` 8,
  `RTE_MAX_DSCP_MAPS` 16, `MAX_DSCP` 64, `MAX_PCP` 8, `DSCP_BITS` 6,
  `PCP_BITS` 3 — all match.
- `TUN_META_FLAG_MARK` / `TUN_META_FLAG_IIF` — DANOS-private, consistent with
  `pktmbuf_internal.h` and the three `shadow.c` readers.

## What to take from it

The renames were never the risk, and they are 69% of the commit. Every defect —
the four already fixed, the four geometry constants, the three corrected here,
and the three still open — came from the 15% where the shim had to supply a
value or a behaviour that stock DPDK does not have.

That is where a compatibility layer stops being mechanical. A rename asserts
that two names mean the same thing, and the compiler checks it. A stub asserts
that doing nothing is equivalent to doing something, and nothing checks that at
all.
