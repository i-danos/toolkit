# DPA capability and backends: five gaps

The project's position, stated:

> **Software-First, Hardware-Acceleration-Ready, ASIC-SDK-Free.**
> The software datapath must run standalone. Hardware offload is optional. No
> vendor ASIC SDK may become a dependency of the core; where one exists it is
> isolated outside the backend boundary. NIC, SmartNIC, DPU and FPGA are all
> legitimate backends. SAI is not an architectural premise.

This records what of that already exists in 2608, measured rather than assumed,
and what is genuinely missing. It deliberately does not settle which software
forwarder is primary; every gap below is the same gap whichever one it is.

Two things are worth saying before the list, because both are easy to get
backwards.

**"No ASIC" is not "no hardware acceleration."** Checksum offload, TSO/GSO,
RSS, VLAN offload, VXLAN/Geneve tunnel offload, `rte_flow` steering, crypto
offload and metering are all hardware acceleration, all reachable through DPDK
today, and all available on ordinary NICs. A position of "we do no hardware
offload" would give away most of that for nothing.

**What must be excluded is an SDK dependency, not hardware.** The thing to
prevent is a stack where the core cannot be built or reasoned about without a
vendor SDK in the path. That is a statement about where a boundary sits, not
about whether hardware is used.

## What already exists

Three assumptions about this area turned out to be wrong when checked, which is
the third time in this project that a capability was assumed missing and found
present. So: measured, on `i-danos_2608_20260913T2310`, with no FAL backend
loaded.

### Per-object programming state, with the reason

`src/pd_show.h`:

```c
enum pd_obj_state {
	PD_OBJ_STATE_FULL,         /* fully programmed in HW */
	PD_OBJ_STATE_PARTIAL,      /* partially programmed in HW */
	PD_OBJ_STATE_NO_RESOURCE,  /* not programmed: HW out of resource */
	PD_OBJ_STATE_NO_SUPPORT,   /* not programmed: unsupported in SW or HW */
	PD_OBJ_STATE_NOT_NEEDED,   /* not programmed: not needed there */
	PD_OBJ_STATE_ERROR,
};

struct pd_obj_state_and_flags {
	uint16_t created : 1;
	enum pd_obj_state state : 16;
};
```

A `pd_obj_state_and_flags` is attached to each object -- routes carry theirs
through `lpm_add()`. The enum distinguishes *why* an object was not offloaded,
which is more than "programmed / not programmed" and is the part that makes it
usable as a policy input rather than only as a report.

Live, from `vplsh -c 'pd show dataplane'`:

```json
{"objects":[
  {"route":     [{"dp":"sw-dataplane","full":6,"partial":0,"no_resource":0,
                  "no_support":0,"not_needed":2,"error":0}]},
  {"route6":    [{"dp":"sw-dataplane","full":5,...}]},
  {"mroute":[]},{"mroute6":[]},{"mpls-route":[]},
  {"vrf":[]},{"qos-if":[]},{"qos-vlan":[]}
]}
```

Eight object classes are tracked (`pd_show.c:52`), QoS among them, and each can
be listed by state: `pd show dataplane route no_support`.

### Software fallback is structural, not a feature

```c
#define call_handler(op_type, fn, args...)			\
	{							\
		if (fal_handler) {				\
			interface = fal_handler->op_type;	\
			if (interface && interface->fn)		\
				interface->fn(args);		\
		}						\
	}
```

Each entry point is resolved by its own `dlsym`. A backend that implements five
of them is a valid backend; everything else is `NULL`, the call is skipped, and
the software path continues. Fallback is not something to be reserved for -- it
is what happens by default, and it is why an incremental backend is possible at
all.

### A capability mechanism, already exercised

`fal_get_switch_attrs(uint32_t attr_count, struct fal_attribute_t *attr_list)`
queries the backend, returning `-EOPNOTSUPP` when there is none. Eighteen
attributes exist, and three callers use them today -- `qos_ext_buf_monitor.c`
for buffer descriptors, `qos_hw.c` for burst size, `bridge.c` for PVST punt.

So the query path does not have to be invented. What it carries is the problem.

---

## Gap 1 — capability is scale-only, and is answered too late

The eighteen attributes are limits and per-feature switches:
`FAL_SWITCH_ATTR_MAX_BFD_IPV4_SESSION`, `FAL_SWITCH_ATTR_MAX_BURST_SIZE`,
`FAL_SWITCH_ATTR_MPLS_IP_TTL_MODE`. **There is no way to ask whether a backend
supports a feature at all** -- no attribute answers "do you do VXLAN", "do you
do MPLS", "do you do ACLs".

Without it, the only way to discover that a backend cannot do something is to
try: program the object, get a failure, record `PD_OBJ_STATE_NO_SUPPORT`. That
works, and it is what happens now, but it means the answer arrives *after* the
attempt. A policy layer that has to choose a backend before programming cannot
use an answer that only exists afterwards.

**What is needed:** feature-presence capability alongside the scale limits,
answerable before the first object is programmed. The existing
`fal_get_switch_attrs()` path carries it; the attribute set is what grows.

The `pd_obj_state` enum should stay exactly as it is. Declared capability and
observed outcome are different facts and both are wanted -- a backend that
claims VXLAN and then returns `NO_RESOURCE` at object 4,000 is telling the truth
twice.

## Gap 2 — two lanes, not N backends

`pd_show.c:85`:

```c
if (!fal_plugins_present())
	show_hw = false;
...
	rc = pd_show_obj(wr, "sw-dataplane", stats);
	if (show_hw)
		rc = pd_show_obj(wr, "hw", stats);
```

Two fixed lanes: `sw-dataplane`, and `hw`. The backend has no name, and there
is exactly one of it -- `fal_init_plugins()` loads a single `platform.conf`
entry.

This is the gap that blocks everything in the doctrine above. *Preferred
backend* and *offload policy* have nowhere to attach when a backend is not a
nameable thing. Hybrid forwarding, where one route is programmed to a SmartNIC
and the next falls to software because the first lacks IPv6, needs objects to
record **which** backend programmed them, not merely that "hw" did.

**What is needed:**

1. Backends have identity. A backend reports its own name, and
   `pd show dataplane` reports per backend rather than per lane.
2. More than one may be loaded. `platform.conf` gains a list.
3. `pd_obj_state_and_flags` records which backend programmed the object.

Point 3 is the load-bearing one and it is also the cheapest: the struct has
15 unused bits.

```c
struct pd_obj_state_and_flags {
	uint16_t created : 1;
	uint16_t backend : 4;   /* index into the loaded backend table */
	uint16_t unused  : 11;
	enum pd_obj_state state : 16;
};
```

## Gap 3 — no reconciliation

`configd` is a transaction engine: candidate, running, and an effective store
used during commit, with `commitmgr.go` driving it. What it does not have is a
loop that re-asserts desired state against what is actually programmed.

Today a commit is applied once. If a backend loses an object afterwards -- a
plugin restart, a device reset, a table flushed under it -- nothing notices and
nothing re-programs. With a single software datapath in the same process this is
close to harmless. With a SmartNIC or DPU backend it is not: those have their
own lifecycle, and "the thing I programmed is no longer there" is an ordinary
event rather than a fault.

**What is needed:** a reconciliation loop that compares desired against
programmed and re-drives the difference. This is the only one of the five that
is genuinely new machinery rather than an extension of something present.

It is also the one with a real design question attached, which this document
does not answer: reconciliation needs a durable notion of desired state at the
object level, and today desired state is a configuration tree in a different
process from the objects.

## Gap 4 — Desired and Programmed live in different processes

- **Desired** is in `configd`: candidate / running / effective, as YANG.
- **Programmed** is in the dataplane: `pd_obj_state`, per object.
- **Oper** is split -- interface and protocol state comes back through the VCI
  and through FRR, while forwarding-object state does not come back at all.

There is no object that spans the three. A route's desired form is a
configuration node; its programmed form is an LPM entry with a
`pd_obj_state_and_flags`; nothing joins them, so no component can answer "this
route was asked for and is not programmed, and here is why" without a human
correlating two tools.

**What is needed:** a join. Not necessarily a new datastore -- the minimum is
that programmed state becomes addressable by the same key the desired state
uses, so that the two can be compared by something other than a person.

## Gap 5 — the state exists and no operator can see it

Found while writing this. `pd show dataplane` is a `vplsh` command only. There
is no YANG module, no operator-mode CLI, no REST endpoint. The per-object
programming state -- the single most useful thing here for someone running the
box -- is reachable only from the debug shell.

This is the cheapest item in the document and it is worth doing early for a
reason beyond operator value: **a capability and backend model that cannot be
inspected from outside the dataplane cannot be tested from outside the
dataplane either.** Every verification in `toolkit/vm/` drives the box through
the CLI or through `vplsh`; the ones that matter most go through the CLI,
because that is what an operator has.

---

## What to build first

Gaps 1 and 2, together, as one additive change. They are prerequisites for
everything else in the doctrine and for every backend, whichever forwarder ends
up primary, and neither displaces anything:

| | |
|---|---|
| `DataplaneCapability` | feature presence + scale limits, answerable before programming |
| Backend identity | a backend names itself; `pd show` reports per backend |
| Per-object backend | 4 bits of the 15 already spare in `pd_obj_state_and_flags` |
| Operator visibility | YANG + op-mode for the above, so it can be tested through the CLI |

Gap 3 (reconciliation) follows, because it needs gap 4's join, which in turn is
easier to specify once objects can say which backend holds them.

## What this does not decide

- **Which software forwarder is primary.** `vyatta-dataplane` today; VPP is the
  stated intent. Every gap above is identical either way, which is the reason
  to do this work before that question is settled rather than after.
- **Whether an ASIC backend is ever written.** The boundary this establishes is
  what would keep such a backend, and any SDK behind it, outside the core.
- **The capability schema itself.** The list of features and limits is a
  separate exercise; this document only establishes that presence and scale are
  different questions and that presence is the one currently unanswerable.
