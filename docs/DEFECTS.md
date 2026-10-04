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

### The checksum fix itself is confirmed

Proven with both sides on 5.52 (a fresh install from the 20260922T0539 build,
run against another copy of the same ISO): `Checking MD5 checksums of files
on the ISO image...OK.` -- clean, where every prior attempt failed on exactly
`.disk/mkisofs`. That is the whole claim 5.52 makes and it holds.

### What broke next: one is harness noise, one looks like #33

Continuing the same run to exercise a second boot entry (the other half of
upgrade/rollback acceptance) hit two more things. Neither is the checksum, and
they turned out not to be the same kind of finding.

**The `VII_IMAGE_NAME` mismatch is not a product defect -- ruled out, not
just unconfirmed.** Answered interactively as `2608b`, the image that actually
landed on disk was named `vyatta` instead (content correct -- squashfs and
kernel timestamps matched the 0539 build -- name wrong). Tracing the
unmodified script with `bash -x` and no custom driver, against the same disk,
showed the opposite: the name prompt defaulted to `[2608]` correctly, was
accepted correctly, and the existing-image collision was reported and refused
correctly. The mismatch appeared only when a one-off Python script written
for this session (`answer_add_image.py`, never committed, matched prompts by
regex and wrote answers straight to the console socket) was driving the
console. That script has no verified guarantee it writes an answer only after
a prompt has finished printing, which is exactly the class of bug this
project already hit once today in `console.py` itself. So: test-harness noise
from an ad hoc, uncommitted script, not a defect in `vyatta-install-image`.
Nothing to fix here; noted so it is not mistaken for one on a re-read.

**The `lu --user configd -- vyatta_update_grub.pl` hang did not reproduce --
also ruled out, not confirmed.** It happened once, in the middle of
`run_post_install`'s grub step, with no output and no prompt back for several
minutes and the QEMU process pinned near 40% CPU. Tested directly and
repeatedly afterward -- the same polluted `VYATTA_CONFIG_SID` a real CLI
session leaves in the shell (matching the mechanism the `CfgClient`
constructor actually reads it by, `getenv("VYATTA_CONFIG_SID")`, `execvp`
carrying it through `lu` unchanged), `--generate-grub` and
`--set-default-boot-index` each on their own, and `--set-default-boot-index`
against the exact invalid name (`vyatta`) that produced the error seen
earlier -- every one of those returned in under two seconds, correctly. So
this specific call, under every condition it plausibly ran under, is not
reproducibly slow. Whatever caused the one observed hang was not caught.

**The CLI's own `add system image` dispatch (through configd/opd) is the one
that is still unresolved, because it was never retried in isolation.** Earlier
in the same session, before the direct script call was used to get the
checksum proof above, the CLI command hung with no output at all, not even
the installer's own banner -- that is the observation that made bypassing
configd/opd necessary to measure anything. It has not been reproduced or
root-caused either, in either direction: not confirmed as the same bug as the
grub hang just ruled out above, and not confirmed as the same bug as the
already-open configd item. It is one unexplained observation, on record as
that and no more, until it happens again with something watching.

So: two things were found beyond the checksum fix, and neither is confirmed.
One was actively tested and cleared. The other was only ever seen once --
until it was deliberately retried, below.

### The CLI dispatch hang is reproducible, and it is not the grub call

Retried in isolation, on a fresh boot, with nothing else running: `add system
image <url>` typed at the CLI hung again, identically -- no output at all,
not even the installer's own "Welcome to the DANOS (Lancaster) image
installer." banner that the direct script call always prints within a couple
of seconds. Five minutes of watching the QEMU process showed CPU usage
decaying asymptotically toward a flat baseline, the shape of `ps`'s
elapsed-time-averaged `%cpu` under constant background load, not of a process
doing increasing work -- the command is blocked, not slow.

That rules out where it is not: not `lu` (tested standalone, 6ms), not NSS or
sssd (`getent passwd configd` and `id configd` both 4ms, and `configd` is a
plain `files`-resolved account, never reaching the `sss` source at all), not
`vyatta_update_grub.pl` itself (every call tested directly above returned in
under two seconds, correct output each time), and not `vyatta-install-image`
running as root (that is the direct-script path, which is what produced the
checksum proof). What is left is opd/configd's own dispatch of a
`opd:privileged true` command -- the mechanism that turns a typed CLI line
into a running root process is not the same mechanism as `sudo` or `lu`
invoked by hand, and it is the one part of this path never yet exercised in
isolation.

No second channel existed to inspect the guest while it was stuck: ssh was
never enabled on this system (test images bring up management by DHCP only),
and reaching the qcow2 offline needed `nbd`, which needed root the host
session did not have. So this is as far as it goes without a password prompt
or a purpose-built harness step to watch `opd`'s own process state live.

### With a second channel: the process tree while it hangs

`set service ssh` before triggering the hang gave a route in over the
management interface while the CLI session stayed stuck, and `/proc` on the
live, hung tree says exactly where each process is, no longer an inference:

```
opd (1767)
 └─ vyatta-install-image (3876)         state S, wchan do_wait
     fd0/1/2 -> /dev/pts/0              -- opd allocated a real pty for this
     └─ vyatta-install-image (3979)     state S, wchan pipe_read
         fd0/1/2 -> /dev/pts/0 (inherited)
         fd3     -> pipe:[15891] (read end)
         └─ vyatta-install-image (4051) state S, wchan wait_woken
             fd0 -> /dev/pts/0 (inherited)
             fd1 -> pipe:[15891] (write end)
             kernel stack: tty_read -> n_tty_read -> wait_woken
```

Three facts, not guesses:

1. **4051 is not a separate script invocation.** Its `/proc/4051/cmdline` is
   byte-identical to 3979's, which is what a `fork()`-only bash `( ... )`
   subshell looks like in `/proc` -- no `execve` happened, so the kernel never
   updated `cmdline`. It is a subshell of 3979, not a recursion into the
   downloaded image a third time.
2. **4051 is blocked reading the real terminal** (`tty_read` on fd 0, which is
   still `/dev/pts/0`, inherited unchanged from 3876). It is waiting for
   keystrokes.
3. **4051's own output has nowhere to go but back to 3979**, through the pipe
   at fd 1 -- and 3979 is blocked on the other end of that exact pipe
   (`pipe_read` on fd 3), which is what `answer=$(some_command)` looks like
   from the outside.

Put together: some command inside the recursed installer is being called
through `$(...)` -- which captures its stdout into a pipe -- while that
command still reads its input from the real terminal. If it ever prints a
prompt before reading, the prompt goes into the pipe with everything else,
where 3979 is waiting to read it only after the subshell exits. Nobody sees
it, so nobody can answer it, so it waits forever. This is inference from the
process tree, not a confirmed line number -- the next step is finding which
call in `vyatta-install-image` or `.functions` is wrapped in `$(...)` while
still expecting to read stdin, likely reached only on this path.

**Also observed, still unexplained:** none of the earlier output that should
exist on this pty -- the "Welcome to..." banner 3876 prints unconditionally
near the top of the script, the checksum-check output, "Executing installer
from downloaded image...", the image-name prompt -- ever reached the actual
CLI session across any attempt in this investigation, hung or not. 3876's own
fd 1 is the same `/dev/pts/0` the deeper processes inherit, so by file
descriptor alone that output should have gone somewhere. Whether it reached a
pty that was never bridged back to the console, or reached the console and
was consumed by something before this session's `console.py` could read it,
is not established. Worth its own pass before concluding the `$(...)` theory
above is the whole story.

### A specific candidate for the `$(...)` call -- not confirmed

`_dialog_enter_password()` is the one function in this script that already
works around exactly this class of bug: it reads and writes through
`/dev/tty` explicitly (`read -p "..." <>/dev/tty`, `echo ... >/dev/tty`)
rather than through inherited stdin/stdout, with a comment citing an old
defect number for why. It is called two ways -- plainly at line 1229 for a
grub password, and through `get_password()`'s `VII_ADMIN_PASSWORD=$(...)`
wrapper at line 406, itself called from `_get_admin_settings()` for a new
administrator account.

The `<>/dev/tty` redirection with no fd number targets fd 0, which is
consistent with 4051's fd 0 still showing `/dev/pts/0` -- so the workaround
is not obviously broken by inspection. Whether `_get_admin_settings()` even
runs on this path is the open question: the two direct-script runs that
produced the checksum proof and the naming/collision behaviour earlier in
this record both reached "Would you like to save the current configuration"
without ever being asked for a new administrator account, which is what
should happen on a **replace-existing-image** install (as this one is) --
suggesting admin setup is skipped here, and this candidate may be the wrong
one. Listed because it is the strongest lead static reading found, not
because it is confirmed. Settling it needs `strace`/`gdb` attached to the
live hung tree, which this pass did not have privilege on the host to do.

### Settled: `strace -f` from the moment `opd` forks the command

Granted host `sudo` for exactly this, `strace -f` was attached to `opd`
itself before the CLI command was ever typed, so the trace covers the whole
tree from its first `execve`. Two things fell out of it, and together they
replace every theory above -- there was no configd/opd dispatch bug and no
swallowed prompt.

**The disk-space finding first, because it wasted two of the four attempts.**
`/tmp` on this test system is a 1.5G tmpfs, and this same disk had been
reused across dozens of installer runs this session without its temp
directories ever being cleaned up -- every one of them killed with `-9`
rather than allowed to exit, so `_clean_up`'s `EXIT` trap never ran. With 300M
free against a ~570M ISO, two straces in a row show `curl`'s destination
write failing partway through (`write(2, "2",) = 0`, both times around the
same byte count) and the installer correctly reporting `Unable to fetch the
ISO image`. Not a hang, not opd, not configd -- ordinary `ENOSPC` from a test
harness that had never been asked to clean up after itself. `rm -rf
/tmp/vyatta-install-image.*` (after `umount -l` on anything still loop-mounted
from the killed runs) fixed it.

**With clean space, the trace runs straight through the checksum, the
recursion, and the image-name prompt -- and every one of those prompts really
is written to fd 1:**

```
write(1, "ISO download succeeded.\n", 24)
write(1, "Checking MD5 checksums of files on the ISO image...", 51)
write(1, "Executing installer from downloaded image...\n", 45)
write(1, "What would you like to name this image? [2608]: ", 48)
```

Every write returns success. The script keeps running past the name prompt --
it does not block there -- and proceeds into the collision check, because
`[2608]` is the default and an image named `2608` already exists: it is the
one currently running. That is where the earlier `tr '[:lower:]'
'[:upper:]'` / pipe / fork tree comes from -- it is `get_response()`'s own
`toupper()` machinery, called correctly, preparing to validate a `Yes/No`
answer. The final blocked call, `read(0, <unfinished ...>)`, is that
function's own `read myresponse` -- waiting for a real answer to a real,
correctly-displayed question: *"Do you want to replace it (Yes/No)? [No]:"*

**So this was never a deadlock.** Every prompt in this path writes to fd 1
successfully and every read is a legitimate wait for an answer to a question
that was actually asked. What makes it look exactly like a hang, every time,
on this specific harness: every build in this project answers `[2608]` to the
name prompt by default, because every one of them is release 2608 --
so re-adding *any* of them onto a system already running one always collides
with itself, always reaches this same interactive confirmation, and nothing
driving the console non-interactively (`console.py`, or the CLI dispatch as
originally observed) ever supplied an answer or was watching for one. It
reproduced with total consistency because the setup guaranteed the collision
every time, not because opd, configd, or `vyatta-install-image` had a bug.

This replaces the `lu`/configd theory (already cleared directly above) and
the `$(...)`-swallows-the-prompt theory (superseded: the prompts are not
swallowed, they are written and simply never answered because nothing was
driving them past the name prompt with a non-colliding name). Nothing here
needs a code fix. What it does mean for acceptance: to add a second image on
a running system without an interactive confirmation, the test driver has to
either answer `Yes` to the replace prompt or install onto a disk that does
not already carry an image named `2608` -- which describes every 2608 build,
so the second image in this project's own upgrade/rollback test will always
need one of those, not a fix to the product.

### Two more things surfaced finishing the actual rollback proof

Getting a genuine second image on disk to prove rollback (select it, reboot,
select the original back) ran into two more anomalies. One is now root-caused
-- and it is real, and it matters more than it looked at first. The other is
still open.

**1. `vyatta_update_grub.pl` writes the new grub config to the wrong file --
confirmed, root-caused, not a red herring.**

`--generate-grub=<name>` reports success and the `Template::Toolkit` render
is correct (verified directly: `@images` correctly includes the pushed name,
the rendered file grows and contains the new `menuentry` blocks). But
`--list-images` and `--set-default-boot-index` keep reporting only the
original image, and that is because they are reading a *different file* than
the one just written -- proven with `stat`, not inferred:

```
/boot/grub/grub.cfg                                   device 0,26  inode 262924
/run/live/persistence/vda2/boot/grub/grub.cfg          device 254,2 inode 263802
```

Different devices, different inodes. `vyatta_update_grub.pl`'s `$grub_cfg`
constant is the hardcoded, relative `/boot/grub/grub.cfg`. On a running,
installed system, `/boot` is not a separate mount -- it is part of the root
overlay, whose `upperdir` is `/run/live/persistence/vda2/boot/2608/persistence/rw`
(the *currently running image's own* persistence directory). So a write to
`/boot/grub/grub.cfg` lands at
`/run/live/persistence/vda2/boot/2608/persistence/rw/boot/grub/grub.cfg` --
confirmed directly, byte-for-byte matching size and content. That path is
inside one image's private, ephemeral overlay. It is not where GRUB itself
reads from at boot (GRUB reads the raw partition, before any overlay exists),
and it is not where this same tool's own read path looks either --
`--list-images` calls `get_live_image_root()`, which correctly resolves to
`/run/live/persistence/vda2` and appends `/boot/grub/grub.cfg` to *that* --
the real, shared, on-disk location. The write path and the read path in the
same tool disagree about what `/boot` means, and the write path is the one
that is wrong: it goes through the running system's own filesystem view
instead of the shared on-disk location every image's boot menu has to live
in.

**Consequence, stated plainly: on an already-installed system, `add system
image` can copy a new image's files correctly and still never make that
image selectable to boot, silently, regardless of the "Done." at the end.**
This is not specific to the naming anomaly below or to any test artifact --
it is a path computed from a constant that does not account for where `/boot`
actually points on a running (non-live-CD) system, and it would reproduce
identically for a correctly-named image added through the ordinary CLI path.

**2. The image still lands under a name that was never typed -- open.**
Across several attempts, on a disk deliberately cleaned of any prior `vyatta`
directory first, and even with `VII_IMAGE_NAME` passed explicitly via `sudo
env` (confirmed reaching the script: the prompt's own displayed default
changed to match), the copied files still land under `/boot/vyatta` -- correct
content, wrong name, consistently. Ruled out: `VII_ADMIN_USERNAME` defaults to
`tmpuser` not `vyatta`, no stray `vii.config` exists to supply a default, and
the value is demonstrably reaching `get_response_raw` (the bracketed default
in the prompt changes correctly) -- yet the confirmation line right after
still says `vyatta`. Not explained. Not blocking further work the way #1 was,
since the image's actual location is knowable by listing `/boot` regardless
of what it is named.

With #1's real location and read/write mismatch understood, completing the
reboot-and-confirm half of the rollback proof needs either a fix to
`$grub_cfg`'s path (or writing through the same `get_live_image_root()`
resolution the read side already uses) or, for acceptance purposes only,
writing directly to the correct on-disk path by hand. The checksum fix and
the #33 conclusion earlier in this record are unaffected by either finding.

---

### Confirmed on real hardware (2026-09-27)

Reproduced end to end on physical hardware, not QEMU: a BayTrail-platform box
with a 4-port Intel I210 NIC (`net_e1000_igb` PMD), running the **official,
unmodified 2105 shipping ISO** installed to disk (`DANOS:Shipping:2105:20210611`,
kernel 5.4.115), console access over a real USB-serial adapter (`/dev/ttyUSB0`,
115200) rather than a QEMU chardev.

Bring-up needed one correction not seen in the QEMU harness: `dp0p1s0` was set to
`address dhcp`, and `show interfaces` kept reporting `Link Down` although the
switch/NIC link LED was lit and `show interfaces dataplane dp0p1s0 physical`
separately reported `Link detected: yes` -- the two DHCP clients (this one and the
test host's) were each waiting for the other to be a server, so neither side ever
got an address to show. Replacing DHCP with static addresses on both ends
(`192.168.50.2/24` on `dp0p1s0`, `192.168.50.1/24` on the test host) resolved it
immediately: `u/u`, auto-negotiated to `a-1g/a-full`, sub-millisecond ping both
ways.

With connectivity confirmed, `add system image http://192.168.50.1:8080/upg.iso`
against the newly built `i-danos_2608_20260927T0704-amd64.hybrid.iso` (served over
plain HTTP from the test host) downloaded cleanly -- 571 MiB in 29s, 18-20 MB/s,
`ISO download succeeded.` -- and then failed the checksum check with the exact
text this section already documents:

```
Checking MD5 checksums of files on the ISO image...md5sum: WARNING: 1 computed
checksum did NOT match
Failed!
1 checksum failures found!
ISO image is corrupted and can not be used.
```

No interactive prompt followed; the shipped 2105 installer refuses outright and
returns to the CLI. This confirms the defect is not an artifact of QEMU's virtio
disks, sockets or timing, and that the "fix does not reach the systems that need
it" finding above holds for a real, officially-shipped 2105 install: this
machine cannot self-heal onto 2608 through `add system image` any more than a
virtual one can. The machine was left on 2105, unmodified, at the end of this
test -- no reinstall was attempted.

---

## 15. `vyatta_update_grub.pl` registers new images in a file nothing reads

Split out from the finding above with its own number because it is a
distinct, standalone defect in its own right, not a side effect of defect 14
or of the #33 investigation that led to it -- see the full root-cause writeup
directly above this heading for the evidence (`stat` output, the overlay
`upperdir` path, the confirmed read/write mismatch between `$grub_cfg` and
`get_live_image_root()`).

One line versions of both halves: `--generate-grub` writes a correct new
`grub.cfg` to `/boot/grub/grub.cfg`, which on a running installed system
resolves through the root overlay into the *current* image's own private,
ephemeral persistence directory -- never the shared, on-disk `grub.cfg` that
GRUB reads at boot and that `--list-images`/`--set-default-boot-index` also
correctly read via `get_live_image_root()`. So a second image can be copied
onto disk successfully and still never become bootable, with no error at any
step -- `add system image` reports `Done.` regardless.

**Fixed in vyatta-image-tools 5.53**, by computing `$grub_cfg` through
`get_live_image_root()` -- the exact resolution the read side already used --
instead of the hardcoded constant.

**Verified end to end, not just at the file level.** With the fix installed:
`--generate-grub=vyatta` made `--list-images` report `2608,vyatta`;
`--set-default-boot-index=vyatta` and a reboot landed the system on
`BOOT_IMAGE=/boot/vyatta/vmlinuz vyatta-union=/boot/vyatta`, with the admin
account and `ssh` still active -- config carried across the switch.
Setting the index back to `2608` and rebooting again returned
`BOOT_IMAGE=/boot/2608/vmlinuz vyatta-union=/boot/2608`, same account and
service state intact. Fetch a newer image, register it, select it, reboot
into it, select the original back, reboot into that -- all four steps of the
upgrade/rollback acceptance this investigation kept getting blocked on are
now proven on a real disk, not asserted from source reading.

---

## Two of these were hiding each other

The Perl warnings buried the SA table, so the empty table underneath — caused by
the crashing dataplane — could not be seen until they were cleaned up. Fixing
defect 1 did not make any test pass; it made defect 2 visible.

Worth expecting on a port of this size: the first fix in an area often reveals
the next rather than resolving the symptom.

---

## P0.5 acceptance: closed

The plan has five items. Item 4 (install/upgrade/rollback/cloud-init/
no-network/NIC-naming) is below first, since it is what this whole thread was
chasing. Items 1-3 and 5 (freezing the build snapshot, a unified release
directory, splitting `unknown` provenance into named categories, and
normalizing every result) came after, in one script -- see the second half
of this section.

### Item 4: install, upgrade, rollback, boot

Everything this thread was blocked on is now verified on a real disk, in
order:

1. **Disk install**, unattended, from a live boot -- proven earlier in this
   record (the driver-bug corrections above defect 14).
2. **Upgrade**: fetch a newer image over HTTP, checksum verifies (defect 14,
   5.52), copy succeeds, `--generate-grub` registers it in the shared on-disk
   grub.cfg (defect 15, 5.53) -- `--list-images` reports both.
3. **Select and boot the new image**: reboot landed on
   `BOOT_IMAGE=/boot/vyatta/vmlinuz vyatta-union=/boot/vyatta`, admin account
   and `ssh` still active.
4. **Rollback**: select the original index, reboot, landed back on
   `BOOT_IMAGE=/boot/2608/vmlinuz vyatta-union=/boot/2608`, same account and
   service state intact across both switches.
5. **81/81 regression, clean**, on a test ISO rebuilt with 5.53 -- the first
   run showed 27 failures, all in the three suites that lean hardest on SSH
   timing (ipsec/mpls/fw), while dpa/bgp/rest passed; the host's own load
   average was ~15 against 4 cores with 18 unrelated qemu processes running
   at the time (`danos-open`, not this project's). Rerun once that eased
   (load ~7.8) passed 81/81 identically. Recorded here rather than silently
   discarded, because a flaky rerun that happens to pass is not the same
   claim as a clean run under load that was never explained -- this one was.
6. **cloud-init**: booted with the existing NoCloud seed
   (`local-hostname: danos-ci-test`) -- prompt and `hostname` both read
   `danos-ci-test`, no stall, confirming defect 4's fix (all four
   configd-dependent modules moved to `cloud_config_modules`) still holds on
   this build.
7. **No-network boot**: the installed disk booted with zero `-netdev`
   arguments at all (not merely an unplugged cable) and reached a usable,
   authenticable login in under a minute.
8. **Interface naming stability**: `dp0s3` -- name and MAC -- was identical
   before and after a reboot of the same disk.

Real hardware NICs remain out of scope for this pass, as recorded under "What
'verified' covers, and what it does not" in `UPGRADE-RECORD.md` -- QEMU's
virtio PMD is not a physical NIC's driver path, and that gap is named there
rather than claimed closed here.

One thing surfaced along the way stays open on its own: an installed image's
directory sometimes lands under a name that was never typed (`vyatta`
instead of an explicitly answered `2608b`, content correct, name not) --
see the writeup under defect 14. It did not block this acceptance, because
the real name is always knowable by listing `/boot`, but it is not
explained.

### Items 1-3 and 5: `toolkit/release/mk-release.py`

One script rather than four, because all four items read the same inputs --
the ISO's own manifest, the OBS project's current state, this project's git
repositories, and the `.commit` files `mk-dsc.sh` already writes when it
builds a `.dsc` -- and produce one coherent answer: where did every byte on
this ISO come from, and is that knowable.

Run for real against `i-danos_2608_20260922T1655-amd64.hybrid-test.iso`, not
just exercised on sample input. Of 1522 installed packages: 568 resolved to
an exact commit (`local_git`), 950 came unchanged from the configured Debian
mirror (`external_source`), 2 matched the 2105 baseline byte-for-byte
(`signed_alias`, inherited rather than rebuilt), 1 was built by this
project's OBS project with no matching `.commit` for the exact version
installed (`obs_package_revision`), 1 resolved to an exact commit under a
*different* version string (`local_git_version_stamped`, added after
checking the two `obs_package_revision` rows below) -- and 0 were
`unresolved`.

The original two `obs_package_revision` rows were themselves a real, useful
finding rather than noise, and checking them (rather than accepting them as
"known gaps") resolved one of the two: `vyatta-version`'s `debian/rules`
deliberately overrides its package version at build time (`dh_gencontrol -p
vyatta-version -- -v$(VVERSION)`, `VVERSION` computed from
`scripts/get_vyatta_version`), stamping the release number ("2608") into
every installed vyatta-version package regardless of what
`debian/changelog` says ("1.4", which does have a recorded commit,
`1faa5269d203f6310fa49f73d7563780e1da18b6`). `mk-release.py`'s
`resolve_source()` now checks, when the exact installed version has no
match, whether the same source package has exactly one commit recorded under
any other version, and resolves that case as `local_git_version_stamped`
rather than the less specific `obs_package_revision` -- ambiguous cases
(more than one distinct commit on file for the source) still fall through
unchanged, so this does not turn into a guess where more than one candidate
exists.

`linux-signed` is correctly `obs_package_revision`, not a gap: its own
`Packages` entry names `Maintainer: OBS signing service <obssign@obs.service>`
-- it is the signed-kernel package OBS's signing infrastructure produces as
a byproduct of building `linux-image`, not a package with source of its own.
There is no local repository for it (checked: no
`build-iso/danos-sources/linux-signed`, no `.obs/dsc/linux-signed*`) because
there is nothing to check out -- `obs_package_revision`'s own definition
("traceable to the OBS package, not to a specific commit") already says
exactly what this is.

`vyatta-image-tools` resolved correctly to `1923cc0`, today's grub-write-path
fix commit -- confirming the mapping is right on a case already known to be
right, not just plausible-looking on cases nobody checked.

`verification-summary.json` lists every P0.5/P1/P2 item this project tracks,
including the ones not started, with `NOT_RUN` rather than omitting them --
the acceptance plan's own rule ("禁止用 not_run 隐藏实际缺口") applied to the
summary about itself, not only to individual test results.

---

## Retracted: the "FIREWALL_DANOS timing window" was a confound, not a finding

An earlier version of this section claimed `vm-sanity.sh` (the readiness
gate's qemu-process check) destabilized `FIREWALL_DANOS` -- six runs, three
failing with the gate wired in, three passing without it, read as a causal
timing effect and used to justify reverting the gate's wiring (`defd3ac`).

That comparison had a real flaw: the two blocks of runs were sequential, not
interleaved -- all three "with the gate" first, then all three "without"
after. A sequential before/after comparison cannot distinguish "the change
caused this" from "something else changed during the time it took to run
both blocks", and something else genuinely had changed: this same session
hit a severe host memory crisis in exactly that window (down to ~3Gi free of
22Gi, swap nearly full -- severe enough that the harness's own low-memory
protection killed an unrelated background wait loop partway through), which
eased across the gap between the two blocks.

Re-tested properly on request: the exact original gate, re-applied fresh,
passed `FIREWALL_DANOS` 16/16 three separate times under normal host load
(one of those runs also correctly caught a genuine, unrelated router-boot
failure and refused to waste time on it -- the gate doing its job). Three
further isolation tests -- a flat sleep matching the gate's worst-case added
delay, the network probe alone, and the pidfile/proc/socket checks alone,
none of the others active in each -- all passed 16/16 too, which argues
against a delay-based mechanism specifically, not just against the gate in
general.

**Corrected: there is no established timing window, and the gate is
re-wired** (`ab448b5`). Whatever made the original three runs fail was most
plausibly the host itself struggling under the memory crisis, not
`FIREWALL_DANOS`'s own logic -- though that was never confirmed either, since
by the time it was worth confirming, the pressure had already passed. If this
resurfaces, the first thing to check is host memory/swap state at the moment
of failure, not the test harness's own recent changes.

The mistake worth keeping on record is procedural: run paired comparisons
interleaved, not as two back-to-back blocks, especially on a host shared with
other work whose load is not under this project's control. This one cost a
correctly-working readiness check several hours of being wrongly blamed and
sitting reverted.

---

## P2: power-loss recovery of an installed system, measured

`vm/verify-power-loss.sh`. An installed 2608 system (fresh `accept-disk-install.sh`
run, disk written, booted from the disk) has its qemu process SIGKILLed at
chosen moments during `commit; save` of 40 static routes -- the operation that
rewrites `/config/config.boot` -- and is then booted again from the same disk.
A survivor must reach ssh, keep a writable filesystem, have no failed units,
hold **exactly** the old or the new `config.boot` (by hash, from a no-cut
control run and the pre-commit baseline), and agree with itself: the routes in
the file must be the routes zebra is running.

**Result: 23 of 23 cuts that could be judged were clean; 0 partial, corrupt or
inconsistent configs.** 15 came back with the complete old file, 8 with the
complete new one. The last sweep placed 10 cuts across the measured 2.02s
commit+save window (30%-100% of it): old at 0.60, 1.00, 1.21, 1.41, 1.51, 1.61,
1.71, 1.81 and 1.91s, new at 2.01s -- a single flip with nothing in between,
which is what an atomic replace looks like. ext4 reported `orphan cleanup` on
the cut boots, i.e. journal recovery did its job. Boot to ssh took 58-120s.

What this does **not** show. SIGKILL of qemu is a power cut *as the guest sees
it*: whatever the guest had not handed to the virtual disk is gone. It is not a
host power failure -- the host's page cache survives -- so it says nothing about
a hypervisor or disk that ignores flushes. Only one operation was cut
(config commit and save), and the sweep has one transition sample (1.91s to
2.01s), not a dense scan of it. No cut was placed during the boot itself, or
during an image upgrade.

### Three ways the harness was wrong first, recorded because each looked like a
product failure

1. **"Did not come back to ssh after the cut", 2 of the first 6.** Not a product
   fault. The disk of a failed trial booted fine when copied and started on its
   own (57s, config intact), and its journal showed no second boot at all
   between the cut and the forensic boot -- the replacement VM never ran. The
   harness restarted after a fixed 3s sleep, but a SIGKILLed qemu on this host
   (or, for the ~130s case, a SIGTERM then SIGKILL) was measured to take
   **0.2s, 3.9s, 15s, 32s, 130s and 432s** to actually exit, and
   until it does it holds the image's write lock and the ssh port. The harness
   also sent `boot-vm.sh`'s output to `/dev/null`, so the failed start looked
   like a slow boot. The cause of the slow exits is the host: swap was 100%
   full (8191/8191 MB) with 8.5 GB of RAM free, on a machine shared with a
   dozen unrelated VMs. Fixed: `wait_gone` blocks until the process is gone, and
   a failed post-cut boot now dumps the serial screen and `qemu.log`. The
   original two failures were not reproduced after the fix (5 of 5 then 10 of
   10 passed), which is consistent with this explanation but is not a
   reproduction of it.
2. **Fixed-second delays are the wrong instrument.** Two runs at the same
   2.4s gave both answers (old, then new), because how long the commit takes
   moves with host load and so does the delay at which the file flips. The
   control run now times its own commit+save and `FRACTIONS` places the cuts at
   fractions of that.
3. **`sudo` did not exist over ssh** for the installer-created `vyatta` account
   (pam_sandbox hides it for anything below `superuser`). The base disk was
   given `set system login user vyatta level superuser`, which is what
   `prep-router.sh` does for the test suites too.

A process note in the same vein as the retraction above: a `rm -f $RUN/*.sock`
issued while the VM was still running deleted its console socket, leaving it
reachable only by ssh. The commands now use `"${RUN:?}"` and only clean up
after the pid is verified gone.

---

## 16. A power cut during `add system image` leaves a machine that cannot boot

Found by `vm/verify-power-loss-more.sh`, the second half of the P2 power-loss
work. **Fixed in vyatta-image-tools 5.54 (`b8db06c`), not yet verified against a
rebuilt image.**

Cutting power (SIGKILL of qemu, as the guest sees it) at 13 points across an
uninterrupted 31s `vyatta-install-image` run on an installed 2608 disk:

| cut at | what was on disk afterwards | outcome |
|---|---|---|
| 7.7s - 23.2s (8 points) | nothing, or an unreferenced partial `/boot/upg1/` | old image boots; the retry install completes |
| **24.7s** | `grub.cfg` default = new image; squashfs truncated | old image came up (see below); retry recovered |
| **26.3s** | `grub.cfg` default = new image; kernel 0 bytes, initrd 43%, squashfs 89% | **no boot, forever** |
| 27.8s - 30.9s (3 points) | complete | the new image boots |

The 26.3s disk was kept and reproduced the failure exactly: GRUB prints
`error: file '/boot/upg1/vmlinuz' not found. error: you need to load the
kernel first. Press any key to continue...` and returns to the menu whose
default is the broken entry. Choosing the old image by hand over the console
boots it normally, so nothing was lost -- but an unattended box does not
recover without someone at the console.

The 24.7s state (kernel and initrd whole, squashfs truncated) was rebuilt on
the 26.3s disk by copying the old kernel and initrd in: live-boot prints `BOOT
FAILED! ... Can not mount /dev/loop0 (/run/live/medium//boot/upg1/upg1.squashfs)`
and stops at an `(initramfs)` shell. Same result, no automatic fallback.

**Cause.** `install_image()` copies the squashfs, kernel and initrd and
returns; there is no sync or fsync anywhere in `vyatta-install-image`, its
functions file, `vyatta_update_grub.pl` or the postinstall scripts. The next
step rewrites `grub.cfg` -- by writing a temp file and renaming it over the old
one, which is correct, and which ext4 also flushes eagerly (its replace-via-
rename heuristic), committing the journal with it. So the file that makes the
new image the default is durable within seconds, while the several hundred MB
it points at can sit in the page cache for tens of seconds. Timestamps on the
26.3s disk agree: `grub.cfg` was written about 8s before the cut, the image
data was not on disk at the cut.

**Fix.** `sync -f` on the new image's directory (plain `sync` as fallback)
between the copy and the post-install. Not touched: `cp`'s exit status is
ignored (`>&/dev/null`, no check), a related weakness left alone because
`cp --preserve=all` can fail harmlessly on some filesystems and checking it
would change behaviour.

**One thing not explained.** At 24.7s the machine did come up on the old image
even though its `grub.cfg` said default = new. The hypothesis is that GRUB read
`grub.cfg` before ext4 replayed its journal (so it saw the *old* file) and Linux
replayed it only after mounting -- which would mean the *next* reboot fails the
same way. That disk was overwritten by the retry before it could be checked, so
this is a hypothesis, not a finding.

**Not yet verified:** the installer executes *from the ISO being installed*
(it re-runs itself from the mounted squashfs), so 5.54 only takes effect in an
ISO built with it. The check is to rerun
`MODE=upgrade FRACTIONS="0.75 0.8 0.85 ..." vm/verify-power-loss-more.sh` with
that ISO and confirm the 24-27s window is now clean.

### Cutting power during boot: 9 of 9 clean

Same script, `MODE=boot`: qemu killed 4, 8, 12, 16, 20, 25, 30, 40 and 50
seconds after it starts (firmware, kernel, initramfs, overlay mount, systemd),
then booted again. All 9 came back to ssh with a writable filesystem, no failed
units, the identical `config.boot` and a complete image set. Boot barely writes
to the disk, so this was expected to be uneventful; it is recorded because that
was an expectation, not a measurement, until now.

### Two harness mistakes, kept because each read as a product result

1. After a clean reboot into the new image the checker script was gone --
   `/tmp` does not survive a reboot -- so `running` came back empty and the
   control run reported "rebooted but not into upg1". The image did boot.
2. A first look at the control disk left over from a run whose VM was killed
   mid-first-boot would not accept the login. That is a separate, unexamined
   question (a cut during the *first boot of a new image*) and is not part of
   what was measured here.

---

## P2: the Secure Boot chain, measured with real OVMF firmware

`vm/verify-secure-boot.sh` (with `vm/efi-inspect.py`). The ISO's UEFI image was
read with no root and no mtools, and booted under OVMF with Secure Boot on
(`OVMF_CODE_4M.secboot.fd`, Microsoft keys enrolled).

**The chain.** Debian shim 16.1, signed by Microsoft (UEFI CA 2011), then
`GRUBX64.EFI` and the kernel, both signed with the OBS project's own
certificate (`CN=home:i-danos OBS Project`, self-signed, valid until
2028-10-29). The shim carries the Debian CA, not the OBS certificate, so the
firmware accepts the shim and the shim will not accept GRUB unless the OBS
certificate is enrolled as a MOK. That is a deployment requirement, not a
defect: a machine with only Microsoft keys and no enrolled OBS certificate
cannot boot this ISO under Secure Boot, and says so (below).

| test | setup | result |
|---|---|---|
| T1 | Microsoft keys only | refused by shim: `Verification failed: (0x1A) Security Violation` (screenshot kept) |
| T2 | OBS certificate enrolled as MOK | boots: `EFI stub: UEFI Secure Boot is enabled`, `Secure boot enabled`, `LSM: initializing lsm=capability,lockdown` |
| T3 | T2 + one bit flipped in GRUB | refused by shim |
| T4 | T2 + one bit flipped in the kernel | GRUB reaches its menu, then `bad shim signature` and refuses the kernel |

T2 and T4 differ by exactly one bit, so the T4 refusal is the signature check
and not the kernel failing for another reason. The tampered bit was written into
a private copy of the ISO at the offset `efi-inspect.py` reported (checked by
comparing those bytes against the extracted files first) and restored after; the
original ISO was never opened for writing. The MOK was injected into OVMF's
variable store with `virt-fw-vars` from a scratch virtualenv -- nothing was
installed system-wide.

The running kernel also logs `Loaded X.509 cert 'Vyatta Secure Boot DB: ...'`,
a certificate of its own on the platform keyring.

**What this does not show.**
- Only the **live ISO** boot was tested. The installed-disk UEFI path
  (`install_grub_efi`, and the installer's own `check_binary_signatures`, which
  warns when Secure Boot is on and the image's binaries cannot be verified) was
  not run. The disk installs in this project boot by BIOS.
- The MOK was written into NVRAM directly. The interactive MokManager
  enrollment an operator would do was not exercised.
- One flipped bit in one place per binary. No revocation (dbx, SBAT) test, no
  test of module signature enforcement beyond seeing `lockdown` initialize.
- The OBS certificate expires 2028-10-29; nothing here checks what happens to
  images signed after that.

**A harness finding worth keeping.** OVMF's first line of output took 2s, 68s,
138s, 192s, 412s and 474s to appear across runs on this host (swap full, other
projects' VMs running). A fixed 60s window read that slowness as "not refused"
three times and as "did not boot" once. The clock now starts at the first line
of real text -- not the first byte, which is only the terminal's reset
sequence -- and each test's verdict is read from the serial output and a
screenshot, never from silence.

---

## 17. The image cannot be installed to disk on a UEFI machine

Found by the first UEFI install of this image (`vm/uefi-vm.sh`, OVMF with
Secure Boot on, `console-install.py` driving `install image` from the live
system). Every disk install in this project until now booted by BIOS, which is
why nothing had exercised this path.

The installer partitions the disk correctly (GPT, a 512 MB ESP, an ext4 root)
and then fails at the boot loader:

```
Setting up grub on /dev/vda: ERROR: grub-install --uefi-secure-boot --no-floppy ...
grub-install: error: cannot open `/usr/lib/grub/x86_64-efi/linuxefi.mod': No such file or directory.
ERROR: Grub failed to install!
```

**Cause.** `install_grub_efi` passes `grub-install` a hardcoded 55-module list
(`grub_efi_modules`, "based on grub2/debian/build-efi-images"). GRUB 2.12
(Debian 13; the image has 2.12-9+deb13u2) folded `linuxefi` into `linux` and
does not ship `linuxefi.mod`. Compared against the modules the image actually
has, `linuxefi` is the only one of the 55 that is missing.

**Verified at the grub-install level, not yet through the installer.** The same
command run against a loop device with a real ESP, in a guest running the same
GRUB: with `linuxefi` it fails with the message above (rc=1); without it, it
finishes (rc=0) and writes `/EFI/debian/grubx64.efi` and `grub.cfg`. (The test
adds `--target=x86_64-efi` and `--no-nvram` because the guest was BIOS-booted;
a first run without the target silently exercised `i386-pc` and proved
nothing.) **Fixed in vyatta-image-tools 5.55 (`ff5ffc7`).** The installer runs
from the ISO being installed, so it needs an ISO built with 5.55 to test the
real thing.

## 18. Probably: an installed UEFI disk gets no shim, so it cannot boot under Secure Boot

Not confirmed end to end -- listed with what is and is not known.

Known: the image has `shim-unsigned` and `shim-helpers-amd64-signed` (only
`fbx64.efi.signed` and `mmx64.efi.signed`) but not `shim-signed`, the package
that provides `usr/lib/shim/shimx64.efi.signed`. The installer's own
`check_binary_signatures` looks for that exact file. And the ESP that
`grub-install --uefi-secure-boot` wrote in the test above held only
`grubx64.efi` and `grub.cfg` -- no `shimx64.efi`, no `BOOTX64.EFI`.

Also known, from the Secure Boot work above: the firmware trusts the Microsoft
shim, not the OBS-signed GRUB, which is trusted only through the shim's MOK. A
GRUB with no shim in front of it is therefore refused by the firmware.

Not known: whether the installer, when it runs for real on UEFI with NVRAM, puts
a boot entry that points at something bootable, and what an installed disk does
under Secure Boot end to end. Same limit as above -- it needs the rebuilt ISO.

The change made (`build-iso` `15f95d7`) is one line: `shim-signed` in
`bootloaders-signed.list.chroot` (1.51~1+deb13u1+16.1-2~deb13u1 is on the
Debian 13 mirror). It is an inference from the evidence, to be confirmed or
rejected by the UEFI install of the rebuilt ISO.

### A note on `check_binary_signatures`

It compares the *subject* of each binary's signing certificate with the subjects
of certificates in the firmware's `db`, by equality. The shim is signed by a
Microsoft leaf certificate (`Microsoft Windows UEFI Driver Publisher`) and `db`
holds the CA (`Microsoft Corporation UEFI CA 2011`), so as written the shim can
never match and the check fails on any standard Secure Boot machine, prompting
`Continue with installation? (Yes/No) [No]`. This is read from the code and
not yet observed: the check runs only in `add system image <URL>`, which needs
an installed UEFI system first.

---

## 16, verified: the 5.54 flush closes the window

`vyatta-image-tools` 5.55 (5.54's `sync -f` plus the defect 17 fix) was uploaded
to OBS, built, pulled into the local repository, and put in a new test ISO
(`i-danos_2608_20260924T1022`, checked to contain `vyatta-image-tools 5.55`,
`shim-signed` and `shimx64.efi.signed`). The installer runs from the ISO being
added, so that ISO was the upgrade source.

**The method changed, because the first one could have given a false pass.**
Cuts placed at fractions of the install time (24.7s, 26.3s of ~31s) hit the
window by luck: how long an install takes moved between 24s and 33s with host
load, and the window is only a few seconds wide. The cut is now triggered by an
event -- the first change of the shared `grub.cfg` -- and delayed 0, 0.5, 1, 2,
4 and 6 seconds after it. The window is "grub.cfg names the new image, its data
is not on disk yet", and it opens at that event whatever the load.

A positive control came first. With the **old** installer (5.53) as the upgrade
source the same six cuts reproduced the defect, so the method is known to hit it:

| cut after grub.cfg first changes | old installer (5.53) | new installer (5.55) |
|---|---|---|
| +0s | harmless: not referenced, orphan dir | harmless: same |
| **+0.5s** | **FAIL**: referenced, squashfs 511,705,088 of 549,777,408 bytes, default = new image | pass: grub does not reference the new image yet |
| **+1s** | **FAIL**: squashfs 494,927,872 bytes | pass: new image complete and running |
| +2s, +4s, +6s | pass (data already written) | pass |
| total | 4 passed, 2 failed | **6 passed, 0 failed** |

At the offsets where the old installer left a default entry pointing at a
truncated image, the new one either has not referenced the image yet or already
has it in full.

**What this does and does not show.** One trial per offset per installer, six
offsets: the mechanism (flush before pointing grub at the data) and the A/B agree,
but this is not a large sample. It covers cuts from the first `grub.cfg` change
onward; cuts earlier in the install were already harmless in the fraction sweeps
(a partial, unreferenced directory that a retry replaces). It is a guest-visible
power cut, not a host power failure. The open hypothesis under defect 16 -- that
GRUB reads `grub.cfg` before ext4 replays its journal, so a broken default can
be masked for one boot -- is still untested.

---

## 17 and 18, verified through a real UEFI install of the rebuilt ISO

Same machine setup as the Secure Boot tests: OVMF with Secure Boot on, the OBS
certificate enrolled as a MOK, the ISO (now `i-danos_2608_20260924T1022`, with
`vyatta-image-tools` 5.55 and `shim-signed`) and a blank 20 GB disk;
`console-install.py` drove `install image` from the live system.

- **17 fixed through the installer, not just at the grub-install level.** The
  installer ran to `Setting up grub on /dev/vda: OK` and `Done.` where the old
  ISO died on `linuxefi.mod`. The output also shows the 5.54 line, `Flushing
  the new image to disk...`.
- **18 confirmed.** The ESP the installer wrote holds `\EFI\debian\shimx64.efi`
  (Microsoft UEFI CA 2011), `grubx64.efi` (OBS project certificate),
  `mmx64.efi` and `fbx64.efi` (Debian Secure Boot CA), `BOOTX64.CSV` and
  `grub.cfg`. The earlier grub-install run against a loop device, on the old
  package set, wrote `grubx64.efi` and `grub.cfg` only. The one-line
  `shim-signed` change (`build-iso` `15f95d7`) is what closes it.
- **The installed disk boots under Secure Boot.** Booted alone, with the NVRAM
  the installer had written: firmware loaded boot entry `Boot0005 "Vyatta-vda"`
  = `\EFI\debian\shimx64.efi`, shim started GRUB 2.12, the menu showed `Vyatta
  2608 (Configured console)`, and the system reached `node login:`.
- **Tampering is refused.** One bit flipped in the installed
  `\EFI\debian\grubx64.efi` (offset found by reading the ESP's FAT, changed in a
  copy of the disk with `qemu-io`; the original was not touched): the same boot
  entry now stops at shim's `Verification failed: (0x1A) Security Violation`
  (screenshot kept). Untampered, the same NVRAM boots.

**Not done, and why.**
- **`add system image` under Secure Boot** (the installer's
  `check_binary_signatures`) was not run. It needs root and a network inside the
  guest, and on this machine the data plane never took over the NIC: it stayed
  the kernel's `enp0s2` (state A/D) after a reset, `dp0s2` was accepted in the
  configuration with "device dp0s2 does not exist", and `dataplane enp0s2` is
  rejected. The BIOS test machines show `dp0s3` right after boot. Whether this
  is the q35 machine's PCI naming (`enp0s2` where i440fx gives `ens3`) or
  something about UEFI was not investigated. So the reading in the note under
  defect 18 -- that the subject comparison can never match the Microsoft-signed
  shim -- is still from the code, not observed.
- The running kernel's own view (`mokutil --sb-state`, lockdown) was not read:
  the login sandbox hides `mokutil` and `/sys/kernel/security`, and root was not
  reachable for the reason above. What shows Secure Boot was on is that shim
  refused the tampered GRUB on the same firmware and NVRAM.
- The MOK was written into NVRAM directly; MokManager's interactive enrollment
  was not exercised. No dbx/SBAT revocation test.

---

## 19. Under Secure Boot the data plane will not start without an IOMMU (by design)

Found while trying to run `add system image` on the installed UEFI system: on
the q35 machine the NIC stayed the kernel's `enp0s2` and no `dp0*` interface ever
appeared. It looked like the data plane failing to claim the NIC; it is the data
plane deliberately not starting.

**What the machine does.** `vyatta-dataplane.service` is `failed` and restarts in
a loop. Its `ExecStartPre` `/lib/vplane/vplane-uio` prints

```
Secure Level / Lockdown enabled and iommu/vfio not available
```

and exits 255. The script (`vyatta-dataplane/tools/vplane-uio`) hands the NICs to
DPDK one of three ways: with an IOMMU present (`/sys/kernel/iommu_groups`
non-empty) it uses `vfio-pci`; without one, if "Secure Level" is on
(`/sys/kernel/security/securelevel` is 1, **or `dmesg` contains `Secure boot
enabled`**) it refuses; otherwise it uses `uio_pci_generic`. QEMU's q35 has no
IOMMU unless one is added, so with Secure Boot on it takes the second branch.
Without Secure Boot the same disk takes the third and works (`dp0p0s2`). The
`dmesg: write error` line before it is `dmesg | grep -q` closing its pipe early;
harmless. On real hardware with VT-d enabled the first branch applies.

**Verified both ways on the same disk and NVRAM:** with Secure Boot and a virtual
IOMMU (`-machine q35,kernel-irqchip=split -device intel-iommu,intremap=on,caching-mode=on`,
NIC with `iommu_platform=on,disable-legacy=on`) the data plane is `active`, the
NIC is bound to `vfio-pci` and comes up as `dp0p0s2` with a DHCP address. Without
the IOMMU it does not start; with Secure Boot off it starts on `uio_pci_generic`.
The NIC's name is `dp0p0s2` (bus 0, slot 2): on q35 DANOS uses the
`dp<F>p<N>s<S>` form. `dp0s2` and `dataplane enp0s2`, which I tried first, are
not valid there -- part of the first "not claimed" reading was me using the wrong name.

**A deployment requirement, not a defect to fix:** a Secure Boot machine needs an
IOMMU for the DANOS data plane to run. Nothing in the image says so before the
service fails.

### A wrong turn, kept because it was convincing

I first explained this as kernel lockdown: enabling lockdown by hand on a working
machine (`echo integrity > /sys/kernel/security/lockdown`, then restarting the
data plane) really does give `0 ports available` and `dmesg` says `Lockdown:
dataplane: direct PCI access is restricted`. But on the actual Secure Boot machine
`/sys/kernel/security/lockdown` reads `[none]` and there are no `Lockdown:` lines:
this kernel is built `LOCK_DOWN_KERNEL_FORCE_NONE` and has no lock-down-in-EFI-
Secure-Boot option, so Secure Boot does not lock it down. The experiment was real
and the conclusion did not apply. What separated them was reading the kernel's
state on the machine in question instead of on the one where it was easy to look.

### Two mistakes in the harness that made this look harder than it was

- `console.py` reuses an already-open login, so a second call after making
  `vyatta` a superuser still ran in the old session, without the new group, and
  the sandbox stayed. The group was on disk (`vyattasu:x:109:vyatta`, in the
  overlay's persistent `etc/group`, seen by mounting the disk in another guest).
  Logging out first, or a fresh session, is what picks it up.
- A host reboot between sessions took down the `danos-robot` container and the
  running VMs; the installed disk and its NVRAM survived, the VM did not.

## `add system image` under Secure Boot, observed

With root and a network (the IOMMU setup above) `vyatta-install-image
http://.../upg.iso` on the Secure Boot system prints, after the download and the
MD5 check:

```
Signing check, no match in signature list for /mnt/cdsquash/usr/lib/shim/shimx64.efi.signed
Warning: secure boot is enabled, but not all signed binaries could be verified ...
Continue with installation? (Yes/No) [No]:
```

Answering No quits. This confirms what was read from the code. `check_binary_signatures`
compares the **subject** of each binary's signing certificate with the subjects in
the firmware `db` by equality. The shim's signer subject is `...CN=Microsoft
Windows UEFI Driver Publisher`; `db` holds the *issuer*, `Microsoft Corporation UEFI
CA 2011`, so it never matches, and the function returns at the first miss without
looking at GRUB or the kernel. Those are signed by the OBS certificate, which is
trusted through the shim's MOK and is not in `db`; the check never consults the
MOK. So on a standard Secure Boot machine, `add system image` always warns and
defaults to No, even with the OBS certificate correctly enrolled -- a false alarm
the operator has to override each time, not a functional break. Fixed in
vyatta-image-tools 5.56 and 5.57 -- see "21. `check_binary_signatures` rejected a
bootable image" at the end of this file.

## What this closes of the earlier Secure Boot gaps

- The kernel's own view was read: `mokutil --sb-state` says `SecureBoot enabled`,
  the kernel logs `Secure boot enabled`, lockdown is `[none]`.
- `add system image` under Secure Boot was run and its check observed (above).
- Still not done: MokManager's interactive enrollment (the MOK is written into
  NVRAM), dbx/SBAT revocation, behaviour after the OBS certificate expires
  2028-10-29.

---

## 20. The ISO's `.packages` manifest is a mid-build snapshot, and the SBOM was built from it

Found by checking that the new ISO's package count had moved after `shim-signed`
was added: it had not (1522 before and after).

Compared with what is really installed (`var/lib/dpkg/status` inside the ISO's
squashfs, 1524 packages), the manifest live-build writes next to the ISO
(`<name>.packages`) **lacks four installed packages** -- `shim-signed`,
`shim-signed-common`, `mokutil` and `grub-efi-amd64-signed`, the signed-boot
components an SBOM most needs to show -- and **lists two that are not in the
image**, `libfribidi0` and `shared-mime-info`. Versions of the packages both
have agree. The new manifest was identical to the previous ISO's, added and
removed nothing, although a package list had changed in between. So it is
captured before the last install step and the hooks that clean up, not from the
final image.

`mk-release.py` built `sbom.json` and `source-revision-map.json` from that
manifest, so the P0.5 SBOM the summary marked PASS was incomplete in exactly the
place this session's Secure Boot work cares about. Not caught earlier because
every check of it compared the manifest with itself.

**Fixed in `release/mk-release.py`.** The installed set is now read from the
image's own dpkg status, extracted from the ISO's `/live/filesystem.squashfs`
(so it works on a release directory, not only on the latest build tree); it
fails loudly if that cannot be read rather than falling back to the manifest.
The manifest is still copied verbatim, and `manifest-vs-image.json` records how
it differs, so the disagreement stays visible. Re-run on the new ISO: 1524
packages, the four above present (`grub-efi-amd64-signed` as
`obs_package_revision`, the OBS signing service's product like `linux-signed`;
the other three as `external_source`).

Not yet known: where in the live-build sequence the manifest is written, and
whether the two extra names (`libfribidi0`, `shared-mime-info`) are removed by a
hook; only the difference was established, not its cause.

---

## The MOK enrollment an operator has to do, walked through

The Secure Boot chain only boots once the OBS certificate is a MOK (see the
Secure Boot section). Until now the tests wrote it into NVRAM directly; this is
the flow an operator actually follows, on the installed UEFI system:
`vm/mok-import.sh` for the first half, MokManager driven by key presses for the
second, a screenshot at each step (`steps/`).

1. Boot the installed system with Secure Boot **supported but off**
   (`SecureBootEnable=0`, on the Secure Boot firmware) and `mokutil --import`.
2. Turn Secure Boot on, reboot. shim starts MokManager (`attempting to load
   \EFI\debian\mmx64.efi`, `Verification succeeded`: it is signed by the Debian
   CA that shim carries). Screens, in order: "Press any key to perform MOK
   management" (10 s), "Perform MOK management" (Continue boot / Enroll MOK / ...),
   "[Enroll MOK]" (View key 0 / Continue), the key's details, "Enroll the
   key(s)?" (defaults to **No**), "Password:", then a menu whose first item is
   Reboot.
3. After Reboot the same boot entry goes shim -> GRUB menu -> `login:`, with
   Secure Boot on. In the guest: `mokutil --sb-state` = `SecureBoot enabled`,
   `mokutil --list-enrolled` lists `CN=home:i-danos OBS Project` (valid to
   2028-10-29) beside `Debian Secure Boot CA`, and the kernel logs `Secure boot
   enabled`. MokManager's "View key 0" showed issuer/subject `CN=home:i-danos
   OBS Project`, Code Signing, and a SHA-1 fingerprint and serial that match the
   certificate byte for byte (checked against `openssl` on the host).

**Four things an operator will hit** (all reproduced, none fixed -- they are
properties of mokutil, shim and this kernel, and the third is worth a line in a
deployment note):

- `mokutil` refuses on firmware with no Secure Boot at all ("This system doesn't
  support Secure Boot"), so the firmware must be a Secure Boot build with
  Secure Boot switched off, not a non-enforcing one.
- **`mokutil --import` silently does nothing for this certificate.** It prints
  `Already in kernel trusted keyring. Skip <file>` and exits 0, because the
  kernel has the certificate built in (`Loaded X.509 cert 'Vyatta Secure Boot
  DB: ...'`). The kernel's keyring is not shim's MOK list, which is what GRUB
  and the kernel are verified against, so nothing is submitted and the next boot
  fails with "Verification failed". `--ignore-keyring` is the option that submits it.
- The request is **consumed even when nothing is enrolled.** A first attempt
  pressed a Shift key to get past the 10-second gate; a modifier alone produces
  no key event in UEFI, MokManager timed out, continued to boot, and both
  `MokNew` and `MokAuth` were gone from NVRAM with no `MokList` created. The
  operator sees the shim error on the next boot and has to import again.
- A second key press at the wrong moment is a choice: the menu opens on
  "Continue boot", and extra key presses after the gate carried it on to boot.

Not covered here: dbx/SBAT revocation, and behaviour after the certificate
expires on 2028-10-29.

---

## SBAT revocation and certificate expiry, measured

Same ISO and the same NVRAM (OBS certificate enrolled), Secure Boot firmware.

**SBAT.** The ISO's GRUB declares `grub,5`, `grub.debian,5`, `grub.debian13,1`;
shim's revocation level (`SbatLevel`) is `sbat,1,2025021800 / shim,4 / grub,5`.
With the level as it is, shim logs `grub, 5` verified and the GRUB menu appears
(~24 s). With `SbatLevel` set to `grub,6` in the NVRAM (`virt-fw-vars
--set-sbat-level`), shim logs

```
component grub, generation 5, was revoked by SbatLevel variable
Verification failed: Security Policy Violation
```

and no GRUB menu appears. (A different message from a bad signature's `Security
Violation`.) The practical consequence for DANOS: this GRUB is at exactly the
current revocation level, so the day shim or the firmware raises the minimum
`grub` generation to 6, this image stops booting under Secure Boot until GRUB is
rebuilt and re-signed from a newer Debian `grub2`. Nothing in the image or the
release process tracks that.

**Expiry.** With the VM clock set to 2030-01-01 (the guest's `date` confirms it),
past the OBS certificate's 2028-10-29 end, shim, GRUB and the kernel all still
boot: `Secure boot enabled` in the kernel log, a login prompt. shim does not
check certificate validity dates, so an expired signing certificate does not
stop an existing image from booting. Not tested: whether a *new* build signed
after expiry, or kernel module loading, behaves the same; only the boot chain was.

**Not done: dbx.** A firmware `dbx` entry revoking the shim's signer or hash. It
is the firmware's own behaviour, not something specific to this image, so it was
left; the SBAT test above covers the revocation that shim and GRUB enforce.

## DPA object model: nexthop-group class, and a coverage-probe defect

**Added.** `dpa object show nexthop-group` (vyatta-dataplane 3.14.40) walks the
IPv4 and IPv6 next-hop tables and emits `{class, key, state, backend}` with key
`inet/idx:N` or `inet6/idx:N`. The index is the slot routes point at, so a route
can be joined to its group. Verified live on three routers built from the 3.14.40
ISO: each router enumerated its groups, and every `nh_index` in `vplsh -c 'route
show'` was present in the enumeration (0 missing, three routers). Indices 0-3 are
enumerated but not referenced by any zebra route; that fits the four routes the
data plane installs itself (`reserved_routes` in `route.c`), which are allocated
first, but the index-to-route mapping was not checked one by one.

**Limits.** State is `no_support` and backend `sw-dataplane` on these machines
because there is no hardware backend; the programmed-in-hardware case is untested.
The class is coverage only: zebra has no comparable "desired" view, so it is not in
`dpa-drift.py`'s `COMPARED` set. Still `not_enumerable`: `qos-if`, `qos-vlan`.

**Defect (older than this change): `probe-dpa-coverage.sh` misreported QoS.** It
decided `enumerable` by finding the word `dpa_objects` in the reply, but a class with
no walker answers with the same envelope (`"enumerable":false,"reason":"no walker"`,
empty `objects`). It therefore reported `qos-if` and `qos-vlan` as `enumerable` --
the exact "absent vs not carried" confusion the class list exists to prevent. It now
reads the `enumerable` field, and also covers `vrf` and `nexthop-group`. Any earlier
coverage JSON that shows the QoS classes as enumerable is wrong.

## DPA object model: interface class

**Added.** `dpa object show interface` (vyatta-dataplane 3.14.41) lists the router
interface each L3 interface asked the backend to create, keyed `if:<name>`, with the
state and backend that creation returned. The result is stored on the ifnet
(`fal_l3_pd`, with `fal_l3_pd_set` marking that one exists, because the state's zero
value is FULL and a zero `fal_l3` handle cannot say *why* there is no object).

**Verified.** On a router with `dp0s8` (address) and `dp0s8.100` (VLAN, address):
the class is enumerable and lists `if:dp0s8.100 no_support sw-dataplane`; the same
after `systemctl restart vyatta-dataplane`. With no data plane interfaces configured
it lists nothing, correctly.

**Not covered -- physical ports, and why (found).** `dp0s8` and `dp0s9` are never
listed because the data plane never asks the backend for a router interface for them.
Traced with uprobes (addresses from the 3.14.41 dbgsym, interface name read from the
ifnet) across a data plane restart. Every interface goes through
`if_change_features_mode`; `lo`, `pimreg`, `pim6reg` and `dp0s8.100` then reach
`if_l3_enable`, while `dp0s8` and `dp0s9` stop there. The gate is
`if_get_emb_feats()`: for an ethernet port it asks `dpdk_eth_if_is_hw_switching_enabled`,
which returns `ifp->hw_forwarding`, and that returned 0 (probed, ~8 calls per port);
0 sets `IF_EMB_FEAT_HW_SWITCHING_DISABLED`, `l3_hw_enabled` becomes false, and
`if_l3_enable` -- hence `dpdk_eth_if_l3_enable` and `if_fal_create_l3_intf` -- is never
reached. `hw_forwarding` is only set by the `switchport <if> hw-switching enable`
config command (`switchport.c`); nothing else turns it on. So this is how the code
is meant to work: a router interface object is for a port switched in hardware, and a
routed port on a software data plane has none. It is not a porting gap.
What was not done: turning `hw_forwarding` on to see the port appear. `switchport` is
a controller config command; `vplsh` only sends operational commands and answers
"Unknown command". The chain is therefore shown by measurement at each step but the
last one (flip the flag, see the object) was not.

**Consequence for the class.** "interface" meant "the interfaces the data plane asked
the backend about", not "all L3 interfaces". A reader could not tell a routed port that
was never asked from one that does not exist. Reporting such ports with the existing
`not_needed` state ("not programmed as it is not needed there") closes that, at the cost
of changing what the class means (objects for which no backend call happened). That was
decided and done in 3.14.42; see "Routed ports, verified" below.

**Known gap.** The recorded state is cleared only from `if_fal_delete_l3_intf`, which
the caller reaches only when `fal_l3` is non-zero. With no backend it always is zero,
so an interface whose L3 is later disabled keeps its stale `no_support` entry until the
ifnet is freed. Harmless with no backend; with one, the state is overwritten on the
next create and cleared on delete. Not exercised.

**Not exercised.** GRE tunnels (the call is wired the same way, via `gre_if_l3_enable`).
Not compared against zebra: no comparable desired-side view.

## 21. `check_binary_signatures` rejected a bootable image

The two notes above ("A note on `check_binary_signatures`" and "`add system image`
under Secure Boot, observed") described the symptom and a cause read from the code:
on any standard Secure Boot machine `add system image` printed `Signing check, no
match in signature list` and defaulted to No, although the machine boots that image.
Both notes left the decision open ("what the check should trust: issuer, chain, MOK").
It was closed in two steps, and the first step was not enough.

**Two causes, not one.**

1. It compared the subject of the binary's *signing* certificate with the subjects in
   `db`. Firmware verifies a chain up to a `db` entry, and for a Microsoft-signed shim
   that entry is `Microsoft Corporation UEFI CA 2011`, the issuer; the signer
   (`Microsoft Windows UEFI Driver Publisher`) is never in `db`.
2. `sbverify --list` prints one `subject:` line per certificate in the chain and the
   code read them into one string. Reproduced with the real `shimx64.efi.signed` and a
   `db` holding the CA: the string had two lines, and no `db` subject can equal it.

**5.56 (`af89a40`, version `edd2628`).** Compares every certificate in the chain with
every `db` subject, in a helper `sig_chain_in_db` that also tells "no signature" (rc 2)
from "no match" (rc 1). Unit-tested against the real shim and GRUB: a `db` with the
Microsoft CA matches shim, an unrelated CA or an empty `db` does not, an unsigned or
missing file is "no signature". Built into an ISO and installed under OVMF Secure Boot,
the check on the real installed system **still failed, one binary later**: it passed
shim and stopped at `grubx64.efi.signed`.

**Why it stopped at GRUB.** This image's GRUB and kernel are signed by the OBS project
certificate (see the Secure Boot chain above). That certificate is enrolled as a MOK and
is not in `db`, and it is shim, not the firmware, that verifies GRUB and the kernel
against the MOK list. Comparing them with `db` alone can never match. The earlier note
had predicted this ("GRUB and kernel ... would also miss"); 5.56 made it observable
because shim no longer failed first.

**5.57 (`f87e9c1`).** Exports the MOK certificates with `mokutil --export` and compares
GRUB and the kernel with `db` plus MOK. Shim stays `db` only: firmware does not consult
MOK for it, so a MOK-signed shim must not pass. Best effort -- without `mokutil`, or
with nothing enrolled, only `db` counts, as before. Subjects are printed the same way
on both sides (`openssl x509 -nameopt compat`), checked against `sbverify`'s output.

**Verified**, on the installed disk of `i-danos_2608_20260926T0757-amd64.hybrid.iso`
(vyatta-image-tools 5.57) under OVMF Secure Boot, with the certificates the machine
really has (`db`: the Microsoft CAs; MOK: Debian Secure Boot CA and the OBS project
certificate): the function shipped in the image returns success and prints nothing.
Control: the same code with the MOK step disabled fails at GRUB with `no match in
signature list`, so the pass is the MOK and not a check that cannot fail.

**Not verified.** The interactive `add system image <URL>` run end to end with the new
installer: it needs an ISO to add and a network path into a Secure Boot guest, and the
data plane's IOMMU requirement (defect 19) makes that guest awkward to reach. The
function was exercised directly on the installed system instead. Machines whose `db` or
MOK differ from the one tested were not tried; in particular a machine that never
enrolled the OBS certificate still (correctly) fails at GRUB.

**A harness note.** The check was run by typing a script into the guest's serial
console, because the guest had no address. The first attempt read the return code with
`echo CHECK_RC=$?` and got `CHECK_RC=` -- the `$?` did not survive the console. Print an
explicit word (`&& echo PASSED || echo FAILED`) instead. The same console also turns a
tab into completion, which is the trap described in defect 22.

## 22. `accept-disk-install.sh` reported failures on a healthy install

Four independent harness faults, each of which read as a product failure. Fixed in
`toolkit` `ef558ba`; the script then passed 14 of 14 on both the test and the product
image, and the install itself was unchanged throughout.

- **A tab typed into a shell is completion.** The command that enables ssh was
  multi-line with tab-indented continuation lines. `console.py` types it into an
  interactive `vbash`, so the tabs produced a listing of operational commands
  (`traceroute ... twping ... update` in the log), and `set service ssh` and `commit`
  never ran. It is now one line with no tabs.
- **No address on the management NIC.** A fresh install leaves `dp0s3` admin-down. ssh
  through QEMU's `hostfwd` needs an address, so the script also sets
  `dp0s3 address dhcp`. Checked, not assumed: the configuration read back from the
  installed disk had no `dp0s3` line until the script wrote it.
- **The admin account is a sandbox.** The installer creates `vyatta` at level `admin`,
  whose shell has no `systemctl`; every service check said `Host is down` for a
  healthy system. The script sets `level superuser` in the same session.
- **The "live or installed" test could not tell them apart.** An installed DANOS boots
  as `boot=live` with an overlay root assembled from `/boot/<release>`, so "root is an
  overlay" and "boot=live" are true of it. The script now requires `BOOT_IMAGE=/boot/`,
  `vyatta-union=/boot/` and a virtio disk partition in use (`/dev/vda2`, or
  `/run/live/persistence/vda2/boot/...` where the sandbox hides the device name).

Also found: the restart step ran `sudo systemctl reboot` in the sandbox, which did
nothing, and ssh kept answering, so "it came back" passed for a machine that never went
away. It now reboots with `sudo -S` and requires a different `boot_id` afterwards.


## 23. `accept-lifecycle.sh`: three ways the first runs were wrong

Upgrade, rollback, interface naming, cloud-init and a no-network boot were each verified
by hand earlier and never scripted. `vm/accept-lifecycle.sh` runs them on an installed disk
(on a throwaway qcow2 overlay, so the disk is never written). On the 5.57 product image it
passes 13 of 13: a second image is registered and its files are on disk, the machine boots
it and boots the original again after a rollback with the admin account intact, `dp0s3` keeps
its name and MAC (`52:54:00:12:34:56`) across three boots, the seed's hostname is applied, and a
machine with no NIC reaches a login. The first two runs did not, for reasons that were the
script's, not the product's:

- **cloud-init was tested where it cannot run.** The cloud-init units carry
  `ConditionKernelCommandLine=cloud-init`. An installed disk boots from grub without that token
  by design (and the installer refuses to run with it), so a seed attached to an installed disk
  changes nothing and the hostname stays `node`. The check now boots live with `CI_TOKEN=cloud-init`,
  as the earlier evidence did. **What this leaves unverified:** cloud-init on an installed disk.
- **The console puts a carriage return before every output line.** `id -un` came back as `\rvyatta`,
  a whole-line match never succeeded, and a machine that booted to a login in about 150 seconds was
  reported as having no usable login after 457. Strip `\r`, and match a marker (`WHO=vyatta`) rather
  than a bare word, because the echoed command contains the word too.
- **"No network" needs `-nic none`.** Leaving `-netdev` off is not enough: QEMU adds a default NIC
  itself. And "only `lo`" is the wrong expectation: the guest always has virtual `pimreg` and
  `pim6reg`. The test is that no interface has a `device` link (a NIC does).

A fourth failure was environmental and looked like a product one: with the `danos-robot` container
stopped (a host restart stops it) every ssh fails and the first boot "did not reach ssh". It was first
put down to memory pressure -- an unrelated 9.7 GB process was running -- which was at most part of the
story. The script now checks the container and says so. The commands used are
`vyatta_update_grub.pl --list-images`, `--print-default-index` and `--set-default-boot-index=<name>`;
`vyatta-install-image --list-images` does not exist.

## DPA object model: routed ports, verified

`vyatta-dataplane` 3.14.42 (`9bf5bda`) lists a port that is not switched in hardware as
`not_needed` in the interface class. Its changelog said so; the code was not checked on a
running system until now, and the section "DPA object model: interface class" above still
called it undecided.

**Verified**, on the installed disk of `i-danos_2608_20260926T0757-amd64.hybrid.iso` (3.14.42),
through `/opt/vyatta/bin/vplsh -l -c 'dpa object show interface'` (evidence in
`acceptance-2608-20260926/dpa-interface/`):

| Step | Objects listed |
|---|---|
| Nothing configured | `if:dp0s3 not_needed`, `if:dp0s4 not_needed` (both `sw-dataplane`) |
| `dp0s4` given an address and a VLAN sub-interface `dp0s4.100` | the two above, plus `if:dp0s4.100 no_support` |
| After `systemctl restart vyatta-dataplane` | the same three |

The guest's own interfaces are `dp0s3 dp0s4 dp0s4.100 lo pim6reg pimreg`, so every listed
name is a real interface. `dp0s3` is the management port, which carries a dhcp address and is
still `not_needed`: the state describes the backend, not whether the port is in use.

**Why `lo`, `pimreg` and `pim6reg` are not listed (read from the code, consistent with
the observation above).** Two things have to be true for an interface to appear. Either it
asked the backend for a router interface (`if_fal_create_l3_intf` ran and set `fal_l3_pd_set`),
or it is one that *would* have asked but for hw switching being off: `if_created`,
`if_l3_enabled`, its type's `ifop_l3_enable` is set, and `IF_EMB_FEAT_HW_SWITCHING_DISABLED`
holds (`if_dpa_emit` in `src/if.c`). Only three interface types define `ifop_l3_enable` and
call `if_fal_create_l3_intf`: `dpdk-eth` (`dpdk_eth_if_l3_enable`), `gre` and `vlan`.
`lo_if_ops` (`src/if/loopback.c`) and `pimreg_if_ops` (`src/netinet/ip_mroute.c`) define none,
so `if_l3_enable` runs for them, as the earlier trace showed, and then calls nothing. The
code comment says so: types with no L3 router-interface support "are not listed at all: there
is nothing they could have asked for".

**A consequence, and the bridge case run.** By the same rule interfaces of type bridge, vxlan,
macvlan, vti, l2tpeth, ppp, ipip and vrf are never listed either, even when they carry an L3
address, because their `ift_ops` set no `ifop_l3_enable`. Checked for the case an operator would
ask about, a bridge SVI, on the installed 5.57 product image (evidence
`acceptance-2608-20260927/dpa-bridge/`):

| State | `ip -br addr` | Interface class |
|---|---|---|
| `br0` with `10.98.0.1/24`, no member (`DOWN`); `lo` given `10.98.9.1/32`; `dp0s4` routed | `br0 DOWN 10.98.0.1/24` | `if:dp0s3`, `if:dp0s4` (`not_needed`) -- no `br0`, no `lo` |
| `dp0s4` moved into `br0` as its member; `br0` `UP` with its address | `br0 UP 10.98.0.1/24` | `if:dp0s3` only -- no `br0`; `dp0s4` gone |

`br0` is absent when it is down and when it is up with a live member, so its absence is not the
down state. `dp0s4` leaves the class once it is a bridge member, which fits the rule (it is no
longer an L3 interface). So the class means "L3 interfaces of the three types that can ask the
backend": absence from it does not mean the interface does not exist or is not routed.

**VXLAN, run 2026-09-28 (corrects the earlier "not run" note above).** The first attempt's path,
`set interfaces vxlan vxlan0 ...`, does not exist in this build -- VXLAN is configured under the
`tunnel` interface type instead (`vyatta-interfaces/yang/vyatta-interfaces-tunnel-v1.yang`):
`set interfaces tunnel tun0 encapsulation vxlan`, `vxlan-id`, `local-ip`, `remote-ip`, then an
`address`. Run on the same installed 5.57 product image, throwaway QEMU overlay (the installed
disk itself was never written): `tun0` came up as a real Linux vxlan device (`ip -d link show`:
`vxlan id 100 remote 1.1.1.2 local 1.1.1.1`, `state UP`) with `10.10.10.1/24` assigned. It does not
appear in `dpa object show interface` -- only `if:dp0s3` and `if:dp0s4` are listed, both
`not_needed` -- confirming the code-read rule above for this type too, not just by inference.
**VTI and VRF, run 2026-09-28.** `set interfaces vti vti0 address 172.16.0.1/24` committed with no
error, but no `vti0` link ever appeared (`ip -d link show vti0`: "Device does not exist") -- the
commit's own warning explains why: "Interface vti0 is not referenced in vpn configuration". A VTI
is a real Linux interface only once an IPsec/VPN tunnel binds to it; configuring the address alone
is accepted but inert. This is a different absence from the others in this section -- not "exists
but outside the class," but "does not exist yet" -- so VTI's class membership remains unverified,
not confirmed excluded, and needs an actual IPsec peer to test properly. Separately,
`set routing routing-instance VRF1 instance-type vrf` committed and did create a real link --
`vrfVRF1`, a Linux VRF master device, `UP`, `NOARP,MASTER,LOWER_UP` -- this is what "vrf" means in
the interface-class list, not a per-interface `vrf` leaf. It does not appear in
`dpa object show interface` either (same `if:dp0s3`/`if:dp0s4`-only result), confirming the rule
for this type on real evidence.

**IPIP and L2TPETH, run 2026-09-28.** `set interfaces tunnel tun1 encapsulation ipip` (with
`local-ip`/`remote-ip`/`address`) committed clean and produced a real device on the first try:
`ip -d link show tun1` shows `link/ipip 2.2.2.1 peer 2.2.2.2`, `UP`. It does not appear in
`dpa object show interface` -- same rule, now confirmed for a fourth tunnel encapsulation
(vxlan, ipip share the `tunnel` type). `l2tpeth`, by contrast, behaved like VTI, not like ipip: the
CLI path is `set interfaces l2tpeth lttp0 l2tp-session {local-ip,remote-ip,local-session-id,
remote-session-id,encapsulation,local-udp-port,remote-udp-port}` plus a top-level `address` (the
first attempt used a flatter path and was rejected outright: "is not valid"; the corrected nested
path was accepted). Committing it failed once on its own precondition ("Local address 3.3.3.1 must
exist before adding tunnel" -- l2tpeth requires the local IP to already be configured on some local
interface, unlike ipip/vxlan which accept any local-ip value); adding that address to `lo` and
recommitting reported "Commit succeeded (non-fatal failures detected)" but still never created an
`lttp0` link (`ip -d link show lttp0`: "Device does not exist"), with `l2tp_core`/`l2tp_netlink`
confirmed loaded in `dmesg` and no error in the journal. Read together with the VTI result, this
looks like the same pattern: some tunnel types are Linux devices the moment DANOS validates the
config (vxlan, ipip, gre presumably), others (VTI, l2tpeth) need a live peer or protocol
negotiation to actually instantiate the kernel link, and config-only testing cannot distinguish "in
the interface class" from "the interface never came into being" for that second group -- their DPA
class membership stays genuinely unverified, not confirmed excluded, without a second real (or
netns-simulated) endpoint to peer with.

**Still not run:** macvlan and (non-PPPoE) `ppp` -- neither has a top-level `set interfaces <type>`
CLI path in this build at all (`grep` across every `.yang` in this tree found no `list macvlan` or
`list ppp`); `IFT_MACVLAN` exists in `vyatta-dataplane` only as VRRP's own mac-passthrough
mechanism, created over netlink by VRRP itself rather than by an operator, and PPP only appears as
PPPoE's underlying link type. These two are better described as "not independently configurable,"
not "not run yet." Not compared against zebra; GRE not exercised.

### `accept-lifecycle.sh` across two different versions

The 13 of 13 above adds the ISO the disk was installed from, which is a valid upgrade but not a
version change. With `UPG_ISO` set the script adds a different ISO and reads `vyatta-image-tools`
inside each image it boots. Run on 2026-09-27: the disk installed from the 5.55 product ISO
(`i-danos_2608_20260925T2005`) added the 5.57 product ISO (`i-danos_2608_20260926T0757`) over http.
The added image is registered (`upg1`) and its files are on disk; selected and rebooted, the running
image reports `vyatta-image-tools` **5.57**; selected back to `2608` and rebooted, it reports **5.55**
again. The admin account survives both switches and `dp0s3` keeps its MAC across the three boots.
12 of 12.

The installer that ran was the one on the ISO being added (5.57), so this is the path an operator
takes, not a same-version repeat. **Not covered:** an upgrade that changes the kernel (both images
carry 6.12.107), and cloud-init/no-network in this cross-version run (`SKIP_BOOT_MODES=1`; both passed
on the product image in the same-version run and do not depend on the version).

## Real hardware: 2608 boots, and its data plane forwards, on a physical I210 NIC

Not a defect. Recorded because "real hardware" had been `NOT_APPLICABLE`/`NOT_RUN`
everywhere in this project's own acceptance tables until now, and this closes the first
piece of it: an image built by this pipeline runs on a physical machine and its data
plane forwards real packets over a physical NIC, not virtio.

**Hardware.** A BayTrail-platform box with a 4-port Intel I210 (`net_e1000_igb` PMD),
the same machine used for the [defect 14 real-hardware confirmation](#confirmed-on-real-hardware-2026-09-27)
above. Console over the same real USB-serial adapter, not a QEMU chardev.

**What was on it.** The official 2105 install was fully reinstalled (not upgraded --
see defect 14, which is exactly why an in-place upgrade was not attempted) from
`i-danos_2608_20260927T0704-amd64.hybrid.iso`, the product image built and verified
earlier the same day.

**Verified after boot**, first over the serial console and then over SSH through the
NIC itself once it had an address:

| Check | Result |
|---|---|
| `show version` | `2608`, `Built on: Sun Sep 27 07:04:33 UTC 2026` -- matches the ISO's own build timestamp exactly; `HW UUID` matches the 2105 install this replaced, confirming same physical machine |
| `dpkg-query -W vyatta-dataplane vyatta-image-tools` | `3.14.42`, `5.57` -- the versions this release was built and verified with |
| `systemctl is-active vyatta-dataplane frr configd` | `active active active` |
| `systemctl --failed` | empty |
| `dp0p1s0` (physical port 1, `0000:01:00.0`) | brought up with a static address directly: `u/u`, auto-negotiated `a-1g/a-full` -- no DHCP involved this time, so the deadlock recorded under defect 14's real-hardware section did not recur |
| ping, both directions, host \<-\> router | 0% loss, 0.6-2.0 ms |
| ssh admin@\<router\> | succeeds; `uname -r` reports `6.12.0-trunk-vyatta-amd64` |
| `show interfaces dataplane dp0p1s0` counters | 1/5/15-minute receive and transmit pkts/sec and bits/sec all non-zero, tracking the ping and ssh traffic just sent -- packets actually moved through the DPDK data plane on this NIC, not just link-up |

**All four ports run (2026-09-27), not just the one above.** Repeated the same check --
static address, ping both directions, ssh, `systemctl is-active`, and the interface's own
traffic counters -- on `dp0p2s0`, `dp0p3s0` and `dp0p4s0` in turn, moving the one test cable
between them (the test host has a single wired NIC, so this was sequential, one port
carrying traffic at a time, not four simultaneously):

| Port | Link | Ping | ssh | services | counters |
|---|---|---|---|---|---|
| `dp0p1s0` (`0000:01:00.0`) | `u/u a-1g/a-full` | 0% loss | OK | active/active/active | non-zero |
| `dp0p2s0` | `u/u a-1g/a-full` | 0% loss | OK | active/active/active | non-zero |
| `dp0p3s0` | `u/u a-1g/a-full` | 0% loss | OK | active/active/active | non-zero |
| `dp0p4s0` | `u/u a-1g/a-full` | 0% loss | OK | active/active/active | non-zero |

Identical result on every port: no port-specific driver or negotiation failure. Afterward
each port's address was deleted and then the whole `interfaces dataplane dp0pNs0` node was
deleted for all four -- deleting only the address left the port administratively up
(`u/D` instead of the original `A/D`), so the full delete was needed to actually restore
the machine to its post-install state, confirmed by `show interfaces` reading `A/D` on all
four again.

**Still not covered.** One link partner, gigabit copper, idle-adjacent traffic levels (a
handful of pings and one ssh session per port), and never more than one port carrying
traffic at the same time -- the four were not exercised simultaneously, so this is not
evidence about aggregate throughput or cross-port interference. Not exercised on any port:
multi-queue/RSS, sustained throughput or packet-rate limits, VLAN/bonding across these
physical ports, a link flap or NIC reset, offloads (checksum/TSO), and recovery from a
power loss on this hardware (P2's power-loss work is QEMU-only). `lspci`/`ethtool` are not
present on the product image; NIC and driver identity came from the CLI's own `show
interfaces dataplane <if> physical` (`driver: net_e1000_igb`, `bus-info: 0000:0N:00.0`),
not from raw PCI tooling.

## Real hardware: Secure Boot key enrollment, attempted and blocked

Not a defect in this project's own code; recorded as a real-hardware attempt that hit
firmware limits, plus one genuine tool-behaviour bug found along the way. Same machine as
the two sections above, same installed 5.57 product image, Secure Boot still `disabled` and
the platform still in `Setup Mode` from the factory reset the earlier NIC testing left it in.

**Not a new bug -- the same one this project already found and decided not to fix, now
confirmed on real hardware.** "The MOK enrollment an operator has to do, walked through"
(above) already reproduced this exact symptom in QEMU and recorded it as one of "four
things an operator will hit ... all reproduced, none fixed -- they are properties of
mokutil, shim and this kernel." What real hardware adds is the root cause and independent
confirmation that it is not a QEMU artifact. Extracting the signer of the installed
`grubx64.efi` gave the expected `CN=home:i-danos OBS Project` certificate (valid to
2028-10-29, matching every earlier measurement of this chain). Running `mokutil --import`
against it printed `Already in kernel trusted keyring. Skip` and created no pending request
(`mokutil --list-new` came back empty). Traced to `linux-vyatta/debian/rules`:

```
dh_signobs_getcert debian/certs/obs.pem
cat debian/certs/obs.pem >> debian/certs/vyatta_db.pem || true
```

`vyatta_db.pem` is `CONFIG_SYSTEM_TRUSTED_KEYS` for this kernel, so the OBS signing
certificate is compiled into the kernel's own module-signing trust store on every build that
doesn't set the `noobs` profile -- confirmed present on the running system via `/proc/keys`
(`asymmetri home:i-danos OBS Project: ... X509.rsa ...`), while `mokutil --list-enrolled`
(the actual persistent `MokListRT` shim reads at boot) showed only `Debian Secure Boot CA` --
the OBS certificate was in neither `MokListRT` nor `db`. `mokutil`'s "already trusted" check
conflates two unrelated trust domains: the kernel's own key store for verifying signed
modules, and shim's separate `MokListRT`/`db` used to verify GRUB and the kernel *before*
Linux ever runs. Being in the first tells you nothing about the second. This is the same
bug this project's own `mok-import.sh` already works around in QEMU (its header comment
describes the identical "Already in kernel trusted keyring. Skip" symptom) -- confirmed here
to reproduce on real hardware with the same real kernel package, not a QEMU-specific
interaction. The documented fix applies unchanged: `mokutil --import <cert> --hash-file
<password-hash> --ignore-keyring` does create a real pending request (`mokutil --list-new`
then showed the OBS certificate's subject). This is a property of `mokutil`, shim and this
kernel, not a DANOS defect to patch -- consistent with the earlier QEMU finding's own
verdict. It matters only if this project ever ships operator-facing Secure Boot enrollment
guidance or a wrapper command: nothing that ships today calls `mokutil --import` without
`--ignore-keyring` except this project's own `vm/mok-import.sh`, which already has it
right; a future deployment note or helper would need to as well.

**Writing `db` directly, tried and refused.** With the platform still in Setup Mode,
`efi-updatevar -a -e -c <cert.pem> db` (append, unsigned update, only valid in Setup Mode
per the tool's own `--help`) was attempted so Secure Boot could work without ever touching
MokManager. Blocked twice: first by this environment's own safety check (modifying a live
machine's Secure Boot `db` is treated as security-sensitive and needs the operator's own
hands), then, run by the operator directly at the machine, with `failed to update db :
operation not permitted`. This firmware does not allow an unauthenticated Setup-Mode `db`
append from the OS, whatever the spec permits in principle. Not investigated further: no
independent way to tell whether this is a vendor-firmware restriction, an interaction with
lockdown, or something about `efivarfs` on this box.

**The Secure Boot toggle is not selectable.** In the firmware's own setup screen, "Secure
Boot activation" read `Disabled` and could not be changed -- consistent with `mokutil
--sb-state`'s `Platform is in Setup Mode` (no Platform Key enrolled; several firmwares grey
out the toggle until one exists). No "Restore Factory Keys" / "Key Management" menu was
found by inspection; the search was not exhaustive; this is recorded as "not found," not
as "does not exist."

**MokManager fires independently of the toggle, and does not persist a skipped request
(also confirming the QEMU section's own "the request is consumed even when nothing is
enrolled" note -- there via a mistimed key press, here via never pressing one at all).**
`mokutil --import ... --ignore-keyring` queued a real pending request. Saving and exiting
the firmware's setup screen triggered a reboot, and the blue MokManager screen appeared --
with Secure Boot still reading `Disabled` in the setup screen moments before. shim checks
for a pending `MokNew` regardless of enforcement state; it is not gated on Secure Boot being
administratively on. No key was pressed; the machine continued and reached the login prompt
normally, and the running image was confirmed unchanged (`2608`, same build timestamp,
`5e24fe9c-...` HW UUID). Checked afterward: `mokutil --list-new` was empty. Passing through
MokManager without enrolling does not leave the request queued for a later boot -- it is
consumed by being shown, not by being acted on. That is a real behaviour of this shim
version worth knowing before relying on "it'll still be there next time."

**End state.** Machine left exactly as before the attempt: 5.57 product image, Secure Boot
disabled, Setup Mode, no pending MOK request, temp files removed. Secure Boot itself remains
unverified on this hardware; what is now known is why the standard command didn't queue an
enrollment, that the workaround this project already has for QEMU applies unchanged here,
that this firmware refuses a Setup-Mode `db` write from the OS, and that the enable toggle
was not found to be reachable in the time spent looking.


## Real hardware: forwarding baseline on the J1900 / I211 bench (2026-10-02)

Not a defect. Recorded so that the one number everyone remembers -- "940 Mbit/s" -- is not read
as more than it is. Everything below was measured on the 2608 product image built by
`close-the-loop.sh` (`i-danos_vyatta_20261001T1242`, `vyatta-dataplane` 3.14.44).

**Bench.** Four identical boxes: Celeron J1900 (4 cores, 3.8 GB), four Intel I211 ports each
(`lspci`: 8086:1539 rev 03, `igb`). One USB-serial cable, no switch, one wired NIC on the test
host. Path under test: test host (iperf3 in a container, kernel stack) -> R1 `dp0p1s0` ->
**R1 data plane** -> R1 `dp0p4s0` -> R3 `enp4s0` (iperf3, kernel stack). R3 was booted *live*
and its NICs handed back to the kernel `igb` driver, so neither end is DANOS. That matters: an
iperf3 endpoint that is itself a DANOS router terminates traffic on the punt path, which tops
out far lower (below) and would have been measured instead of the forwarding path.

**What was measured.**

| Test (one direction, p1 -> p4) | Result |
|---|---|
| TCP, 1 stream, both directions | 934 / 941 Mbit/s, 0 retransmits |
| TCP, 4 streams | 941 Mbit/s, 909 retransmits |
| UDP 1470-byte, 500 / 800 / 950 Mbit/s offered | 0% / 0.023% / 0.007% loss |
| UDP 1400-byte, unlimited, 4 streams | 953 Mbit/s, 0% loss (85 kpps) |
| UDP 512-byte, unlimited, 4 streams | 178 kpps delivered of 190 offered, 6.2% loss |
| UDP 128-byte, unlimited, 4 streams | 223 kpps delivered of 308 offered, 27% loss |
| UDP 64-byte, unlimited, 4 streams | 235 kpps delivered of 356 offered, 34% loss |

**What this does and does not establish.**

- The 940 Mbit/s figures are a *large-packet* result. At 1500 bytes a gigabit port needs about
  82 kpps; at 64 bytes it needs 1.488 Mpps. The measured ceiling here is roughly **0.22 Mpps in
  one direction**, about 15% of 64-byte line rate. "Forwards at line rate" is true for
  1400-1500 byte traffic on this hardware and false for small packets.
- Where the small-packet loss happens is measured, not guessed: R1's ingress counters stayed at
  `Input discarded 0` / `Input missed 0` while `dp0p4s0` `Dropped ring` rose by 2,042,202 and
  `Dropped h/w queue` stayed 0. R1 received 9,318,580 packets, transmitted 7,271,238, and
  dropped 2,042,202 at the ring -- the three agree. The data plane has three forwarding cores
  (`vplsh -l -c cpu`: `forwarding_cores: e`) and every port has only RX/TX queue 0, so there is
  no RSS spread; for this direction the receive runs on one core and the transmit on another,
  joined by a ring that fills. **Why** that ring is the limit (core speed, ring size, per-packet
  cost) was not profiled; the table is a result, not a diagnosis.
- The offered rate at 64 bytes (356 kpps) was limited by the test host's iperf3, so this is the
  behaviour at that injection rate, not proof that 0.22 Mpps is an absolute maximum.
- The cross-check that rules out the endpoint: R1 `dp0p1s0` in-packets and `dp0p4s0`
  out-packets differ by 50 over 3.59 million in the large-packet run (discards 0, no new
  output drops).

**The punt path is a different, much lower number, and is easy to measure by accident.**
Traffic addressed *to* a DANOS box (an iperf3 server on R1 or R2, or an ssh session) is
punted to the kernel. Measured: TCP 311 Mbit/s into R1, 573 Mbit/s out of it, UDP 900M offered
-> 458 Mbit/s received. Forwarding through R1 to a DANOS endpoint gave 252 / 549 Mbit/s TCP and
328 Mbit/s UDP, with R1's own counters showing no loss -- the endpoint was the bottleneck. A
benchmark whose far end is a DANOS router measures the far end.

**Shaping.** A 500 Mbit/s `policy qos` shaper on the egress port (`dp0p4s0`):
UDP 300M and 450M offered, 0% loss; 600M and 950M offered, held to about 475 Mbit/s of iperf3
payload (about 500 Mbit/s on the wire); TCP 468 Mbit/s. `qos-if:dp0p4s0` appeared as `full`,
backend `sw-dataplane`; after removal it was absent while the class still reported
`enumerable: true`. The first TCP run after removing the policy reached only 541 Mbit/s, and
four runs after a 20-second wait reached 940-941 Mbit/s with no new `Dropped ring`: a transient
of roughly ten seconds, not a residue. Changing a policy under load briefly costs throughput.
The hardware (FAL) QoS path was not exercised; only the software one.

**Both directions at once (same path, same day).** iperf3 `--bidir`, one stream each way:
TCP 935 / 939 Mbit/s simultaneously, 0 retransmits (about 1.87 Gbit/s through R1 in total).
UDP 1400-byte unlimited: 950 and 805 Mbit/s delivered, 0.31% / 0.2% loss. Small packets are
where the picture changes and where it must be read carefully:

| UDP unlimited, both ways | p1 -> p4 delivered (of sent) | p4 -> p1 delivered (of sent) |
|---|---|---|
| 512 B | 342 Mbit/s (49%) | 312 Mbit/s (99.9%) |
| 64 B | 57 Mbit/s (56%) | 34.5 Mbit/s (100%) |

The large p1 -> p4 loss is **not** attributable to R1: over this run R1 received 4,562,875
packets on `dp0p1s0` and transmitted 4,534,913 on `dp0p4s0` (99.4%), with only 27,869 output
drops, yet the receiving iperf3 on R3 saw about 1.7 million fewer datagrams than R1 handed to
the wire. The shortfall is downstream of R1 -- R3's NIC/kernel receive path or its iperf3
process, on a J1900 that is also sending in the other direction. The p4 -> p1 direction was
offered only 67 kpps at 64 bytes because R3 could not send faster, so it never stressed R1.
The bidirectional small-packet figures are therefore a **lower bound** on R1, limited by the
endpoint; they do not establish R1's two-way packet rate, and the 0.22 Mpps one-way figure above
(where R1's ring drops matched the receiver's loss to within 6%) stands as the only measured
data-plane ceiling. Measuring R1's two-way limit needs an endpoint faster than a J1900 or
several endpoints.

**Corrections to what the earlier sections of this document say.**

- *NIC model.* The sections above name an I210. `lspci` on the four boxes reports **I211**
  (8086:1539). The `net_e1000_igb` PMD serves both, which is probably how the I210 came to be
  recorded, but it is unknown whether the earlier box was a different one. An I211 port has at
  most **two** queues; any multi-queue or RSS statement must use that, not I210's figure.
- *Machine identity.* "`HW UUID` matches the 2105 install" was used above to show it was the same
  physical machine. Two of the four boxes here report the **same** DMI `product_uuid`
  (`5e24fe9c-c8d0-45bd-a79f-54ea5fbd3d97`), so on this batch that UUID is a factory default and
  identifies nothing. The earlier claim is unproven, not disproven.
- *The product image's login is a sandbox.* `admin` (level `admin`) has no `sudo`, `systemctl`,
  `ip` or `vplsh`, and `systemctl is-active` there answers "Host is down" for a healthy box.
  `set system login user <name> level superuser` plus a **fresh login** is what gives them;
  this was already recorded (defect 14's notes) and was rediscovered here the slow way.
  `show platform dataplane objects | grep qos` works inside the sandbox; `vplsh` does not.

**Not covered.** Simultaneous multi-port load and both directions at once; any run with more
than one queue per port (I211 caps at two); IMIX or mixed-size traffic; link flap or NIC reset
under load; IOMMU/VFIO and Secure Boot on this hardware -- **the J1900 has no VT-d**
(`/sys/kernel/iommu_groups` is empty, cmdline `iommu=pt`), so the `vplane-uio` IOMMU gate
(defect 19) cannot be exercised on any of these boxes and needs a different machine.

**Method note for the next person.** To use a DANOS box as a plain Linux host (live image): the
data plane rebinds NICs to `uio_pci_generic` and `/lib/udev/rules.d/20-vyatta-net-dataplane.rules`
-> `vyatta-udev.sh` -> `/lib/vplane/vplane-uio` re-takes any NIC 0.25 s after it is given back
to `igb` (symptom: `igb ... removed PHC on enpNs0`, PCI device with no driver). Stop
`vyatta-dataplane` and `vplane-controller.{socket,service}`, mask that rule with an empty file
of the same name in `/etc/udev/rules.d` plus `udevadm control --reload`, then unbind from
`uio_pci_generic` and bind `igb`. `dp0pNs0` left behind is a virtual device, not the NIC.


## Real hardware: 2608 -> 2608 upgrade and rollback via `add system image` (2026-10-02)

Not a defect. This is the first time the product's own upgrade path ran on physical hardware, and
the first hardware confirmation of the defect 14 fix. Bench as in the forwarding section above:
R1, a J1900 box with four I211 ports, installed from `i-danos_vyatta_20261001T1242`
(`vyatta-image-tools` 5.57, `vyatta-dataplane` 3.14.44), console over the USB-serial adapter.

**What was done.** A marker was written to the saved configuration
(`description upg-marker-before` on `dp0p4s0`). The *same* ISO was served over plain HTTP from the
test host and added with `add system image http://.../i-danos_vyatta_20261001T1242-amd64.hybrid.iso`,
named `2608b`. Rebooted into it, checked, changed the marker to `upg-marker-after-2608b`, saved,
set the default boot back with `set system image default-boot 2608`, rebooted again, checked, and
deleted `2608b`.

| Step | Result |
|---|---|
| ISO download | 605 MB in 23 s (about 26 MB/s) |
| `Checking MD5 checksums of files on the ISO image...` | **OK** -- the check that failed on every 2608 ISO before 5.52 (defect 14) passes on hardware from 5.57 |
| Installer copy (squashfs, kernel+initrd, flush, config, SSH host keys, machine-id) | `Done.`, no error |
| `show system image` afterwards | `2608 (running image)`, `2608b (default boot)` -- the new image becomes the default boot |
| Reboot into `2608b` | reachable again 118 s after the reboot command; `BOOT_IMAGE=/boot/2608b/vmlinuz`; `vyatta-dataplane`, `frr`, `configd` active; all four links `u/u a-1g/a-full`; `dpa object show qos-if` returns `enumerable: true`; saved config carried over (marker, `set service ssh`, `level superuser`) |
| `set system image default-boot 2608` + reboot | back on `/boot/2608/vmlinuz` after 116 s, services active, links up |
| Config after rollback | the **pre-upgrade** configuration: `upg-marker-before` present, `upg-marker-after-2608b` absent |
| `delete system image 2608b` | removed after a Yes/No confirmation; only `2608` remains |

**What this does and does not show.**

- Upgrade, reboot into the new image, rollback by default-boot, and removal all work on this
  hardware, and a 5.57 system can take a new 2608 image through `add system image`.
- **Configuration is per image.** Changes made after the upgrade stay in the new image and do not
  come back on rollback. That is the right behaviour for a rollback, and it also means a rollback
  silently discards everything configured since the upgrade. It is worth stating in operator
  documentation; it is not a bug.
- The image added was a *rebuild of the same version*, so this proves the mechanics, not that a
  change between two real releases migrates cleanly (schema changes, renamed configuration nodes).
  No cross-release configuration migration was exercised here.
- **Still not done: anything from 2105.** `add system image` run on an installed 2105 still fails
  its own MD5 check on a 2608 ISO, as defect 14 records, so the route off 2105 remains a fresh
  install plus configuration carry-over. That carry-over (which 2105 configuration loads on 2608,
  which does not) has not been tested; it needs a 2105 box, which has not been built on this bench
  yet.
- Boot-time behaviour on the console: the serial line shows the login prompt but this image's
  kernel command line has only `console=tty0`, so the boot loader menu and kernel messages are not
  on the serial port. Choosing a non-default boot entry needs the screen and keyboard, not the
  serial adapter.

**Method trap for anyone scripting the prompts over serial.** Writing `command\r\n` sends *two*
line terminators: `\r` runs the command and the stray `\n` is consumed by the first prompt as an
empty answer. Here that accepted the default image name (`2608`, which collides with the running
image) and, on the next prompt, the SSH-key default -- without any prompt having been answered on
purpose. Send `\r` only. The installer did refuse the collision (`An image named 2608 is already
installed ... Do you want to replace it (Yes/No)? [No]`), and answering No exited cleanly with the
image list unchanged. Also: the reboot confirmation prompt ends `[No] ` with no colon, so a
prompt matcher that expects `: ` never fires.


## Real hardware: carrying a 2105 configuration onto 2608 (2026-10-02)

Not a defect. First test of the path an existing 2105 user actually has, since `add system image`
cannot cross from 2105 (defect 14): configure on 2105, bring the configuration to a 2608 system.
R4 was installed from the official 2105 ISO (`DANOS:Shipping:2105:20210611`, Debian 10, kernel 5.4);
R2 runs the 2608 image from the sections above.

**The 2105 side.** Nine groups were committed on R4 as `admin`/level `admin`, none refused: a second
user, time zone, ssh; interface addresses (including a VLAN `vif` and a loopback); static routes (one
blackhole); a firewall ruleset applied inbound; source NAT masquerade; a 500 Mbit/s QoS shaper applied
to an interface; OSPF; BGP with a neighbour and a network statement; an SNMP community. 405 lines of
`config.boot`, most of it the default access-control rules.

**Finding 1: an `admin`-level 2105 user cannot export a configuration that contains its secrets.**
`show configuration | no-more` and the file written by `save /home/admin/mig2105.boot` both contain
`encrypted-password "********"` for both users and `community "********"` -- three masked values in
the saved file itself, not only on screen. `/config/config.boot` is not visible from that account at
all (it is a sandbox: no `/config`, no `sudo`). A backup taken this way restores a configuration whose
credentials are literally asterisks. Only the masked form was observed here; getting the real file
needs a `superuser` login, which was not done on R4. The three values were replaced by known ones
(`plaintext-password`) before loading, so **credential carry-over is untested**.

**Finding 2: the structure carries over cleanly.** The 405-line file loaded into R2 with
`load /home/admin/r4.boot` and **no warnings** at all (an earlier attempt printed
`Configuration path: [admin@node:~$] is not valid`, which was stray terminal text of mine at the end
of the captured file, not the configuration). `compare` showed the expected additions. Committed with
`commit-confirm 5`, with three lines added to keep R2's own reachability, the running system showed:

| Feature | On 2608 after the load |
|---|---|
| Interface addresses, multiple addresses on one port, `vif`, loopback | present and up |
| QoS shaper | `qos-if:dp0p2s0` appears as `full`, backend `sw-dataplane` |
| Firewall `FW-IN` inbound | `show firewall`: "Active on (dp0p2s0, in)"; the test host's ping to R2 stopped working and ssh did not, exactly as the ruleset says |
| Source NAT rule 100 | present in `show nat source rules` |
| Static routes, OSPF, BGP, SNMP | accepted and present in the committed configuration |
| Hostname | changed to the 2105 one |

**Not verified:** the *runtime* state of BGP, OSPF and SNMP (no `show` command for them exists in the
2608 operational tree used here, and `vtysh` is not reachable from the sandbox), and whether the static
routes were installed. "Accepted by the schema" is what was shown, not "running".

**Finding 3: `load` replaces the whole configuration.** After the load R2's own `admin ... level
superuser` was gone, because the 2105 file said `level admin`; the prompt changed to `admin@R4-2105`
and the account fell back into the sandbox. Anyone migrating by loading a 2105 file loses whatever the
target had configured for management, which is why a `commit-confirm` was used here.

**Finding 4: `commit-confirm 5` rolled back by itself.** Without confirming, R2 was back on its own
configuration (hostname `R2`, `level superuser`, no firewall or QoS, addresses restored) after about
five minutes -- and answered ICMP again because the firewall was gone. A safety net worth using for any
migration.

**One observation not explained.** In the object view the new VLAN sub-interface was listed as
`interface  no_support  sw-dataplane  if:dp0p3s0.100`, while the physical ports were `not_needed`.
Whether `no_support` for a VLAN sub-interface on the software backend is intended, or a mapping fault
in the interface walker, was not looked into.

**Not covered.** A real fresh install of 2608 on R4 with the configuration restored at first boot (the
load was done on an already-running 2608 box); `add system image` from 2105 onto 2608 (known to fail,
defect 14, not rerun on this hardware); the credentials in Finding 1; protocol runtime state; any
2105 feature outside the nine groups above (DHCP, VPN, VRRP, bridging, VRF, zone firewall).


## Real hardware: `add system image` from 2105 onto a current 2608 ISO, rechecked (2026-10-02)

Not a defect report yet; a finding that changes what defect 14 says. Run on R4 (official 2105,
`DANOS:Shipping:2105:20210611`), ISO `i-danos_vyatta_20261001T1242` served over HTTP from the test
host through R1 (so the download itself crossed a data plane).

**The checksum no longer fails.** `Checking MD5 checksums of files on the ISO image...OK.` Defect 14
and the 2026-09-27 hardware run both record that 2105 rejects every 2608 ISO on `.disk/mkisofs`.
This ISO's `md5sum.txt` (308 lines) has no `.disk/mkisofs` entry at all, as the official 2105 ISO's
does not -- so for ISOs built with this fix the stale line is gone *at the source*, and the old
checking function in an installed 2105 (or a 5.51 system) has nothing to trip on. The "fix does not
reach the systems that need it" concern in defect 14 does not apply to this build. Which change made
the difference was not traced.

**It fails later, somewhere else.** The installer proceeded through naming, saving the configuration
and SSH keys, `Copying squashfs image...`, `Copying kernel and initrd images...`,
`Flushing the new image to disk...`, then:

```
Error trying to mount a partition/directory.
ERROR: Failed to mount live rootfs.
```

The image list afterwards still held only `2105.06111158`; nothing half-installed was left behind.

**Cause, from the installer's own log** (`/tmp/install-*.log`, readable only after giving the account
`level superuser`):

```
mount /dev/sda2 /tmp/vyatta-install-image.../rootfs/lib/live/mount/persistence/sda2
mount: /run/live/persistence/sda2: /dev/sda2 already mounted on /run/live/persistence/sda2.
```

The installer mounts the persistence partition *inside* the new image's root tree at
`.../rootfs/lib/live/mount/persistence/sda2`. In the 2608 image `/usr/lib/live/mount` is an
**absolute symlink to `/run/live`** (`/lib` is `usr/lib`), checked directly in
`live/filesystem.squashfs`. Resolved by the running system rather than inside the new tree, that path
is the host's own `/run/live/persistence/sda2`, where the same partition is already mounted, so the
mount is refused. The 2105 image has `/lib/live/mount` as a real directory, which is why the same
code worked for 2105 images.

**Where the symlink comes from.** It is deliberate: `usr/lib/live/README.danos-mount-compat`, shipped in
the image, explains that live-boot dropped the historical `/lib/live/mount` path after buster while
live-config still reads `/lib/live/mount/medium`, so without the link the ISO's `config.conf`,
`user-setup.conf` and friends are silently ignored, no login account is created and the console shows a
login prompt instead of a shell. The link fixes that, and it is also what stops the 2105 installer.

**Two things this does not say.** It does not say the link is the only obstacle: the run stopped at
this mount, and nothing after it was exercised. And "a relative link would fix it" is an inference
from the log, not tested -- it would put the mount target inside the new tree, but the directory it
needs would have to exist there and live-config would have to be rechecked. The 5.57 installer on a
2608 system takes the same ISO through (the 2608 -> 2608 section above), so the problem is specific
to the 2105-era installer's path handling.

**What it leaves open (owner's call).** A 2105 user still cannot move to 2608 with `add system image`,
now for a different reason than defect 14 states. Options: leave it and document fresh install plus
configuration carry-over (see the previous section); or change how the compat link is made and test
the 2105 route again, with a live-config regression check because that link exists to keep the console
working.

**Decision (2026-10-02, project owner): 2105 -> 2608 upgrade work is stopped.** The compat link was
not changed and the relative-link idea was not tried. The supported route off 2105 remains a fresh
install plus configuration carry-over, with the limits recorded in the section before this one
(structure loads cleanly; secrets cannot be exported from an `admin`-level 2105 account;
BGP/OSPF runtime state not verified). Reopen only if the owner asks.


## Real hardware: OSPF and BGP between two J1900 routers, and an intermittent failover hole (2026-10-02)

Not yet a filed defect: an observed, partly diagnosed behaviour, recorded with what was and was not
established. R1 and R2 (2608, `vyatta-dataplane` 3.14.44, FRR 10.3) joined by two links,
`dp0p2s0` (192.168.72.0/24) and `dp0p3s0` (192.168.73.0/24), loopbacks 10.255.0.1/32 and 10.255.0.2/32.

**Protocols come up.** OSPF area 0 on both links and the loopbacks: two `Full` adjacencies, and each
loopback reachable over both links as an equal-cost pair. eBGP (AS 65001 / 65002) over the `dp0p2s0`
addresses: Established, loopbacks exchanged; eBGP (distance 20) wins over OSPF (110), so the best path
to the peer's loopback is the single `dp0p2s0` path and OSPF's pair is the backup. This is the first
check of *running* BGP/OSPF state on this hardware; the earlier configuration-migration section only
showed that the configuration was accepted.

Three things in the 2608 configuration that cost time and are not bugs, but are not obvious:
- A neighbour is not active until `neighbor <ip> address-family ipv4-unicast` is set; `remote-as` alone
  leaves `show bgp summary` saying `No BGP neighbors found`.
- eBGP then shows `(Policy)` and exchanges nothing until a policy exists or
  `protocols bgp <as> parameters ebgp-requires-policy disabled` is set (RFC 8212; default `enabled`).
  `set policy route-map ...` was rejected as an invalid path in this configuration tree on these boxes
  (`Configuration path: policy [route-map] is not valid`); the correct path was not found.
- A `network` statement for a static *blackhole* prefix appeared in the local BGP table but was not
  received by the peer, while the connected loopback prefix was. Not diagnosed.

**The failover test.** Failure was injected with `vtysh -c 'interface dp0p2s0' -c 'shutdown'` on one
router -- an administrative down of the kernel interface, **not a cable pull** (see the last
paragraph). Expected: BGP drops, the route to the peer loopback falls back to OSPF over `dp0p3s0`,
traffic continues.

**What happened, in order of discovery.** A continuous ping (20 packets/s, loopback to loopback) lost
14.85 s in one block, essentially the whole 15 s the link was down. FRR on both routers had already
moved to `dp0p3s0` within about two seconds (BGP `Active`, OSPF best path over p3), yet the ping
failed: on the *other* router the **kernel** route still pointed at the dead `dp0p2s0`. Polling that
kernel next hop afterwards, 15 timed trials in total:

| Trials | Kernel next hop moved to `dp0p3s0` |
|---|---|
| 12 of 15 | 0.2 - 1.3 s on both routers |
| 1 | 30.7 s |
| 1 | still not after 120 s (the failing router itself) |
| 1 | not after 15 s (caught for diagnosis, then restored) |

So 3 of 15 timed trials left a hole of at least 15 s, one of at least 120 s. It was intermittent and
not tied to anything controlled for: neither letting the BGP session age 90 s nor the order of the
failing router changed it reliably.

**One stuck instance, caught at +15 s on R2:**
- `ip route show 10.255.0.1/32` returned **nothing** -- not a stale route, no route at all.
- `vtysh show ip route 10.255.0.1/32`: OSPF, best, via `192.168.73.2 dp0p3s0`, and via
  `192.168.72.2 dp0p2s0 inactive`, entries flagged `r` (rejected, not installed).
- zebra log, same second:
  ```
  netlink-dp error: Network is down, type=RTM_NEWNEXTHOP   Extended Error: Nexthop device is not up
  netlink-dp error: Invalid argument, type=RTM_NEWNEXTHOP  Extended Error: Invalid nexthop id
  netlink-dp error: Invalid argument, type=RTM_NEWROUTE    Extended Error: Nexthop id does not exist
  Failed to install Nexthop (80[192.168...
  ```
zebra programs the kernel through nexthop objects. The equal-cost OSPF route includes a next hop on the
interface that was just taken down; the kernel refuses that nexthop object, the next hop group and the
route that references it follow, and the previous route has already been removed. The kernel is left
without a route until zebra retries, which is consistent with the 15 s, 30 s and 120 s+ holes seen.

**What this does not establish.**
- Whether it happens on a **real link loss**. An admin-down makes the kernel say "Nexthop device is
  not up". A pulled cable normally leaves the interface administratively up with no carrier, which the
  kernel can treat differently. The honest next test is a physical cable pull, not repeated here.
- Whether it is upstream FRR behaviour or something DANOS adds. Not compared against another build.
- Anything about the data plane's own forwarding table. Every observation above is the kernel's and
  FRR's. The data plane's route objects for these prefixes were `no_support` on the `sw-dataplane`
  backend and carry no next hop, so they could not show whether the data plane agreed.
- A cause for the *intermittency*: why one in five injections hit the refusal and the rest did not.

Nothing was changed. The owner's 2026-10-01 decision covers route repair and reconciliation code; it does not cover this finding, so a fix here is undecided, not forbidden. It was not attempted because it needs a design choice and a read of the data plane's kernel-interface code first. No workaround was attempted or tested.
Test configuration (OSPF, BGP, loopbacks, static blackholes) was removed from both routers afterwards.


**Update: the same test with a real cable pull (2026-10-03).** The admin-down injection above is not a
cable pull, so the test was repeated physically: OSPF area 0 over both links, eBGP over `dp0p2s0`
(BGP is the best path, OSPF over `dp0p3s0` the backup), a 10 Hz ping from R1's loopback to R2's
loopback, and a monitor sampling each router's kernel next hop to the peer loopback every 0.2 s. The
`dp0p2s0` cable was pulled four times (pulled for 33 s, 41 s, 64 s, 64 s on R2's own log, then
re-inserted and the BGP session allowed to re-establish).

| Pull | Link-down logged by both routers' data plane | R1 kernel next hop moved to p3 | R2 kernel next hop moved to p3 | Ping loss (continuous) |
|---|---|---|---|---|
| 1 | yes, same instant | under 1 s | 33.2 s | 30.1 s |
| 2 | yes | under 1 s | 26.3 s | 23.9 s |
| 3 | yes | under 1 s | 26.7 s | 24.2 s |
| 4 | yes | under 1 s | 8.3 s | 7.9 s |

- **The link event is symmetric; the reaction is not.** Both data planes logged `dp0p2s0 Link down` at the
  same moment (the spacing between pulls matches to within 0.1 s on both logs). R1 re-pointed to p3 at
  once. R2 took 8 to 33 s. The ping that failed was R1 -> R2: the request left R1 correctly at once; the
  reply was routed by R2, which was still pointing at the dead port. Loss ended when R2's route moved.
- **This is a failover of 8 to 30 seconds, not sub-second**, in the case where two routers share two
  links and one is pulled. It matches neither the BGP hold time (180 s) nor the OSPF dead interval (40 s)
  at a single value, so it is not simply one of those timers expiring.
- **It is R2 every time.** All three stuck instances in the admin-down runs above were also R2 (30.7 s,
  more than 120 s, more than 15 s); R1 converged within 1.3 s in every timed trial of both kinds.
  Whether R2 differs in a way that matters (it has a different configuration history: it took the
  2105 `load` and the `commit-confirm` rollback, R1 did not) was not established.
- **The mechanism seen with admin-down was absent.** zebra logged no `netlink-dp error` and no
  `Failed to install Nexthop` on either router across the four pulls (four zebra lines each in total).
  So the "kernel refuses a nexthop on a down device" chain is specific to the admin-down injection
  and does not explain these delays.
- **The kernel interface never shows the loss.** The monitor read `carrier=1` for `dp0p2s0` on both
  routers throughout. The data plane's own `MOD link` records show the flags change from
  `<UP,BROADCAST,RUNNING,MULTICAST,LOWER_UP>` to `<UP,BROADCAST,MULTICAST,LOWER_UP>`: only RUNNING is
  dropped, LOWER_UP stays. Anything reading carrier rather than the RUNNING flag will not see a pull.
- BGP dropped four times and re-established after each re-insertion on both routers.

**Not established.** Why R2 is slower and why the delay varies between 8 and 33 s. No daemon debug
output was collected during a pull (zebra, bgpd and ospfd were at default logging), so the next step
is an instrumented pull, not more of these. The path in R2's kernel during the delay (BGP or OSPF
route) was not recorded. Whether the same happens between two routers from different builds or on
non-J1900 hardware was not tested. Nothing was changed. The owner's 2026-10-01 decision covers route repair and reconciliation code; it does not cover this finding, so a fix here is undecided, not forbidden. It was not attempted because it needs a design choice and a read of the data plane's kernel-interface code first.


**Update: instrumented cable pull, and the cause of the 8-33 s delay (2026-10-03).** The pull test was
repeated with zebra, bgpd and ospfd debug logging on both routers (`log file ... debugging`, runtime
only, removed afterwards) and a monitor that also records the source protocol of the kernel route.
Two pulls of the same cable; the failing side is again R2.

**Everything above the kernel reacted at once.** At the moment of the first pull R2's log shows, in
the same second: `Intf dp0p2s0 has gone DOWN`, `Zebra: Interface[dp0p2s0] state change to down`,
OSPF `Full (KillNbr)` and `SPF: calculation timer delay = 500 msec`, and BGP
`Established->Clearing`; BGP then withdrew `10.255.0.1/32` and zebra replaced the BGP route by the
OSPF one (`Redist del: ... (bgp), new re ... (ospf)`) and sent `RTM_NEWROUTE 10.255.0.1/32` to the
kernel twice within 1 s. No netlink error. After 18:12:58 zebra logged **nothing further** about that
prefix until the end of the window. The kernel next hop nevertheless stayed on the dead port, and the
moment it moved was not a zebra action (the only entries at that moment are BGP connect-retry timers).

**It moved when the neighbour entry for the dead next hop reached FAILED.** R2 zebra's record of the
kernel's neighbour state for 192.168.72.2 (`0x4` STALE, `0x10` PROBE, `0x20` FAILED), against the
monitor's kernel route:

| | Interface DOWN | STALE | PROBE | FAILED | Kernel next hop -> p3 |
|---|---|---|---|---|---|
| Pull 1 | 18:12:57 | 18:13:17 | 18:13:22 | 18:13:25 | 18:13:24 (+27.3 s) |
| Pull 2 | 18:15:43 | 18:15:42 | 18:15:47 | 18:15:50 | 18:15:50 (+7.4 s) |

This fits the neighbour timers on these boxes (`base_reachable_time_ms` 30000, so an entry stays
REACHABLE for 15-45 s, then STALE; `delay_first_probe_time` 5 s; `ucast_solicit` 3 x `retrans_time_ms`
1000 ms): in pull 2 the entry was already STALE, leaving 5 + 3 = 8 s; in pull 1 about 20 s of
REACHABLE remained, giving 27 s. It also explains why the delay varied between 8 s and 33 s over
the six pulls and why it was not tied to any one protocol timer. The upper bound from these timers is
about 45 + 8 = 53 s (superseded: a later run exceeded this, see the correction at the end of this section).

**Why the next hop is only dropped then is not established.** The kernel reports
`fib_multipath_use_neigh=0` and `ignore_routes_with_linkdown=0`, both defaults, so a neighbour-state
dependency is not what those settings would predict; the correlation above is observed in two pulls
(and is consistent with the earlier four), not derived from kernel code. What was seen of the route:
after the BGP route went, the kernel route was `proto ospf` and zebra encoded it with a nexthop group
id (337, then 350 in pull 2); an earlier run showed the kernel route as an equal-cost group holding
both `192.168.72.2 dev dp0p2s0` and `192.168.73.2 dev dp0p3s0`. That group content during these pulls
was not captured.

**One condition that lets the dead next hop stay usable.** The kernel interface never loses its link
as far as the kernel is concerned: `dp0p2s0` stays `state UP`, `LOWER_UP`, `carrier 1` throughout
(only the RUNNING flag disappears in the data plane's link-change message, and zebra reacts to that).
With carrier up, the kernel has no link-down signal to mark the next hop dead, so a dead path can
only be recognised when neighbour resolution fails. Whether the missing carrier propagation is the
intended design of the data plane's kernel interfaces, an omission, or specific to this build was not
investigated.

**Practical reading.** With two parallel links between two DANOS routers and loopback-to-loopback
traffic, a pulled cable costs between about 8 s and about 53 s (later measured above 68 s; see the correction at the end of this section) of one-way loss of *router-originated* traffic, depending on where
the neighbour entry is in its aging cycle, even though OSPF and BGP both reconverge within a second.
It is a property of how the data plane's kernel interface reports link loss and of default neighbour
timers, not of OSPF or BGP convergence, and the earlier admin-down finding (nexthop install refused) is a
different, injection-specific effect. Nothing was changed. The owner's 2026-10-01 decision covers route repair and reconciliation code; it does not cover this finding, so a fix here is undecided, not forbidden. It was not attempted because it needs a design choice and a read of the data plane's kernel-interface code first.
Options a person could evaluate, none applied or tested here: BFD between the routers (detects loss
without relying on neighbour state), shorter neighbour timers, propagating link loss to the kernel
carrier, or avoiding equal-cost groups that contain a path through a port whose link is down.


## Real hardware: `qos-vlan` on VLAN sub-interfaces (2026-10-03)

Not a defect. First check of the `qos-if` / `qos-vlan` walkers (`vyatta-dataplane` 3.14.44) against a
VLAN sub-interface on physical hardware: R1 (J1900, I211, 2608 image `20261001T1242`), `dp0p4s0`.

**Configuration.** A shaper profile at 200 Mbit/s, a `trunk` policy on the port, and one policy each on
`vif 10` and `vif 20` (each `vif` with an address). No error on commit.

**Results.** `dpa object show qos-vlan` returned `qos-vlan:dp0p4s0/10` and `qos-vlan:dp0p4s0/20`, state
`full`, backend `sw-dataplane`; `qos-if` returned `qos-if:dp0p4s0`, `full`. Removing the policy on
`vif 20` alone left only `/10`; removing `vif 10`'s as well left `qos-vlan` with `enumerable: true` and
no objects while `qos-if` stayed; removing the port policy emptied both. So the class distinguishes
"enumerable, nothing configured" from the earlier "no walker", and an object appears and disappears
with exactly the policy it describes.

**Limits.** Software scheduler state only; the hardware (FAL) path and the `no_support` mapping were not
exercised because these boxes have no hardware QoS backend. No traffic was sent through the VLAN
sub-interfaces, so the per-VLAN shaping itself was not measured. In the object view the sub-interfaces
themselves read `interface  no_support  sw-dataplane` (`if:dp0p4s0.10`, `.20`), while the physical port
reads `not_needed`; the reason was not investigated. The test configuration was removed afterwards.


**Update: the same pull with traffic that goes *through* the data plane, and a correction (2026-10-03).**
Every number above came from traffic the routers originate themselves (a ping sourced from a router's
own loopback), which uses the **kernel** route. A router's job is mostly to forward, and forwarded
traffic uses the **data plane's own table** (fed from zebra), which none of the above observed. This
test measured that.

Topology: test host -> R1 (`dp0p1s0`) -> R1 data plane -> `dp0p2s0` primary / `dp0p3s0` backup -> R2
data plane -> R2 `dp0p4s0` -> R4 (a plain end host, 192.168.75.4). Both directions of the ping cross
both data planes. OSPF over both links, eBGP over `dp0p2s0` (so p2 is primary), prefixes
192.168.71.0/24 and 192.168.75.0/24 advertised. Each router sampled, in one loop, the kernel next
hop (`ip route get`) and the **data plane's** next hop (`vplsh -l -c 'route lookup <addr>'`). A 10 Hz
ping ran from the test host to R4 for 600 s; the `dp0p2s0` cable was pulled twice
(75.7 s and 68.3 s on R1's own log), 6000 pings.

| | Pull 1 | Pull 2 |
|---|---|---|
| **Forwarded ping loss** | **0.8 s** | **0.9 s** |
| R1 data plane next hop -> p3 | within the sample interval of the pull | same |
| R2 data plane next hop -> p3 | about 0.5 s after R1's | same |
| R2 kernel next hop -> p3 | about 2 s | about 2 s |
| **R1 kernel next hop -> p3** | **about 68 s** | **about 54 s** |

- **Forwarded traffic fails over in under a second** here: the data plane tables moved on both routers
  and the end-to-end ping lost 0.8 to 0.9 s. The 8 to 33 s holes found earlier belong to
  *router-originated* traffic and to the kernel table, not to forwarded customer traffic. That
  materially lowers the severity of the earlier finding.
- **The kernel lag is real and was longer this time**, and on the other router than before (R1 here,
  R2 earlier), so it is not tied to one box. Both R1 flips happened before the cable was re-inserted
  (68 s of 75.7 s; 54 s of 68.3 s), so re-insertion did not cause them.
- **Correction.** The earlier update stated an upper bound of about 53 s for the delay, derived from the
  neighbour timers (15-45 s of REACHABLE, then 5 s, then 3 probes). **The 68 s seen here exceeds it**,
  so that bound is not valid as stated; treat "8 s to at least 68 s" as what was observed, with no
  established maximum. The correlation with the neighbour entry reaching FAILED, shown in two pulls
  earlier, was **not re-checked**: this monitor's neighbour column was parsed wrongly (it read the
  last word of `ip neigh show`, which is `zebra`, not the state), so no neighbour state was recorded.
  The correlation therefore rests on two pulls and is not confirmed by this run.
- Four short losses of 0.2 to 0.3 s each occurred 70 to 90 s after the second re-insertion. They were
  not investigated.

**What is exposed.** Traffic the router itself originates or terminates and that depends on the kernel
route for a destination reached over a failed link: multihop or loopback-sourced routing sessions
(for example iBGP between loopbacks), management sessions to the router, syslog, NTP, SNMP traps, DNS
lookups made by the router. None of these was tested against the hole; they are the realistic
exposure, not a measured one. Forwarded traffic is not exposed on this evidence.

**Still not established.** Whether the data plane table stayed correct for longer flows than a 10 Hz
ping (throughput under a pull was not measured), the 0.2 s losses, and anything on non-J1900
hardware. Nothing was changed.


**Update: a third run, with an extra BGP path, did not reproduce the kernel lag (2026-10-04).** The
exposure test (loopback-to-loopback BGP with 3 s / 9 s timers, a router-originated TCP echo, a
100 Mbit/s UDP stream through both data planes, and the corrected monitor) was run with three real
pulls of the `dp0p2s0` cable (80 s out, 100 s back). It was meant to measure what the kernel-route
hole exposes. **There was no hole to measure.**

- **Kernel next hop: 0 of 3 pulls lagged.** In all three, R1's and R2's kernel and data plane next
  hops moved to `dp0p3s0` together (188.6 s, 373.9 s, 562.6 s on the monitor clock), within the sample
  interval (about 1-2 s). The neighbour entry for the dead next hop was still `REACHABLE` when each
  route moved and reached `FAILED` only 36 s later (224 s) in the first pull.
- **So the earlier correlation does not generalise.** Two pulls had shown the route moving when the
  neighbour reached FAILED. Here the route moved first and the neighbour state is irrelevant to it.
  The kernel lag occurred in 8 of 8 earlier pulls (4 + 2 + 2: 8-33 s, 8 s and 27 s, 68 s and 54 s on one
  router) with one eBGP session over the link and OSPF as the backup, and in 0 of 3 here.
- **What changed between the two configurations** (not what caused it): this run added a second,
  loopback-sourced multihop eBGP session between the routers with OSPF advertising the loopbacks, so
  R1 held two BGP paths to 192.168.75.0/24 (the direct one, best, and one recursive via 10.255.0.2); both
  routers had also been rebooted about 15 minutes earlier. In the earlier runs the replacement for the
  failed BGP route was an OSPF equal-cost route whose kernel next-hop group held the dead port as well
  as the live one (seen in an earlier run as `nhid ... nexthop via 192.168.72.2 dev dp0p2s0 ... nexthop via
  192.168.73.2 dev dp0p3s0`). **A hypothesis consistent with all of it:** the hole appears when the
  route left after the failure is an equal-cost group that still contains the dead next hop, and not
  when it is a single next hop. It is a hypothesis: the kernel route was not captured at failover in
  either configuration in the same run, and the recovery trigger is unexplained.
- **Router-originated traffic: nothing observed.** The loopback BGP sessions (3/9 s timers) stayed
  `Established` through all three pulls and the TCP echo connection (router loopback to router loopback,
  one probe every 0.2 s) logged no stall. With no kernel lag in this configuration there was nothing to
  expose; the exposure of the earlier configuration remains unmeasured.
- **Forwarded traffic.** A 100 Mbit/s UDP stream (1200-byte datagrams) from the test host to R4 lost
  **no datagrams in 820 s: 0 of 8,541,655 at the receiver**, across the three pulls. R1's counters show
  the stream really changed path: `dp0p2s0` transmitted 5,778,178 packets and `dp0p3s0` 2,730,264, the
  second matching about 262 s of the stream (the three outages plus the time before BGP returned the route
  to p2). **Unresolved:** the 10 Hz ping over the same path lost 0.8 s at each of the three pulls, while
  the stream, in the same direction as the echo requests, lost nothing, and a physical pull would be
  expected to cost at least the packets in flight. If the ping loss is real forwarding loss it is in the
  reply direction (R4 to the test host), which this stream does not exercise; that was not tested.
- **Ping loss with no pull.** Six further loss windows of 0.2 s to 4.5 s occurred outside the pulls,
  including a 4.5 s one at 92.7 s with nothing disturbed, and the stream lost nothing in any of them. The
  ping target is R4, a DANOS 2105 router terminating 100 Mbit/s of UDP on its punt path; these look like
  the end host's ICMP handling, not forwarding. Not shown directly.

**What is established now:** forwarded traffic through the data planes survives a pulled cable with no
measurable stream loss, in two separate configurations (0.8-0.9 s of ping loss in each pull in both);
whether the kernel route lags depends on something in the configuration. **What is not:** the cause of
that dependence (the hypothesis above), the reply-direction loss, and the exposure of router-originated
traffic in the configuration that does lag. A direct test would run the two configurations on the same
boxes and capture `ip route show`, `ip nexthop` and the data plane's lookup 3 s and 15 s after each pull.


**Update: A/B test, and what the stuck kernel route actually is (2026-10-04).** Same boxes, same
topology, same traffic (forwarded ping and UDP from the test host to R4), `dp0p2s0` pulled by hand.
After each pull a script took, at +3 s, +15 s and +40 s, from both routers: `ip -d route show` for
the transit prefix, `ip nexthop show`, the data plane's own lookup, FRR's RIB entry and the neighbour
entry. Two configurations:

- **A:** one eBGP session over the link; OSPF over both links as the backup. (R2's leftover static route
  for 192.168.71.0/24, which had pre-empted BGP on R2 in the previous run, was removed first.)
- **B:** A plus a loopback-sourced multihop eBGP session (3 s / 9 s timers), so each router holds a second,
  recursive BGP path to the far subnet.

| Config | Pull | R1 kernel route after the pull | R2 kernel route after the pull | Kernel next hop moved |
|---|---|---|---|---|
| A | 1 | `nhid 143 proto ospf`, **group 17/25** (dead p2 and live p3) | `nhid 137 proto ospf`, **group 16/26** (dead p2 and live p3) | R1 at once; **R2 not for the whole 92 s** |
| A | 2 | `nhid 25`, single next hop p3 | `nhid 26`, single next hop p3 | both at once |
| B | 1, 3, 4, 5, 6 | single next hop p3, `proto bgp` at +3, +15, +40 s | same | **5 of 5 at once** |

(B's second pull was a 3-second contact bounce and is not counted.)

- **The stuck state is now observed, not inferred.** In pull A1 the kernel held an equal-cost group that
  still contained the dead port's next hop, for the whole outage, on **both** routers. FRR's own RIB
  at the same moment marked that next hop `inactive` and listed only p3 as active, and the **data
  plane's lookup returned only p3**. So FRR and the data plane were right and the kernel group was not:
  zebra pointed the kernel route at the pre-existing two-member group object instead of one holding
  only live members.
- **Why only one router looked stuck.** Both routers held the bad group in A1; the kernel picks a member
  by flow hash, so a flow hashed to the live member looked fine (R1's did) and a flow hashed to the dead
  one was blackholed (R2's). That is why "which router is slow" changed between runs, and why a given
  router-originated flow is lost for the whole outage or not at all.
- **It is intermittent inside one configuration.** A1 left the group, A2 installed a single next hop,
  same boxes, same procedure. Earlier lagging pulls (8 of 8, plus the 1 of 2 here) all had the OSPF route
  as the route left after the BGP route went; the 0 of 8 non-lagging pulls with the loopback session
  (3 earlier, 5 now) had a **BGP** route (recursive via the loopback, resolved to a single next hop) take
  over instead, and the OSPF equal-cost route was never the one installed in the kernel.
- **Supported, still not proven:** the hole appears when the route that takes over after the failure is
  an OSPF equal-cost group whose kernel next-hop group keeps the failed interface's member. Evidence is
  the A1 snapshot (observed in the stuck case) and 0 of 8 against about 9 of 10 across the two
  configurations. Not established: why zebra reuses the two-member group in some pulls and not in
  others (likely a race between OSPF's SPF, which waits 500 ms, and the BGP withdrawal, which is
  immediate; not shown), whether FRR upstream does the same, and any fix. The earlier "waits for the
  neighbour to reach FAILED" correlation is withdrawn: with a single next hop installed the neighbour
  state is irrelevant, and in the stuck case it was observed to matter only because the group still
  held the dead member.
- **Exposure, restated.** Only router-originated flows that hash to the dead member are affected, and
  only while the failure lasts; forwarded traffic is unaffected because the data plane's table never held
  the dead next hop in any pull. The router-originated exposure (iBGP over loopbacks, management
  sessions, syslog, NTP, SNMP) was still not measured in the configuration that has the hole.


## Real hardware: how much router-originated traffic the stuck kernel group hits (2026-10-04)

Question left open above: when the kernel route is left as an equal-cost group that still contains the
dead next hop, how much of the traffic a router *originates* is lost, and for how long? Measured with
scripts in `toolkit/vm/` (`hw-link-cycle.py`, `hw-exposure-flows.py`, `hw-exposure-analyze.py`).

**Method.** Configuration A (one eBGP session over the link, OSPF as backup; no loopback BGP path).
`dp0p2s0` was taken down and up on R1 by the router itself (`ip link set`), five cycles of 80 s down and
100 s up, with the router's own epoch time logged at each action. Probes ran throughout: on R1, one 5 pps
ping per (source, destination) pair for 9 sources (three real addresses and six extra loopbacks) times
two destinations (`192.168.75.2` on R2, `192.168.75.4` on R4); on R2, 9 sources to the test host; and
six TCP echo connections from R1 to R4 (one probe every 0.2 s). Kernel multipath hashing here is
`fib_multipath_hash_policy=0`, source and destination **address** only, so the address pair decides the
member, not the ports. The failed link's own address is removed by zebra on link-down and cannot be a
source, so it was excluded.

**What this method is.** Taking the port down from the router makes the data plane bring it
administratively down, so the NIC's link really drops and the **peer** sees a genuine link loss (the
same `Link down` / `NO-CARRIER` as a pulled cable; an 8 s trial showed R2 holding the stuck group,
`nhid 248` with both `dp0p2s0` and `dp0p3s0`). The router doing it sees an admin-down instead, which also
takes its kernel interface down and lets the kernel mark next hops on it dead. **Results on R2 therefore
match a pulled cable; results on R1's own side do not.** In the table below the two sides show identical
loss fractions in every cycle, which says the losses on both sides are one event: R2's stuck group, hit
by R2's own flows and by the replies to R1's flows.

**Per-flow loss inside each 80 s down window** (fraction of probes lost after the first second):

| Cycle | R2's kernel route 3 s after | Flows affected (R1 side / R2 side) | Loss in an affected flow | Implied stuck time |
|---|---|---|---|---|
| 1 | group with dead member | 4 of 18 / 4 of 9 | 41% / 40% | about 32 s |
| 2 | **single next hop** | 0 / 0 | 0% | none |
| 3 | group with dead member | 4 of 18 / 4 of 9 | 79% / 78% | about 62 s |
| 4 | group with dead member | 4 of 18 / 4 of 9 | 35% / 34% | about 27 s |
| 5 | group with dead member | 4 of 18 / 4 of 9 | 23% / 23% | about 18 s |

- **The affected flows were the same every time**: on R1 the sources `10.255.0.1`, `10.255.1.1`,
  `10.255.1.2`, `192.168.71.2` to destination `192.168.75.2`, and **none** of the 9 sources to
  `192.168.75.4`; on R2, 4 of 9 sources (`10.255.0.2`, `10.255.2.4`, `192.168.73.3`, `192.168.75.2`).
  The share of address pairs that hash to the dead member is about half or less (R2: 4 of 9; R1: 4 of
  18 pairs), as two members and a hash predict, and it depends on the destination.
- **The loss is a stuck period, not a permanent blackhole.** Within a cycle every affected flow lost the
  same fraction, and the flows recovered part-way through the window while the kernel route still
  listed the group at +40 s. The stuck time was 18, 27, 32 and 62 s in the four affected cycles (none in
  one). **62 s again exceeds the 53 s the neighbour timers would allow**, so that bound stays withdrawn.
- **Totals on R2** (the pull-faithful side): 16 of 45 flow-cycles were affected (36%); over all flow-cycles
  the share of outage time lost was **15.6%**; one cycle in five saw no loss at all.
- **TCP echo: 0 stalls and 0 resets** in all five cycles for all six connections. **This is not evidence
  that TCP is safe:** all six went to the one destination, `192.168.75.4`, and no address pair to that
  destination hashed to the dead member in any cycle. Exposure for TCP to a destination that does hash to
  it was not measured; those flows would stall for the same 18-62 s.
- **Forwarded traffic** was not part of this run; earlier runs showed it unaffected.

**What this does and does not say.** In this configuration, router-originated traffic is exposed
partially and intermittently: roughly four in nine address pairs to a given destination are blackholed
for about 18-62 s in four of five cycles, and none in the fifth. A router's management sessions,
syslog or NTP would be hit only if their (source, destination) pair hashes to the dead member, which can
be checked from the addresses alone with `ip route get ... from ...` against the group. Not measured:
protocols with real timers (hold times of 90-180 s would survive an 18-62 s stuck period; the 9 s hold
time of the earlier loopback session would not), and the recovery trigger.

**Method caveats.** R1-side flows reflect an admin-down on R1 as well as R2's stuck group, so no
statement about R1's kernel under a cable pull is made from them. The cycle count is five.
After the run the test configuration was removed from R1 and R2; R4 still carries extra static routes
(192.168.72/73/74.0/24 and 10.255.1.0/24 via 192.168.75.2), removed from nothing because R1 no longer
routes to it.


## Root cause of the stuck kernel next-hop group, from zebra's own log and source (2026-10-04)

Question left open above: why does the kernel sometimes keep an equal-cost group that still holds the
dead port's next hop? Answered by reading FRR 10.3-3+deb13u1 (the version on the routers; Debian's patches
are security fixes and do not touch the next-hop group code) and by capturing zebra's debug log
(`debug zebra rib detailed`, `nexthop detail`, `kernel`, `dplane detailed`, `events`) on R2 across 8 failovers
of `dp0p2s0` taken down from R1 (`ip link set`; R2's side is the pull-faithful one). One note on a trap:
the `frr` tree under `danos-sources/` is a 7.6-dev fork and is not what runs; the source used here is the
Debian 10.3 orig tarball.

**Observed (R2, same second, stuck failover, `nhid 473`, `group 16/26`):**

1. `Intf dp0p2s0 has gone DOWN`. The BGP route to 192.168.71.0/24 is withdrawn and zebra selects the OSPF
   route that was already in the RIB, whose next-hop group `473[16/26]` has a member `16`
   (`192.168.72.2` via `dp0p2s0`) and a member `26` (`192.168.73.2` via `dp0p3s0`).
2. Installing it: `zebra_nhg_install_kernel: valid flag set for nh 473[16/26]`, then
   **`valid flag set for nh 16[192.168.72.2 if 10 vrfid 0]`** (the dead port's next hop is marked VALID
   again), then `RTM_NEWNEXTHOP id=16`, `RTM_NEWNEXTHOP id=473`, `RTM_NEWROUTE ... nhg_id is 473`. The
   kernel now holds a group containing the dead member.
3. About 10 ms later ospfd's update arrives with only `192.168.73.2` (zebra creates a new next hop,
   474, for it). `zebra_nhg_rib_compare_old_nhe` compares it with the old group: new active next hops are
   `192.168.73.2`; old are `192.168.72.2` (not ACTIVE) and `192.168.73.2`. Log: `Old is not active going to
   the next one` ... `New and old are same, continuing search` ... **`They are the same, using the old nhg
   entry`**, then `nexthop_active_update: CHANGED: nhe 474 => new_nhe 473[16/26]`. The route stays on the
   two-member group and nothing is pushed to the kernel.
4. ospfd itself is right: `show ip ospf route` in the stuck state lists only `via 192.168.73.2, dp0p3s0`
   and its last SPF ran at the failure. FRR's RIB entry still lists `192.168.72.2 ... inactive`, and the
   data plane's lookup returns only p3. Only the kernel group is wrong.

**Same capture, normal failover (cycle 3, `nhg_id is 26`).** The order is reversed: ospfd's single-next-hop
route reaches zebra *before* `Intf dp0p2s0 has gone DOWN` (line 6 against line 100 of the segment), so the
route is moved to the single next hop 26 first, the old group is released and no dead member is ever
re-validated. The stuck cases (two of two) had `gone DOWN` first (line 8, line 9) and ospfd's update after.
A separate snapshot run (zebra `show nexthop-group rib`, 5 failovers) agrees: the stuck state shows
`ID 16 ... Valid, Installed`, `ID 374 ... Valid, Installed, Depends (16) (26)`; a normal one shows
`ID 16` with no Valid/Installed flags and no group.

**So the intermittency is a race** between the local interface-down event reaching zebra and the OSPF
route update, which the peer's LSA triggers: when the interface event comes first the failure leaves
the old group installed with the dead member; when the OSPF update comes first it does not. Over the runs
here, R2 was stuck in 2 of 5 and 2 of 6 failovers in the two snapshot runs, 2 of 3 in the debug run and
4 of 5 in the exposure run: 10 of 19 in all, with no pattern by cycle order.

**Two defects in 10.3's `zebra_nhg.c` explain steps 2 and 3:**

- `zebra_nhg_check_valid()` should clear the ACTIVE flag on a *singleton* next-hop entry (no depends, only
  dependents) when its interface goes down. Its code tests `depends_count || dependents_count == 0`, while
  its own comment describes the opposite, so a singleton that groups depend on keeps ACTIVE.
  `zebra_nhg_install_kernel()` then calls `zebra_nhg_set_valid_if_active()`, which sets VALID on any singleton
  whose next hop still carries ACTIVE, regardless of the interface state: step 2.
- `zebra_nhg_rib_compare_old_nhe()` treats the old group as equal when its *active* next hops match the
  new route's, ignoring that the kernel group built from it also holds the inactive member: step 3.

**Upstream.** FRR 10.7.1 (Debian pool) changes the first two functions: `zebra_nhg_check_valid()` now tests
`ZEBRA_NHG_IS_SINGLETON(nhe)` (comment and code agree), and `zebra_nhg_set_valid_if_active()` adds
`if (!ifp || !if_is_operative(ifp)) valid = false`, so a singleton on a non-operative interface is no
longer re-validated. `zebra_nhg_rib_compare_old_nhe()` is identical to 10.3. *(Superseded below: this was a reading of a source diff, and testing 10.7.1 showed it does not remove the
symptom.)*

**Not established.** What ends a stuck period after 18-62 s (not captured; the debug segments cover 15 s).
Whether a real cable pull has the same ordering as a down taken from the peer (the debug side is the peer,
so the signal is a real link loss, but the local-event timing was not compared). Any behaviour of 10.7.1 on
this hardware. How this relates to the earlier "loopback BGP path avoids it" observation: with a BGP route
taking over there is no old two-member OSPF group to reuse, consistent with step 3 but not tested.

**Options, none applied or tested** (nothing was changed; the 2026-10-01 decision about repair code does
not cover them): carry a downstream backport of the two 10.7.1 changes into the Debian 10.3 package (the
patch-maintenance cost described in `FRR-ROUTE-REPAIR-DECISION.md` section 8 applies); move to an FRR that
contains them; or avoid the condition in configuration (a BGP path that takes over, or no equal-cost
backup through the failing link).


**Correction: FRR 10.7.1 does not fix it (2026-10-05).** The statement above that fixing step 2 would stop the
dead member being installed was an inference from a source diff. It was tested: FRR 10.7.1-2 was rebuilt
for trixie from Debian's source (Lua disabled, sphinx and `Breaks` adjusted; `libyang3` 3.12.2 and
`libc6` 2.38 on the routers satisfy it), installed on R2 only (R1 stayed on 10.3, so this was also a mixed-version
interop test: OSPF 2 adjacencies Full, eBGP established, DANOS CLI commits accepted, data plane lookups
correct), and R2's failover was cycled 12 times with the same loop as before.

| FRR on R2 | Failovers where the kernel kept the dead member (at +3 s and still at +15 s) |
|---|---|
| 10.3-3+deb13u1 | 10 of 19 over four runs |
| 10.7.1-2 | **8 of 12** |

- **No improvement.** The counts are not statistically distinguishable; if anything 10.7.1 is no better.
- **The step-2 fix does work as far as it goes.** In a debug capture of a stuck 10.7.1 failover the line
  `valid flag set for nh <dead singleton>` that 10.3 printed is absent, and the singleton is not `Valid` in
  `show nexthop-group rib`.
- **It does not matter, because the kernel group is never rewritten.** The route is still installed with
  `nhg_id is 58` (the two-member group), no `RTM_NEWNEXTHOP` for 58 is sent at the failure, and
  `zebra_nhg_rib_compare_old_nhe` again logs `Old is not active going to the next one` and `They are the same,
  using the old nhg entry`. The group is already in the kernel with both members, and keeping the old nhe
  keeps it that way. So the cause that matters is the second one (reusing an old group whose kernel
  members include an inactive one); the first only changed how the dead member got there in 10.3.
- **Consequence for the options above.** Upgrading to 10.7.1, or backporting its two changes to 10.3,
  would not remove the stuck state. The remaining candidates are a change to
  `zebra_nhg_nexthop_compare`/`zebra_nhg_rib_compare_old_nhe` or avoiding the condition in configuration.


## The fix, validated: a small zebra patch, not an upgrade (2026-10-05)

Decision taken by the owner on 2026-10-05: upgrade FRR. Testing showed the upgrade does not fix the stuck
group (above) but a small change does, so the recommendation to the owner is a downstream patch, not a
version change.

**The change** (`toolkit/frr-patches/`, with a README, both patches and the build script): in
`zebra_nhg_nexthop_compare()` an inactive member of the old nexthop group that the new route does not carry
now means "not the same", so zebra uses the new nexthop group instead of reusing the old one that the kernel
still holds with the dead member. The same applies to leftover members at the end of the comparison. The
function differs between versions, so there is one patch for Debian `frr 10.3-3+deb13u1` and one for
upstream 10.7.1.

**Results, R2 on the physical bench, same loop each time** (R1 on 10.3; link taken down from R1; kernel route
read 3 s and 15 s later; "stuck" means the kernel route held the dead port's next hop):

| FRR on R2 | Stuck failovers |
|---|---|
| 10.3-3+deb13u1 (Debian) | 10 of 19 |
| 10.7.1-2 rebuilt for trixie | 8 of 12 |
| 10.7.1-2 + patch | **0 of 12** |
| 10.3-3+deb13u1danos1 (10.3 + patch) | **0 of 12** |

With the patch the kernel route was always a single next hop via `dp0p3s0` (one `nhid` throughout), unpatched
runs showed the two-member group in about half the failovers. Patched 0 of 24 against unpatched 18 of 31.

**What the upgrade did and did not do.** FRR 10.7.1 was rebuilt for Debian 13 from the sid source package
(Lua disabled, sphinx version relaxed; `Breaks: systemd (<< 259)` in sid's packaging had to be forced past,
which a proper rebuild would remove). It installed over 10.3 with only the libraries the routers already
have (`libyang3 >= 3.12.2`, `libc6 >= 2.38`), ran with R1 on 10.3 (OSPF two adjacencies Full, eBGP established, DANOS
CLI commits accepted, data plane lookups correct), and removed one of the two defects (the dead singleton is
no longer re-validated). It left the stuck rate unchanged, so it is not a remedy for this problem; whether
it brings other benefits was not examined. The 10.3 base with the patch needs no version change, keeps
Debian's security updates, and is a smaller change to carry.

**Not tested (also in the README).** The full 81-case Robot regression on a patched build; real cable pulls
(the evidence uses a link taken down from the peer, which sees a genuine link loss); other FRR daemons;
nexthop-group growth from the patch; whether upstream has or would accept a different fix. Nothing has
been shipped: the patched packages are installed on R2 (10.3-3+deb13u1danos1) for testing only and are not in OBS or
the ISO.

**What shipping it would take.** An OBS (or equivalent) package that rebuilds Debian's frr 10.3-3+deb13u1 with
the patch under a `+danos` version, a change so the ISO installs it instead of Debian's, the regression
suite, and a plan for re-applying the patch when Debian publishes a new 10.3 security update. The patch is a
few lines, but this is a standing downstream delta, which is the cost described in
`FRR-ROUTE-REPAIR-DECISION.md` section 8.
