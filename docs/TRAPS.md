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

## Build

| What you see | What it is |
|---|---|
| A rebuild still contains what you just removed | `lb clean` does not empty `binary/`. Files staged there by an earlier run — an extra kernel, say — are packaged into the new ISO unchanged, so a package-list fix appears not to have worked. `rm -rf binary` before rebuilding, and verify against the ISO, not against `binary/`. |
| A previously built ISO has vanished | `lb clean` removes `*.iso` from the build directory, and `90-mk-test-iso.sh` runs it before every test-image build. Copy an image you want to keep out of the build directory first. |
| The image is unusually large | Two kernels. 566M is normal here; 616M and 766M were images that had picked up Debian's kernel alongside ours. Size is a cheap first check. |
| `Unable to locate package` deep in the build | `iso/preflight.py` catches this before the build starts. |
| Everything passes but the wrong kernel boots | `verify-iso.sh` checks the default boot entry now. Before that it only checked presence, and presence was never in doubt. |

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
