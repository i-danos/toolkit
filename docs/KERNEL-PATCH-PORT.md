# Porting the DANOS kernel patches to Linux 6.12

What happened to each of the 35 `debian/patches-vyatta/` entries of `linux-vyatta`
when the kernel moved from 5.4 to 6.12, how it was checked, and one decision that
needs to be understood before anyone reopens it (TCP-AO).

**Provenance.** The first half of this note is written from the working log of the
port itself, which used to live in an untracked scratch file and was removed on
2026-09-26. Where the log and the repository disagree, both are shown and the
repository is treated as authoritative. The kernel's own `debian/changelog`
(`linux-vyatta`, branch `linux-vyatta-6.12.y`) is the durable record of the outcome.

## Outcome

35 vendor patches in, 29 applied on 6.12, 6 not:

| Disposition | Count | Which |
|---|---|---|
| Ported, applies in series order with `--fuzz=0` | 29 | everything else |
| Dropped: upstream already has the change | 1 | `0001-Remove-trailing-whitespace-in-uapi-linux-tcp.h.patch` |
| Dropped by decision: TCP-AO | 5 | the group `0002` to `0006`, about 4900 lines |

The Debian generic patches (`debian/patches/`, 20 of them) were replaced with the set
from Debian 13's own `linux_6.12.94-1` source package, because the previous copy had
drifted and no longer applied.

### The counts do not agree everywhere

| Source | Says |
|---|---|
| Working log, mid-port | 34 entries processed: 28 ported, 1 dropped, 5 TCP-AO |
| `debian/changelog`, 6.12.94-1vyatta1 | "all 35 entries: 32 ported and verified, 1 dropped, 5 TCP-AO" |
| `debian/changelog`, 6.12.101-1vyatta1 | "All 29 DANOS out-of-tree patches ... apply cleanly" |
| `ls debian/patches-vyatta` | 29 files |

`32 + 1 + 5` is 38, not 35, so the "32 ported" in the 6.12.94 entry is wrong. The
consistent figures are 35 = 29 + 1 + 5, matching the 29 files on disk and the 6.12.101
entry. The mid-port log's 28 is an intermediate count. The changelog text was left
alone: it is published package history.

## Method

Read the patch's intent, find the equivalent code in the current 6.12 tree, apply the
same semantic change by hand in a scratch copy, regenerate the whole hunk with
`diff -u` (never hand-edit line numbers: whitespace and context counts go wrong), then
check with `patch --dry-run --fuzz=0`. Work went from the smallest patch to the largest.

The check that mattered was **two-phase, in series order, with the real tool**:
`quilt push -a --fuzz=0` over `debian/patches`, then over `debian/patches-vyatta`.
Testing each patch alone against the base hides exactly the failures that come from a
patch depending on an earlier one.

## What sequential validation found

Both were left over from earlier in the port, and both had passed individual checks:

- **`af9005-disable.patch` was marked "already applied" and was not.** It needed a real
  application (only an offset adjustment). Fixed.
- **Hunk 5 of `0075-tun-intf-pass-meta-data` was ported against the wrong base.** An
  earlier vyatta patch adds an `if/else` the hunk depends on, and the port did not have
  it. The same class of error as the earlier MPLS chain. Fixed and re-verified in order.

Two more "already applied upstream" items were found and handled the same way:
`video-remove-nvidiafb-and-rivafb.patch` and the `cipso-draft` documentation patch.

Patches that needed real adaptation, not just line drift (from the changelog):

- **MPLS chain** (`0005` to `0008`, `mpls-socket`, `mpls-ipv6-qualify-ecmp-lo`): ported
  as one dependency-ordered sequence, because `0006` rewrites the `mpls_xmit()` region
  that `0007` touches and exports functions `0008` needs.
- **`0151-net-sysfs`** (operstate transition counting): adapted to the lockless
  `WRITE_ONCE`/`try_cmpxchg` operstate design, where `dev_base_lock` no longer protects
  it, and to an `IFLA_*` enum offset that now collides with upstream's `IFLA_DPLL_PIN`.
- **`0132`** (external multicast stats ioctl): adapted to the new
  `ipmr_sk_ioctl()`/`ip6mr_sk_ioctl()` pre-dispatch layer and to `mrt_lock` changing
  from `rwlock_t` to `spinlock_t`.
- **`0001-Revert-ipmi_ssif-avoid-registering-duplicate-ssif-in`**: adapted to the newer
  single-argument i2c `.probe` prototype.

## The TCP-AO decision

The five TCP-AO patches (`0002` to `0006`) implement RFC 5925 from scratch. `0004`
alone is 4195 lines. The working log first parked it as "too large for this session,
hand to a kernel engineer", and then the group was dropped rather than ported. The
reasons, from the changelog:

1. Linux 6.12 ships its own complete, RFC 5925-compliant TCP-AO
   (`net/ipv4/tcp_ao.c`, `net/ipv6/tcp_ao.c`). The vendor implementation dates from
   2019 and predates it.
2. They **collide at the `setsockopt` level**: both hardcode option level 38. This is
   an architectural conflict, not a matter of line drift, so porting would mean two
   implementations fighting over one socket-option number.
3. **Nothing consumes the vendor interface.** The YANG schema, `vyatta-protocols-frr` and
   FRR itself were searched; they reference only the classic `TCP_MD5SIG` ("BGP MD5
   password"). There is nothing to migrate.

Note what this is and is not. TCP-AO is **not validated on this system**: the vendor
interface is absent, and whether anything in DANOS could use the kernel's native TCP-AO
was not tested. A statement that "TCP-AO works" is not supported by this port.

## Not validated

- **SSIF/IPMI behaviour on real hardware.** The `ipmi_ssif` revert was ported
  mechanically and checked to apply; its behaviour has not been run on hardware. It was
  flagged for review before production use. (The hardware-vendor IPMI package is also
  disabled in `build_order.txt`, the project having taken a software-only path.)
- Everything in this note is about the patches applying and the kernel building. The
  runtime evidence for the kernel is elsewhere (`DEFECTS.md`, `UPGRADE-RECORD.md`, the
  Robot results).

## After the port

- 6.12.94 to 6.12.101: kernel.org incremental stable patches applied; all 20 Debian
  generic and 29 vendor patches re-applied cleanly; `abiname` unchanged (`trunk`), so
  binary package names did not change.
- 6.12.101 to 6.12.107 (`6.12.107-1vyatta1`): stable update imported. The ABI name
  `6.12.0-trunk-vyatta-amd64` is unchanged. A later commit
  realigns `netdevice-stats-override` for 6.12.107 and another restores the invariant
  "orig + patches = tree".
- A changelog version string was corrected along the way (`6.12.94+deb13-1vyatta1` to
  `6.12.94-1vyatta1`): the `+deb13` suffix did not match `VersionLinux._upstream_re` and
  broke `debian/rules debian/control`.

## Where to look

| What | Where |
|---|---|
| The outcome, per version | `linux-vyatta/debian/changelog` |
| The 29 vendor patches | `linux-vyatta/debian/patches-vyatta/` |
| Replay the two-phase check | `quilt push -a --fuzz=0` in `debian/patches`, then `debian/patches-vyatta` |
| Kernel on the built image | `linux-image-6.12.0-trunk-vyatta-amd64 6.12.107-1vyatta1` |
