# Symptoms and what they actually were

Each row is something that cost real time because the message pointed somewhere
other than the cause. Read the left column when you are stuck; the right column
is what it turned out to be here.

## Test harness

| What you see | What it is |
|---|---|
| `ExceptionPxssh: Could not establish connection to host` | Almost never the network. The routers boot from a live image with no persistence, so sshd generates fresh host keys every boot, and pxssh does not pass `StrictHostKeyChecking=no` — those lines are commented out in `pxssh.py`. Fix once with an ssh_config for `192.168.203.*`. |
| `No match found for '$'/'#' in N seconds` | A hung `sudo`, not a timeout — raising the timeout changes nothing (verified: 15s → 90s, no difference). The suites run `sudo ping` and `sudo nc` over a non-interactive session and DANOS asks for a password: `/etc/sudoers.d/0vyatta` grants `%vyattasu ALL= ALL` **without** `NOPASSWD`. Note `level admin` does not even put the user in `vyattasu` — `/opt/vyatta/etc/level` gives that group to `superuser` only — but fixing the level is not enough, because the rule still wants a password. |
| Only the loopback gets configured, nothing else | A batch of `set` commands where one names an interface that does not exist. The whole batch rolls back; the loopback survives only because it is the first line. Slot numbers come from the **test data**, not the topology drawing in the suite header — the drawing labels both LAN ports `dp0s3` while `FIREWALL_DANOS_testdata.py` uses `dp0s8` and `dp0s9`. |
| `VyOSError: Connection timed out` from a capture or ping keyword | The same hung `sudo` as the row above, wearing a different coat. `capture_traffic()` runs `sudo timeout 5 tcpdump`, and vymgmt waits out the password prompt instead of the command. Nothing is wrong with the router. It reads like a topology or reachability problem and is not one -- check `sudo -n true` before looking anywhere else. |
| `Support for the old FOR loop syntax has been removed` | `suite/modernize-for-loops.py`. |
| `No keyword with name '\' found` | A `:FOR` conversion that ended the body at a comment, leaving `END` in the middle and the rest of the body outside any loop. |
| Header regexes match nothing | Two independent causes. HTTP/2 lowercases header names (RFC 7540), so `Location:` arrives as `location:`. Separately, SSHLibrary allocates a PTY, so curl styles its output with bold and OSC-8 escapes; curl ignores `NO_COLOR` for this and only `--no-styled-output` turns it off. Piping curl into grep hides the second one — the styling appears only on the path the suite uses. |
| `Should Contain ... 2105` fails | The suites pin the release id. Parameterised as `${RELEASE}`. |
| Relay containers up but nothing connects | `apt-get` inside the container hung holding `/var/lib/apt/lists/lock`, so socat never installed, and the failure surfaced much later as a connection error. Use an image that already carries socat. |

## DANOS specifics

| What you see | What it is |
|---|---|
| A command's output looks like the previous command's | The vyatta shell binds `?` to completion, so `echo X$?` arrives as `echo X$` plus a bell. Use `${PIPESTATUS[0]}`. `vm/console.py` already does. |
| `ss` prints ssh's usage | The vyatta shell resolves `ss` to `ssh`. Read `/proc/net/tcp` — and `/proc/net/tcp6`, or you will miss a service listening on `:::port` and conclude it is down. |
| `vcli -s <n>` says the session does not exist | `cli-shell-api getSessionEnv` exports `VYATTA_CONFIG_SID` **readonly**, so one shell holds one session id for its lifetime. A second id is silently ignored — `\|\| true` swallows the assignment error. |
| …and `prep-router.sh` fails the same way, so it looks like configd broke | The serial console shell **outlives every `console.py` invocation**. One earlier `eval $(cli-shell-api getSessionEnv …)` pins the readonly id for the rest of the VM's uptime, and every later script that invents its own id (`SID=${2:-$((RANDOM + 9000))}`) reports a session that was never created. The id in the error is the script's invention, not something configd lost. Settle it in one step: log out and back in — a fresh shell prints `sid=[]` and `inSession` is false. Then use `SID=$$` rather than a random id. |
| A freshly booted topology refuses `vyatta/vyatta` on SSH **and** on the serial console | The image has no `vyatta` account until `prep-router.sh` creates one over the console — SSH, HTTPS and telnetd are set up there too. Nothing about the symptom says so: the box reaches `node login:` normally, the hostfwd ports are listening, and every credential is rejected the same way, which reads as a broken image rather than a skipped step. It is easy to skip because a long-running topology only needs it once, so the previous suites appear to have gone straight from `boot-topo.sh` to SSH. Run it per router: `prep-router.sh <console.sock>`. |
| A whole suite fails `SSHException: Error reading SSH protocol banner`, every test, on an image that is fine | The router was never prepared, and `prep-router.sh` said it was. Its two console phases end in `\| grep -v ...`, and a pipeline's status is the last command's, so a `console.py` that timed out waiting for the login prompt — a router still booting — exited 1 into a status nobody read. **Fixed in 2608**: it now waits for a login prompt first and checks `${PIPESTATUS[0]}`. On older toolkits, or in any driver script, do not trust its exit status — re-check each router over SSH, which is what the suites actually use. A driver that believes it reports "ready" and then burns a full run: IPSEC_VPN 0/10 and MPLS_LDP 0/11, both against a good image. |
| Editing a script that is currently executing | bash reads a script incrementally by byte offset, so inserting lines above the running point makes it resume mid-statement. Done to `prep-router.sh` while it was preparing a router — the fix for the entry above, applied on top of itself. Kill the run, then re-run it; do not assume a long-running script has already been fully read. |
| Every `show protocols mpls-ldp ...` returns nothing — no header, no error — while LDP is actually up | `/run/frr/ldpd.sock` is missing, so the show commands have nothing to query; `ldp_vty_connect: connect: /run/frr/ldpd.sock` in the log is the giveaway. LDP itself is fine: `show mpls ldp neighbor` via `vtysh` is equally empty, but the ldpd log ends `nbr_fsm: ... from OPENREC to OPERATIONAL`. Cause is a boot race — watchfrr's first connection attempt has **no delay** at all, so a daemon still starting is marked down and restarted one poll period (5s) later; ldpd had not written its pid file, the restart could not stop it, and the duplicate unlinked the control socket before dying on the pid-file lock. It became reachable when the daemon list grew from 8 to 12. On an affected box, `systemctl restart frr` restores the socket. **Fixed in 2608** by `watchfrr_options="-i 15"` in `daemons.danos`. Two things make this hard to reproduce and both mislead. Every daemon reports `initial connection attempt failed` at startup as a matter of course — that line is normal and means nothing on its own. And ldpd is not watchfrr's "special" daemon, so `try_restart()` refuses to restart it unless zebra is already up, logging `postponing restart attempt because master zebra daemon not up` at **debug** level, invisible by default. The restart therefore fires only when a poll of ldpd lands in the window where zebra is up and ldpd is not — a first attempt with a 7s delay missed it by about a second, zebra up at 5s and ldpd at 9s with polls either side. With a 12s delay on the ldpd parent it is deterministic and shows both directions: `-i 5` gives restart ldpd 2, a pid-file lock failure, no socket, and `show mpls ldp neighbor` printing nothing at all; `-i 15` gives no restart, the socket, and the header. |
| The dataplane restarts every 10-12s, `systemctl is-active` still says `active`, and nothing has crashed | A command in vplaned's configuration store whose topic the dataplane does not recognise. The store accepts anything: `Vyatta::VPlaned::store()` and the Go `StoreCommand()` both return success, and the failure appears only when vplaned replays the store on dataplane connect. The dataplane logs `(vplaned) unknown topic '<cmd>'`, the resync aborts, and it goes `state change resync -> reset`, `RESET, reconnecting in 10s` -- forever. The box looks up, `is-active` says active, there is no core dump, and the interfaces flap admin up and down. **One bad store entry is enough to take a router out.** It survives restarting both the dataplane and vplane-controller; on a live image the quickest cure is a reboot. Storing the DELETE does not help -- that stores a *delete command*, which is another unknown topic. |
| A dataplane command works from `vplsh` and is rejected when it arrives from configuration | Two registries. `cmd_table` in `commands.c` is the console/op registry; commands replayed from vplaned are dispatched by **topic** through `find_msg_handler()`, and a command registered only in `cmd_table` is an unknown topic there. Registering a config handler is a separate call -- `dp_feature_register_string_cfg_handler()` -- and its own header marks it *deprecated in favour of the protobuf handlers*, so for new code the answer is a protobuf command, not a text one. |
| `systemctl is-active vyatta-configd` says `inactive` | There is no such unit; the real one is `configd.service`. `is-active` answers `inactive` for units that do not exist, which reads exactly like a dead service. Confirm the name with `systemctl list-units --all '*configd*'` before concluding anything. |
| `Attempt to call undefined import method with arguments (valid_binding)` during a QoS commit | Noise, not a failure — **fixed in 2608**, expect it only on older images. `Shaper.pm:19` said `use Vyatta::QoS::Profile qw(valid_binding)`, but `valid_binding` is only ever called as a method and `Profile.pm` has no Exporter; present since the 2019 DANOS import. On perl ≥ 5.18 this **warns and continues** — the import throws before importing anything, so `Shaper.pm`'s own `sub valid_binding` was always the one in use, and dropping the `qw(...)` changes no behaviour. The `[policy qos]` header printed beside it is configd's normal per-node commit output, not an error marker — check whether the commit applied before calling it a failure. |
| `Configuration path: service [https] is not valid` … but it works | The path is valid; the node was already set. Check with `vcli -s <sid> -c 'show service'` before believing the error. |
| Links exist and carry addresses but move no packets | Check `systemctl is-active vyatta-dataplane` before suspecting the topology. A crashing dataplane leaves the ports listed with their addresses while RX/TX stay at zero. `journalctl -u vyatta-dataplane \| grep -c core-dump` counts the restarts. |
| OSPF stuck in `ExStart`, ping 100% loss, neighbour discovered | Duplicate MACs. QEMU derives them from the PCI slot unless told otherwise, so identically-built routers collide. The disguise is good: OSPF hellos are multicast and still arrive, so the neighbour appears in `show protocols ospf neighbor` — but the database exchange is unicast and needs ARP, and so does ping. The tell is two routers sharing an IPv6 link-local address, which is derived from the MAC. (MTU mismatch is the textbook cause of ExStart and was checked first — both ends were 1500.) |

## Retiring the DANOS DPDK fork

The 2608 port dropped DANOS's patched DPDK 20.11 for Debian's stock 24.11 and
removed the build dependencies that marked those patches --
`librte-acl-rcu-qsbr-dq-support-dev` and
`librte-crytpodev-session-sym-pool-empty-dev` -- as obsolete. They were not
obsolete. They marked patches this code depends on, and four separate defects
came out of it:

| What you see | What it is |
|---|---|
| Dataplane SIGSEGV on `dataplane/slow`, `rte_acl_classify_scalar+299`, `%r8 == 0` | `rte_acl_build()` frees `trans_table` before rebuilding. The DANOS fork skipped that for a context registered with `rte_acl_rcu_qsbr_add()`; `src/compat.h` stubbed that call out, so nothing protects a classifying thread. Fixed in 3.14.33 by excluding readers around the rebuild. |
| A deleted firewall or IPsec rule keeps matching | `rte_acl_del_rule()` was stubbed to return 0. The caller reads -ENOENT as "not in this trie", got 0 from the first one, decremented its count and stopped -- and the rule stayed in the DPDK context. Fixed in 3.14.34 by keeping our own rule list and rebuilding. |
| `CRYPTODEV: Invalid mempool` then `Closing crypto device` | The session pool was created with `elt_size` 0, right for 20.11's two-level session model and wrong after 22.11 merged them. Fixed in 3.14.35. |
| `Could not allocate crypto session private pool` | The second level of that model, now redundant, and unallocatable anyway: 256K elements in one contiguous piece. Fixed in 3.14.36. |

The last two both end as `netlink SA message parse error` and `total-sas 0`.
Everything above the dataplane looks healthy -- charon authenticates, the IKE
and child SAs are up, the kernel has the XFRM state -- and traffic through the
tunnel is lost entirely. When IPsec does not pass traffic, read the dataplane's
own log before believing anything strongswan says.

## Login and the CLI sandbox

| What you see | What it is |
|---|---|
| The live image never reaches a login prompt; getty respawns in a loop | Not `pam_sandbox` failing — it succeeds and logs `entering sandbox cli-1000(leader=…)`, and `machinectl` shows the container running. `login` then hands over to the shell, referring to the tty by name, and util-linux 2.41 needs that node under the new root; systemd-nspawn's `/dev` has no tty in it. Fixed in `cli-sandbox` 0.27, which binds the ttys in a `sandbox-post-create.d` hook. Official 2105 has the same container `/dev` and works, because util-linux 2.33 did not need the node — the difference is util-linux, not the sandbox. |
| The console echoes what you type and answers nothing | The same thing, one layer down. The tty line discipline is still there, so the kernel echoes; the shell that would read it exited the moment `login` handed over. `agetty` back on the port and a climbing `systemctl show getty@tty1 -p NRestarts` are the tells. |
| A session that should be sandboxed reports `systemd-detect-virt -c` = `none` | Check the account's level first. `pam_sandbox.c`'s `exclude_groups` is `{ "vyattasu", NULL }`, and `level superuser` maps to `vyattasu`, so those sessions are exempt by design and never enter a container. Measure with an `admin` account. It is also why the test suites are unaffected: they log in as a superuser. |
| Inside the sandbox, `ip`, `sudo`, `systemctl` and `vplsh` are all missing, and `/sys/class/net` shows only `lo` | The workspace working as designed, not a broken image. `[Network] Private=yes` gives the container its own netns, and its PID 1 is `cli_sandbox_init`, not systemd — hence "System has not been booted with systemd as init system". Verification has to go through the CLI; configd's and opd's sockets are bind-mounted in for exactly that. Harness steps written against a sandbox-off image stop working here. |
| A login succeeds but is not in a sandbox, though `pam-sandbox` is installed | Installed is not enabled. The module is only called if `pam-auth-update` wrote it into `/etc/pam.d/common-session`, and the profile it reads lives in `/usr/share/pam-configs/`, not in the package. Check `grep pam_sandbox /etc/pam.d/common-session`, not `dpkg -l`. |

## Build

| What you see | What it is |
|---|---|
| A rebuild still contains what you just removed | `lb clean` does not empty `binary/`. Files staged there by an earlier run — an extra kernel, say — are packaged into the new ISO unchanged, so a package-list fix appears not to have worked. `rm -rf binary` before rebuilding, and verify against the ISO, not against `binary/`. |
| A previously built ISO has vanished | `lb clean` removes `*.iso` from the build directory, and `90-mk-test-iso.sh` runs it before every test-image build. Copy an image you want to keep out of the build directory first. |
| The image is unusually large | Two kernels. 566M is normal here; 616M and 766M were images that had picked up Debian's kernel alongside ours. Size is a cheap first check. |
| `Unable to locate package` deep in the build | `iso/preflight.py` catches this before the build starts. |
| Everything passes but the wrong kernel boots | `verify-iso.sh` checks the default boot entry now. Before that it only checked presence, and presence was never in doubt. |
| `deb-systemd-helper: error: systemctl preset failed on td-agent-bit.service: No such file or directory` | Expected, and nothing is missing. Read the line **above** it: `Unit /etc/systemd/system/td-agent-bit.service is masked`. deb-systemd-helper renders a masked unit as "No such file or directory", which sends you looking for an absent file. The mask is deliberate and ships in `vyatta-service-nat-cgnat-v1-yang`: DANOS replaces the packaged single-instance service with `td-agent-bit@.service`, one instance per VRF (`chvrf %i /opt/td-agent-bit/bin/td-agent-bit -c /etc/td-agent-bit/cgnat.conf`), driven by `cgnat-configuration`. The plain unit is masked so it cannot run and contend for the same configuration. dpkg configures td-agent-bit after the mask is already in place, hence the line. What *is* worth checking, since the mask means the standard service never runs: that DANOS's own path still works. On 2608 it does — binary and `chvrf` present, `/etc/td-agent-bit/` populated (`cgnat.conf` is generated at runtime and correctly absent from the image), zero unresolved libraries, and `td-agent-bit --version` runs inside the chroot. |

## OBS

| What you see | What it is |
|---|---|
| A package is absent from `osc results` | Not absent — stuck before scheduling, most likely two `.dsc` files in one package directory. OBS builds one source package per directory and cannot choose. Uploads succeed, the revision climbs, and nothing is ever built. |
| Several unrelated packages report `unresolvable` | Look for a package that produces what they link against and is not building. Five packages here reported unresolvable purely because `vyatta-dataplane` was stuck; all five cleared the moment it built. The cause is never the ones being reported. |
| OBS says the package built and the published index names the new file, but the package vanishes from the assembled repository | The download mirror lags the published index — for over two hours, once, after a `vyatta-protocols-frr` rebuild. `mk-obs-repo.sh` checks each file against the index's SHA256 and correctly refuses the old one, so the failure surfaces as a *missing* package rather than a stale one, and an ISO then builds cleanly without it. Do not wait it out and do not weaken the check: `osc api /build/<prj>/<repo>/x86_64/<source-pkg>/<file>` serves the build result directly and has no lag. `mk-obs-repo.sh` now does this automatically and names what it fetched that way. Note the path wants the **source** package, not the binary one — `vyatta-frr-vci` lives under `vyatta-protocols-frr`. |
| The status tally looks healthy | It only counts packages that have results. A package stuck before scheduling is not failed, not disabled, not unresolvable — it is in no column at all. `osc ls <prj> \| wc -l` against `osc results <prj>` is the only thing that shows it. Two packages sat invisible this way for days, holding six product fixes that had therefore never been compiled on OBS. |

## Debugging a dataplane crash

The image has neither `gdb` nor `zstd`, so the core has to come out to the host:

```sh
# in the VM — coredumpctl, not a direct .zst decompress
sudo coredumpctl dump -o /tmp/core.dp

# on the host, three things are needed for symbols:
#   1. vyatta-dataplane-dbgsym_*.deb from obs-repo
#   2. the VM's /lib and /usr/lib (197 shared libraries; without them the
#      stack is all "??" and you will read meaning into frames that have none)
#   3. gdb's sysroot pointed at them
gdb -q -batch -iex "set debuginfod enabled off" -iex "set auto-load safe-path /" \
    -ex "set sysroot <libs>" -ex "set debug-file-directory <dbgsym>/usr/lib/debug" \
    -ex "core-file core.dp" -ex "bt 18" <dbgsym>/usr/sbin/dataplane
```

Read registers in **frame 0** only. `rsi`/`rdx` and friends are caller-saved;
gdb cannot recover them for outer frames, and reading `rsi = 0` in frame 1 as
"a NULL argument was passed" is a guess dressed as evidence. Frame 0's faulting
instruction is the real thing — here `mov (%r8),%ecx` with `%r8 == 0`.

## Wrong turns worth remembering

Roughly half the elapsed time went into these. All were plausible; none were
checked before being acted on.

- **MTU mismatch** for OSPF stuck in ExStart. The textbook cause. Both ends were
  1500.
- **Uninitialised `seq`** as the cause of the dataplane crash, reasoned from
  source alone. The field genuinely is uninitialised — and is unrelated to the
  crash, which was in the ACL classifier.
- **`strlcpy` overflow**, read off a stack that had no symbols loaded. The frame
  vanished once the sysroot was supplied.
- **Entropy starvation** in `ssh-keygen` for the boot hang. Adding virtio-rng
  changed nothing.
- **`cloud-init-local`** as the hung unit, inferred from the last line of console
  output. systemd, asked directly with `systemd.log_level=debug`, said
  `cloud-init-network.service`. That is the lesson: ask the system what it is
  waiting for instead of inferring it from where the output stopped.
- **Classifying by symptom instead of cause.** Four cloud-init modules depended
  on configd; two of them hung and two only logged an error. Moving the two that
  hung cleared the deadlock and left the hostname silently wrong, costing a
  second full build-and-verify cycle. The 18.3 baseline had all four in the
  right stage and would have answered it in one step.

## Whether a patch applies depends on who is applying it

`debian/rules.real` applies the `debian/patches-vyatta` set with
`quilt push -a -q --fuzz=0` — **no fuzz at all**.

Checking that locally with `quilt push -a -f` proves nothing, because `-f` is
precisely "allow fuzz and generate no rejects". Zero rejects locally and a
failed OBS build are therefore both true at once, and the combination is bound
to appear after a stable import: upstream only has to insert a few lines near a
patch's context for its trailing hunk to stop matching. In 6.12.107 that was a
whole `BUILD_BUG_ON` block added between the variable declarations of
`dev_get_stats()` and `if (ops->ndo_get_stats64)`.

The self-check that works reproduces the build's own step: extract just the
files the series touches into a small tree (53 files, 2.5 MB), apply them in
series order with `patch -p1 -F0`, and count the failures. The full 1.8 GB
kernel tree is not needed.

The two patch sets have different appliers, so neither says anything about the
other:

- `debian/patches` is applied by `dpkg-source` — the `applying ...` lines in
  the build log;
- `debian/patches-vyatta` is applied by `debian/rules.real` during
  `binary-indep`, so it fails midway through the build rather than at unpack.

The fix is to **regenerate the context**, not to allow fuzz. Apply the patch
with fuzz once against the state that precedes it in the series, `diff -u` the
result to get the new hunk, and replace that file's section of the original
patch. The patch means the same thing afterwards; its context is realigned to
the current source.

## An `osc` batch that hangs forever, printing nothing

`~/.config/osc/oscrc` uses `TransientCredentialsManager`: the password lives in
one `osc` process and is never written to disk. The session cookie is therefore
all that carries authentication between invocations, and it lasts about a day.

When it expires, `osc` asks for the password again — through `/dev/tty`, which
`< /dev/null` does not cover, because `getpass()` opens the terminal directly.
That alone would be survivable. What makes it fatal is that `timeout` runs its
child in a **new process group**: reading the terminal from a process group
that is not the terminal's foreground group raises `SIGTTIN`, which *stops* the
reader. `timeout` sits in that same group, so it stops too, and its alarm never
fires.

The result is a batch that hangs indefinitely with no output whatsoever. Both
processes sit in state `T`. It looks exactly like OBS not answering, and no
amount of waiting changes it.

```
1901899 T  timeout 30 .../osc -A https://api.opensuse.org api /person/i-danos
1901900 T  python3 .../osc -A https://api.opensuse.org api /person/i-danos
```

Run every `osc` call under `setsid`. With no controlling terminal `getpass()`
cannot open one and an expired session fails in about three seconds with
`EOFError`, which a caller can act on.

The same expiry had a quieter second effect worth naming separately: an
unauthenticated API call returns nothing, so a script that reads "no md5 came
back" as "the package is not on OBS" reports **every** package as missing —
including the 150 that are up there and building. A check that answers
confidently when it cannot see anything is worse than one that refuses to run.
Probe authentication first and exit.
