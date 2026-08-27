# The four defects

All four were invisible to static checks and to the OBS build. Each needed a
booted image, and three of them needed a booted *topology*.

---

## 1. Perl smartmatch warnings printed to stdout

**`vyatta-security-vpn` 2.16 → 2.17**

`Vyatta/VPN/Util.pm`, `Charon.pm` and `OPMode.pm` used `given`/`when`. Perl
deprecated the switch feature in 5.38 and removed it in 5.42; Debian 13 ships
5.40, where it still runs and prints a deprecation warning per construct — **on
stdout**, which is what makes it a functional problem rather than noise:

```
$ show vpn ipsec sa
given is deprecated at /opt/vyatta/share/perl5/Vyatta/VPN/Util.pm line 375.
when is deprecated at .../Util.pm line 376.
...
```

The SA table is buried and anything parsing that output sees nothing it
recognises. It surfaced as the IPSEC_VPN suite reporting an empty SA table for a
tunnel it had just configured successfully.

38 constructs converted to `if`/`elsif`, keeping the enclosing block so `$_` stays
bound.

**The first attempt was wrong and the package's own tests caught it.** `continue`
inside a `when` means *fall through*. Treating every block as independent gets
the seven blocks ending in `continue` right and the other eleven wrong, and
leaves the `continue` statements as syntax errors:

```
Can't "continue" outside a when block at .../Charon.pm line 306.
# TOTAL: 7  # PASS: 4  # FAIL: 3
```

The verification that missed this was `perl -c` plus one equivalence test on
`tnormal()` — a function that happens to live in the file without any `continue`.
The package ships seven `.t` files and 187 assertions; running them would have
caught it immediately. OBS did that job instead.

---

## 2. XFRM policy path never committed its rldb transaction

**`vyatta-dataplane` 3.14.26 → 3.14.28**

Configuring a site-to-site IPsec tunnel segfaulted the dataplane: 566 SIGSEGVs on
one router in a single run. Both its dataplane ports went dead while still being
listed with their addresses, so for a long time it read as a routing problem.

`rtnl_process_xfrm()` only stages policy rules in an rldb transaction; the ACL
runtime that `crypto_policy_check_outbound()` classifies against is not built
until the transaction is committed. `xfrm_client.c` commits when it sees the
`END` marker closing a batch. The controller snapshot path in `control.c` has no
such marker and was not committing at all, so `m_trie->num_rules` rose above zero
while the trie stayed unbuilt. `npf_rte_acl_trie_match()` gates only on
`num_rules`, so it handed an unbuilt context to `rte_acl_classify()`:

```
rte_acl_classify_scalar+299   mov (%r8),%ecx    with %r8 == 0
npf_rte_acl_trie_match        npf_rte_acl.c:1484
rldb_match
crypto_policy_check_outbound
shadow_crypto_output
tap_reader
```

Not a DPDK API change, as first guessed — DPDK faithfully crashes on a context
that was never built.

**This one also took two attempts, and the partial fix is what located the
rest.** 3.14.27 put the commit after the parse-result check, so a batch that
failed partway through still returned without publishing what it had staged. The
measurement made it obvious: R1 and R2 went to zero crashes with links passing
traffic, while R3 still took 13 — and R3 was the only one logging
`netlink POLICY message parse error`, i.e. the only one taking the early return.
Three routers on one version, one difference in the logs. A fix that had worked
everywhere or nowhere would have been harder to place.

Also zeroed `xfrm_client_aux_data` before use: only `.vrf` was being set while
`rtnl_process_xfrm()` reads `.seq`. Real, unrelated to the crash, and said so in
the commit message.

---

## 3. `linux-headers-amd64` metapackage version race

**`build-iso` package list**

Both DANOS and Debian ship a package called `linux-headers-amd64`, and apt picks
between them by version. Fine while ours was newer; once trixie moved to
`6.12.105-1` it outranked `6.12.101-1vyatta1`, so `vyatta-systemtap.list.chroot`
asking for the metapackage pulled in Debian's headers, their `linux-image`
through the dependency, and their `linux-kbuild` in place of ours.

The image then carried two kernels and booted Debian's — not what the dataplane
is built against. The mismatched `linux-kbuild` is the quieter half: external
module builds on the target would use headers from a kernel that is not running.

No manifest check noticed, because `linux-image-vyatta-amd64` was still
installed. **Present and booted are different questions**, and `verify-iso.sh`
was only asking the first. It now reads the default boot entry out of the ISO.

Not introduced by any change here — upstream moved and the image followed. The
fragile part, naming a metapackage that both sides provide, had been there all
along.

---

## 4. cloud-init stage deadlock

**`cloud-init` …vyatta2 → …vyatta4**

Booting with a datasource attached hung before the login prompt, with nothing on
the console after `Finished modprobe@efi_pstore.service`. systemd named it as
soon as it was asked:

```
sysinit.target: starting held back, waiting for: cloud-init-network.service
```

cloud-init 25.x added `cloud-init-network.service`, which blocks `sysinit.target`
until the network stage finishes. That stage runs `cloud_init_modules`, where the
rebase had put four modules that reach configd — and configd starts at
`multi-user.target`, after `sysinit.target`:

```
sysinit.target ──waits──▶ cloud-init-network.service
      ▲                            │ waits
      └────waits──── configd ◀─────┘
```

18.3 had no network-stage handshake, so the same placement was harmless there.

**The first fix was half a fix, for a reason worth naming.** Four modules
depended on configd; two of them *wait* (deadlock) and two only *log an error and
continue*. Moving the two that hung cleared the deadlock — boot went from 300s
with no response to 60s — so it looked done. But `set_hostname` and
`update_hostname` stayed behind, and the `vrouter` distro sets the hostname
through configd with `_write_hostname` a no-op, so there is no `/etc/hostname`
fallback: a seed asking for `danos-ci-test` still booted as `node`.

Classifying by symptom (hangs / does not hang) instead of by cause (needs
configd) cost a second full build-and-verify cycle. The 18.3 baseline had all
four in `cloud_config_modules`, whose service is ordered
`After=config-loaded.target` — the answer was one `git show` away.

The verification that caught the half-fix was a check added *because* the first
one had passed too easily: `hostname` must print `danos-ci-test`. Boot time and
module execution were both green on the half-fixed version.

---

## Two of these were hiding each other

The Perl warnings buried the SA table, so the empty table underneath — caused by
the crashing dataplane — could not be seen until they were cleaned up. Fixing
defect 1 did not make any test pass; it made defect 2 visible.

Worth expecting on a port of this size: the first fix in an area often reveals
the next rather than resolving the symptom.
