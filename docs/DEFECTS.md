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
the operator has to override each time, not a functional break. Not changed here:
fixing it means deciding what the check should trust (issuer, chain, MOK).

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
