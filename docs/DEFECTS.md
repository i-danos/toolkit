# The defects

Every one of these was invisible to static checks and to the OBS build. Each
needed a booted image, and most needed a booted *topology*.

Defects 1 to 4 were found during the port itself. Defects 5 to 10 came out of
running the Robot suites against the built image, and four of those six trace
back to a single decision — retiring the DANOS fork of DPDK, whose patches
turned out to be functional rather than cosmetic.

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

## 5. rldb torn down before it was disabled

**`vyatta-dataplane` 3.14.31**

`rldb_destroy()` walked the databases and freed them, then set
`rldb_disabled = true`. A packet arriving in between matched against a database
that was already being freed. The window is real on any liburcu; 0.10.2 simply
happened to hide it, and 0.15.2 does not.

This is an upstream defect from 2021, not something the port introduced — but
the port is what made it fire. 2105 survived eight rounds of the IPsec suite
with no crash. 2608 crashed on 2 of 2 attempts before the fix and 0 of 4 after.

The fix moves `rldb_disabled = true` ahead of the destroy loop and splits the
body into `rldb_destroy_internal()`.

---

## 6. ACL trie rebuilt underneath live readers

**`vyatta-dataplane` 3.14.33**

DANOS's DPDK fork patched `rte_acl` with `rte_acl_rcu_qsbr_add`, which let the
ACL defer its own reclamation. Retiring the fork replaced that with a stub in
`compat.h`, so a trie could be rebuilt while forwarding threads were still
traversing it.

The signature was a segfault in `rte_acl_classify_scalar` with `%r8 == 0`,
reached through `rldb_match` on the crypto policy path. `DEFECT-npf-acl-classify.md`
records the investigation, including the wrong turns.

The fix clears the built flag and waits for a grace period before rebuilding:

```c
if (live && (m_trie->acl_built || m_trie->needs_recreate)) {
        m_trie->acl_built = false;
        dp_rcu_synchronize();
}
```

---

## 7. Deleted ACL rules kept matching

**`vyatta-dataplane` 3.14.34**

The same stubbing removed `rte_acl_del_rule` and `rte_acl_copy_rules`. Nothing
failed to compile and nothing logged an error — deleting a rule simply had no
effect, so traffic kept matching policies that had been removed.

Upstream DPDK has no rule-deletion API, so the fix does not restore the calls.
Each trie now keeps its own `rule_list`, and deletion rebuilds the context from
what remains (`npf_rte_acl_store_rule`, `find_rule`, `free_rule_copies`,
`recreate_ctx`). The stubs are gone from `compat.h`; the comment explaining why
is not.

---

## 8. Crypto session pool sized to zero

**`vyatta-dataplane` 3.14.35**

DPDK 22.11 merged the symmetric session model, and
`rte_cryptodev_sym_session_pool_create` now wants `elt_size` to be
`rte_cryptodev_sym_get_private_session_size()`. It was left at 0, so every
session allocation failed with `Invalid mempool`.

The fix creates the pool from the device setup path, once the size is known
(`crypto_rte_ensure_session_pool`).

---

## 9. Redundant private session pool

**`vyatta-dataplane` 3.14.36**

With the merged model, the separate private session pool is not just
unnecessary — it prevents sessions from being established at all. Removing
`crypto_rte_setup_priv_pool()` took `ipsec sad` from `total-sas: 0` to
`total-sas: 2`.

Defects 8 and 9 are one story: the first made the pool unusable, the second kept
it that way after the first was fixed.

---

## 10. strongswan unit renamed on Debian 13

**`vyatta-security-vpn` 2.18 → 2.19**

Debian 13 ships the unit as `strongswan-starter.service`. Every reference to
`strongswan.service` therefore matched nothing, the IKE daemon never started,
and — worst of it — the commit reported success: "succeeded (non-fatal
failures)".

Fixed by using the shipped unit name throughout, and by having the daemon wait
for the VICI socket rather than testing for it once:

```
ExecStartPre=/bin/sh -c 'for i in $(seq 1 60); do [ -S /var/run/charon.vici ] && exit 0; sleep 1; done; exit 1'
```

`ipsec_running()` checks `strongswan-starter` for the same reason.

---

## 11. brokerd cancelled a thread holding a mutex

**`vyatta-route-broker`**

`route_broker_kernel_shutdown()` ran `pthread_cancel()` on the kernel consumer
thread, and is called on every FPM session teardown rather than at process
exit. The consumer waits on a condition variable — a cancellation point that
reacquires `route_broker_mutex` before returning — and the library has no
`pthread_cleanup_push` anywhere, so the cancel could destroy the thread holding
that mutex or mid-ZMQ-send. The next publish faulted inside the allocator.

Every FPM bounce produced a core, which took the data plane down with it,
because the data plane is restarted when its feed dies.

Replaced with a stop flag the consumer's one-second wait timeout notices. Ten
bounces before: ten cores. Ten after: none.

This one cost two wrong conclusions before it was found, both drawn from the
empty forwarding table it produced. `DEFECT-brokerd-crash-on-fpm-bounce.md` has
the full account, including the first diagnosis, which explained every piece of
available evidence and was wrong.

---

## 12. An installed system ran on memory, not on its disk

**`live-boot-vyatta`**

After `install image`, the account created during the install could not log in.
`admin/admin` answered "Login incorrect", and `tmpuser/tmppwd` -- the *live*
account -- worked. Official 2105 does the reverse.

The installed system's overlay had `upperdir=/run/live/overlay/rw`, live-boot's
in-memory default. 2105 has
`upperdir=/run/live/persistence/sda2/boot/2105.06111158/persistence/rw`. The
installer had written everything correctly -- `persistence/rw/etc/passwd`,
`shadow`, `config/config.boot`, a password hash that `openssl` confirms matches
"admin" -- into a directory the running system never used.

DANOS keeps `/boot/<image>/<image>.squashfs` and `/boot/<image>/persistence` on
one partition and names the latter with `vyatta-union=`. live-boot's
`find_persistence_media()` builds a list of devices that host the live root
filesystem and does not scan them, so a parent directory is never mounted over
a child of the same filesystem. In live-boot 4.x that list was always empty: the
loop passed the literal string `d` to `what_is_mounted_on` instead of `$d`. The
guard never fired and this layout worked by luck. Current live-boot fixed the
quoting and added `/run/live/medium`, the guard fires on the DANOS partition,
the scan returns nothing, and the system falls back to memory.

Fixed in `live-boot-vyatta` 0.11: for a `vyatta-union=` boot only, `storage_devices()`
is replaced by a copy that ignores that list. Every other boot keeps the stock
scan. The guard is right in general; what it protects against does not happen in
the DANOS overlay.

Confirmed on a controlled pair. The same ISO build, the same install, and
identical installer output, differing only in `live-boot-vyatta` 0.10 against
0.11: before, `admin` cannot log in; after, `upperdir` is the on-disk path,
`admin/admin` logs into vbash, and `getent passwd tmpuser` is empty.

What this defect is not, because three things were blamed for it first and none
of them was:

- **`sss_cache: Can't access '/var/lib/sss/db/config.ldb'`.** Printed during
  "Creating admin account" and listed as defect #19 in an earlier list. It appears
  identically on the install that could not log in and on the one that can. Noise.
- **The password hash.** Verified against "admin" with `openssl`, no backslash,
  correct length for a 16-character salt.
- **`/bin/sh` -> bash, `vbash`, the PAM stack, `user-setup.conf`.** Compared with
  official 2105 image for image: the same, apart from the SSSD lines and a
  jump distance that had to change with them.

Not explained: why `tmpuser` stops being created once persistence is mounted. It
does, and the marker file guessed at as the reason is absent in 2105 as well.

**What this does to earlier results.** The record says the suites were also run
against a system installed to disk. If that system ran on memory, nothing in it
exercised persistence, and the suites could not have noticed: prep-router.sh
recreates its account through the CLI on every boot. The 2026-09-02 installed
disk shows the failure -- `tmpuser` on login, `vyatta/vyatta` refused -- when
booted from its own bootloader. That does not prove the run itself was affected,
since the record does not say what the run logged in as, but it means "passed on
an installed system" has to be read as "passed on a system installed to disk",
not "passed on one running from it".

---

## 13. sssd 2.x printed a complaint on every successful install

**`vyatta-image-tools`**

Creating the admin account printed, twice, in the middle of an install that then
succeeded:

    [sss_cache] [sss_tool_confdb_init] (0x0010): Can't access
    '/var/lib/sss/db/config.ldb', probably SSSD isn't configured
    Can't find configuration db, was SSSD configured and run?

It looked like the cause of the login failure in defect 12 and was listed as
defect #19 in an earlier list, "the only user-visible defect". It is neither the
cause nor a failure: it appears identically on an install whose admin account
logs in, and `useradd` exits 0.

shadow 4.17's `sssd_flush_cache()` runs `/usr/sbin/sss_cache` after a change to
passwd, group or shadow, and skips silently only if that file does not exist. It
exists, so it runs, and on a system where SSSD has never been configured -- every
system being installed -- `sss_cache` complains on stderr, which `useradd` does
not control. Two call sites, `lib/commonio.c` when the lock count reaches zero
and `src/useradd.c` at the end, account for the two occurrences.

New with the port: 2105 ships sssd 1.16.3-3danos6, 2608 ships 2.10.1, and
"probably SSSD isn't configured" is a 2.x message. A guess written down before
this was checked said 2105 simply lacked `sss_cache`. Both images have it.

`useradd`'s stderr is now shown only when it fails -- `run_command`'s rule,
without `run_command`, whose command line would put the password hash in the
install log. Checked with a stub: noise on success shows nothing, a real failure
shows the error and stops, the hash appears zero times.

The stub could not show the part that mattered. `sss_cache` is started by a
child of `useradd`, and whether its stderr passes through `useradd`'s own was an
inference. Confirmed on a real install of `vyatta-image-tools` 5.51: between
"Creating admin account for user [admin]" and "Running post-install script..."
nothing is printed, the install reaches "Done.", and the new exit-status check
did not fire, so `useradd` returned 0. The same image, with `live-boot-vyatta`
0.11, logs in as `admin/admin` with `upperdir` on the disk -- the fix for
defect 12 was not undone by this build.

That change also closes a gap this defect was standing in front of. Nothing
checked `useradd`'s exit status, so a failure left the installer going on to
"Done." with no account on the new system -- which is the symptom of defect 12,
reached by a different route.

Not done: configuring SSSD during install, which removes the cause and changes
what an installed system starts with; and filtering the message by its text,
which breaks the first time SSSD rewords it.

---

## 14. "add system image" rejected every 2608 ISO's own checksums

Found doing the upgrade/rollback acceptance this project had not yet run: boot
an installed 2105 disk, attach the 2608 ISO, `add system image
http://.../i-danos_2608....iso`. The installer downloaded it, then:

```
Checking MD5 checksums of files on the ISO image...md5sum: WARNING: 1 computed
checksum did NOT match
Failed!
1 checksum failures found!
ISO image is corrupted and can not be used.
```

The one file was `./.disk/mkisofs` -- not payload, a text record of the exact
`xorriso -as mkisofs ...` command line used to assemble the ISO, written by
live-build during that same assembly step. Its content necessarily includes
the ISO's own output filename and build timestamp, so it cannot be known when
live-build's earlier checksums stage writes `md5sum.txt`. Confirmed on two
independent 2608 builds (the `-test` and product variants from the same tree):
each has its own internal mismatch between its `.disk/mkisofs` and the entry
for it in its own `md5sum.txt`, so this is not one bad build, it is every 2608
build.

The official 2105 ISO's `md5sum.txt` has no entry for `.disk/mkisofs` at all --
its live-build (Debian 10-era) never wrote that file, so 2105 never hit this,
and no earlier acceptance step in this project happened to check an upgrade
path, which is why it went unnoticed until now.

`check_install_source()` in `vyatta-image-tools` validates every line of
`md5sum.txt` with no exceptions, so this one always-stale line failed every
`add system image`. Fixed in 5.52 by excluding exactly that one path from the
check, with the reasoning above left in the code next to it. Not a security
loosening: `.disk/mkisofs` is build provenance about the ISO, not something the
installed system trusts or executes, and every other file in the manifest is
still checked.

### The fix does not reach the systems that need it

Testing this properly, 2105-as-base first hid a second, worse fact: the code
that runs `check_install_source()` belongs to the *currently installed*
system, not to the image being added. An already-installed 2608 system still
running 5.51 rejects every future 2608 image with this same failure --
including one built with 5.52 -- because 5.51's copy of the function has no
exclusion. The fix in 5.52 only helps a system that got 5.52 some other way;
it cannot repair itself, which is exactly the case `add system image` exists
for.

Confirmed by testing the representative path, not the convenient one: install
the 2105 ISO, then `add system image` a 2608 ISO onto it -- fails, expected,
cross-release. Then install a *2608* ISO built before 5.52
(`...20260921T1632...`, carrying 5.51) and `add system image` a 2608 ISO built
after (`...20260922T0539...`, carrying 5.52) onto it -- **also fails**, same
error, because the *running* system's 5.51 is what performs the check. Only a
system already installed from a 5.52-or-later image can successfully add
another image.

This makes 5.52 alone insufficient as a release fix: every 2608 system
installed before it ships is permanently unable to move off the checksum
failure through `add system image`, the product's own upgrade path. Not yet
decided: whether the exclusion needs a second path (an out-of-band bypass, a
signed override, or shipping 5.52 through a channel `add system image` does
not gate on) so an already-installed system can cross this one boundary. No
such path exists yet.

---

## Two of these were hiding each other

The Perl warnings buried the SA table, so the empty table underneath — caused by
the crashing dataplane — could not be seen until they were cleaned up. Fixing
defect 1 did not make any test pass; it made defect 2 visible.

Worth expecting on a port of this size: the first fix in an area often reveals
the next rather than resolving the symptom.
