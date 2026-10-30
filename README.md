# DANOS toolkit

Tooling written while porting DANOS from Debian 10 to Debian 13 (kernel 6.12,
DPDK 24.11, FRR 10.3), covering the whole path from source packages to a booted
router under test:

```
build/   the numbered pipeline: clone the sources, order them, build them
obs/     build source packages, push them to OBS, keep the repos clean
iso/     check an image before and after building it
vm/      boot routers under QEMU and wire them into a topology
suite/   bring the DANOS Robot suites up to current tooling
seed/    NoCloud seed for exercising cloud-init
docs/    what each defect was, and how it was found, plus the 2105 baselines
```

Every script carries its reasoning in its own header. This file is the map;
[`docs/TRAPS.md`](docs/TRAPS.md) is the part worth reading first, because most of
the time here went into failures that pointed somewhere other than their cause.

## The one idea behind all of it

**A check must come out differently depending on whether the thing is true.**

That sounds obvious and is easy to violate. This project shipped a verification
that read "the package manifest matches the previous ISO" as evidence that
packages came from OBS — but for the same set of packages the manifests are
identical whatever the source, so the check could not have failed. The
discriminator that actually settled it was `iproute` (a hand-made stub that only
ever existed in the old local repo) versus `iproute2`.

The same mistake recurred in different clothes:

- `verify-iso.sh` checked that the DANOS kernel was *present*. It was — while
  the image booted Debian's. Present and booted are different questions.
- A fix was declared complete because the boot no longer hung. It didn't hang,
  and the hostname was silently wrong. "Stopped failing" is not "works".
- A packet-loss check matched `"0% packet loss"` as a substring, which
  `100% packet loss` contains. It scored a dead link as a pass.

When adding a check, ask what it would print if the thing were broken. If the
answer is "the same", it is not a check.

## Paths

The scripts default to the working directory they were written in and take an
override, so nothing needs editing to run them elsewhere:

| Variable | Default | What it is |
|---|---|---|
| `OBS_DIR` | `/home/aikon/danos/.obs` | Operational state: `dsc/`, the `osc` wrapper, `run/`, `fixes/` |
| `OBS_REPO` | `.../danos-build/obs-repo` | Local apt repo built from OBS output (`preflight.py`, or `--repo`) |
| `PKG_LISTS` | `.../danos-sources/build-iso/config/package-lists` | live-build package lists (`preflight.py`, or `--lists`) |

`OBS_DIR` is deliberately outside this repository. The scripts are worth keeping
in version control; the 2 GB of generated source packages and build staging
under them is not.

## Quick start

```sh
T=/home/aikon/danos/build-iso/danos-sources/toolkit

# before building: package lists resolve, dependency closure is satisfiable
$T/iso/preflight.py

# after building: 20 discriminator checks against the ISO
$T/iso/verify-iso.sh <image>.iso

# three routers wired for FIREWALL/IPSEC, each with its hard-coded address
TOPO=ipsec $T/vm/boot-topo.sh <test-image>.iso
for r in r1 r2 r3; do $T/vm/prep-router.sh /home/aikon/danos/.obs/run/$r/console.sock; done
$T/vm/relays.sh up r1:192.168.203.155:2231 r2:192.168.203.156:2232 r3:192.168.203.157:2233
```

## build/ — the pipeline

The numbered scripts run in order, from an empty tree to a built image:

| | |
|---|---|
| `00-start_repo.sh` | serve the local apt repo over HTTP — without it every DANOS package reports "Unable to locate", which reads like a missing package |
| `10-fetch_danos_repos.py`, `20-clone_danos_189_repos.sh` | fetch and clone upstream's 189 repositories |
| `30-audit_and_fix_repos.sh` | check out the release branch in each and report the strays |
| `40-analyze_build_order.py` | topologically sort the repositories by their Build-Depends |
| `50-build_danos_packages.sh` | build each one in the order `build_order.txt` gives |
| `80-fix_repo.sh` | regenerate `Packages`/`Release` after new .debs land |
| `90-mk-test-iso.sh` | build a test image with the overlay applied, then remove the overlay |

`build_order.txt` is the authoritative build scope: 148 active entries, and
every retired one kept as a comment with the reason it went. Read it before
concluding a repository is unused — several directories under `danos-sources/`
are only there because upstream has them.

`40-analyze_build_order.py` regenerates the file from dependency analysis and
writes no comments, so `50-` only calls it when the file is missing or empty.
Deleting `build_order.txt` therefore discards every retirement reason in it.

These scripts resolve `build_order.txt` and each other from their own location,
so mounting this directory anywhere in the build container works. The
`/build-iso` paths that remain in them refer to the *source tree* mount, which
is a different thing and still correct.

## obs/ — source packages and OBS

`mk-dsc.sh <pkg>...` builds Debian source packages from a clean `git archive
HEAD`, never from the working tree: most of these repositories carry build
residue, and for a `3.0 (quilt)` package a patched tree makes `dpkg-source`
apply the series twice.

`mk-kernel-dsc.sh` / `mk-kernel-dsc-reuse.sh` do the kernel separately — its
`debian/` needs the working tree, and the 147 MB orig cannot be uploaded
reliably (connection reset at ~85 MB, every time), so the `-reuse` variant
regenerates only the `.dsc` and `debian.tar.xz` against the orig already on OBS.

`push.sh` / `push-api.sh` upload. `push-api.sh` skips `osc co`, which times out
on the kernel and leaves a half-broken working copy.

`mk-obs-repo.sh` assembles a local apt repository from what OBS published, so
the image is built from the same binaries OBS produced.

`clean-artifacts.sh`, `commit-fixes.sh`, `redo-fix-commits.sh` are repository
hygiene. `redo-fix-commits.sh` exists because `git add -A` in these trees sweeps
in build residue — fourteen commits went out that way, the worst at 2132 files.

**Never `git add -A` here.** The working trees are dirty by nature: `Makefile.in`
and `configure` are tracked upstream and regenerated by every build, and
`linux-vyatta` sits in a quilt-applied state. Stage the files you meant to
change.

## iso/ — image acceptance

`preflight.py` runs the two checks that otherwise fail deep inside `lb build`
with messages pointing elsewhere: every package named in the package lists
exists, and the dependency closure of what actually gets installed is
satisfiable. Scoped to the closure of the lists, not to all 823 built packages —
about half are never installed and several genuinely have unsatisfiable
dependencies, so reporting those trains you to ignore the check.

`verify-iso.sh <iso>` is 20 checks on the finished image: release identity,
whether packages came from OBS or the old local repo, which kernel actually
boots, and that the retired forks really are Debian stock now. It reads the ISO
directly with `xorriso` — `binary/` beside it can disagree, because `lb clean`
does not empty it.

## vm/ — routers under QEMU

`boot-vm.sh` for one, `boot-topo.sh` for a topology (`TOPO=fw|ipsec|bgp`).

Both pass `-kernel`/`-initrd` with their own command line instead of booting the
ISO's bootloader, because the image's isolinux default has no serial console and
injecting one means typing into a five-second window.

`-cpu host` is required: the default QEMU CPU model lacks SSE4.2/AVX and DPDK
dies with SIGILL as the dataplane starts.

Every NIC gets an explicit MAC. Without one QEMU derives it from the PCI slot,
so identically-built routers collide — and that failure wears a convincing
disguise, described in [`docs/TRAPS.md`](docs/TRAPS.md).

`prep-router.sh` creates `vyatta`/`vyatta` at level `superuser`, enables ssh and
https. `relays.sh` gives each router the address its suite hard-codes.
`console.py` drives the serial console. `verify-ipsec-fix.py` checks a booted
topology for the dataplane crash.

`probe3.py`, `linkchk.py` and `vymgmt_t.py` are small probes: reachability from
the Robot container, interface state, and a direct vymgmt login. Reach for
`vymgmt_t.py` first when a suite fails — the suites drive the CLI through
vymgmt, whose own errors say little, and a one-line login test separates a
harness problem from a product one in seconds.

### Testing configd — `vm/selftest-configd.sh`

Not part of the build, and not a QEMU script; it lives here because it is the
other thing that needs a throwaway environment with more privilege than the
build has.

configd's `server/` tests are skipped by `debian/rules` (configd commit
`0d025e7`). They need what only an installed system provides — `/var/tmp/configd`
and `/run/vyatta/configd` (from `debian/configd.tmpfile`), `/config` (the
commit tests write `/config/config.boot`, hard-coded in `server/dispatcher.go`)
and `/opt/vyatta/sbin/vyatta_current_conf_ver.pl` (exec'd by absolute path) —
and the build user cannot create any of them. `fakeroot` does not change that:
it fakes ownership, grants no right to create `/config`, and `dh_auto_test` does
not run under it anyway.

`selftest-configd.sh` runs the tests as root in a one-shot container instead:
it creates those paths there, puts a stub in place of the version script, and
runs `go test ./server/` from a copy of the source. Nothing it creates leaves
the container, and nothing is added to any `.deb`. The exit status is that of
`go test`; the log goes to `handoff/runs/selftest-configd-<timestamp>.log`.

```sh
REPO_DIR=<local apt repo> $T/vm/selftest-configd.sh      # serves it for the run
APT_URL=http://172.17.0.1:8080/ $T/vm/selftest-configd.sh # or use one already up
KEEP=1 $T/vm/selftest-configd.sh                          # keep the container
```

It needs the packaging image (`IMAGE`, default `danos-pkgbuild:2608-r3`) and an
apt source carrying the danos `-dev` build dependencies. Last result: 234 PASS,
0 FAIL, 4 SKIP.

**It does not run `session/`**, and restoring `dh_auto_test` would not work yet
for a separate reason: `session/component_failure_commit_test.go` imports
`github.com/danos/godbus/dbus`. The danos fork is vendored inside the `config`
repository (`config/vendor/github.com/danos/godbus/dbus`, installed under
`usr/share/gocode` by `golang-github-danos-config-dev`) and Go's vendor
directories are visible only to `github.com/danos/config/...`, so the import
does not resolve from `configd/session`; `configd/debian/control` has no
Build-Depends entry for it either. That package's tests therefore do not
compile in a build environment, and restoring the test run needs that
dependency first.

### Assertion cases — `vm/verify-case.py`

`mk-release.py` accepts a result only if it parses as JUnit/Robot and the pass
count derives from the parsed cases; a serial transcript is not evidence.
`verify-case.py` turns a real run on a booted guest into that JUnit file.

A case (`vm/cases/<id>.yaml`) is a list of steps. Each step runs a command in a
persistent root shell and **asserts on what was measured**:

| key | meaning |
|---|---|
| `expect_exit` | the exit status equals this number exactly |
| `expect_regex` | every regex matches the output (`re.search`, multi-line) |
| `expect_not_regex` | no regex matches |
| `expect_json` | the output is exactly one JSON document (e.g. `cat commit-state.json`); each entry gives a `path` (list of keys / indexes) and one of `equals` (type-strict: `true` is not `1`), `exists`, `contains`, `matches` |

A step passes only if every assertion it declares holds. Rejected before
anything runs: a case with no steps, a step with no assertion, an unknown key (a
typo would silently weaken the case), a missing `basis` (case level and per
step: where the expected value comes from, `observed:<document>` or
`design:<reference>`), a bad regex, an unknown `{{variable}}`. A rejected case
still writes a JUnit with one failing testcase, so a stale passing file cannot
be mistaken for this run. Timeouts, a refused connection, a failed login, a lost
console and steps that could not run are all FAIL, never skipped.
Steps whose `basis` says "not yet observed" were derived from the design and may
legitimately fail the first time a real image runs them.

Exit status: 0 every step passed, 1 a step failed, 2 invalid case or invocation.
The first testcase of every run is `console-sync`, a nonce round trip, so a dead
console cannot yield an empty pass.

**Three ways to run a case — and why acceptance runs only in the guest's cloud-init.**

| how | where the runner runs | use it for |
|---|---|---|
| `--exec local` on the host | host bash | `selfcheck`, `selfcheck-pass` and the unit tests only. The guest cases need `systemctl`, configd and `/var/run/vyatta`; on a host they measure nothing |
| `--console HOST:PORT --user root` | host; commands typed into the serial login shell | **diagnosis**: `f6-diagnose`, looking around, anything that does not pin an execution context |
| `--exec local` **inside the guest**, started by cloud-init (`vm/make-guest-seed.sh`) | guest, as root, from `cloud-final.service` | **acceptance** of `f6`, `item12`, `p2p4` |

Acceptance can only be the third, because the cases pin their execution context: the
`execution-context` step requires uid 0 and a cgroup containing `cloud-final.service`. It is
not relaxed to "uid 0" on purpose: every `set` that has been accepted so far was run from
cloud-init (`SET_BEFORE_RC=0`, `handoff/verify/R4-set-context-ab-20261027.md`), the one from the
serial login was refused and the reason is not established, so the context is a variable that
must stay fixed, not hidden. A serial login shell runs in `serial-getty@ttyS0.service`.
**Running `f6` or `p2p4` with `--console` therefore fails at `execution-context`, before the
first `set`. That is the design, not a bug.**

`vm/make-guest-seed.sh CASE.yaml OUT.iso [--var K=V]` builds the seed. It embeds the unmodified
`verify-case.py`, `console.py` and the case into `/vm`, and cloud-init's `runcmd` runs the runner
with `--exec local`. It validates the case first (an invalid case builds no seed), refuses to
overwrite, and prints the sha256 of runner, console and case plus the decoded manifest of what
the guest will write. In the guest, the serial port carries `VC-SEED-SHA256 runner=… console=…
case=…` (what actually ran), the runner's own PASS/FAIL/SKIP lines, `VC-SEED-RC=<n>` and the
JUnit as gzip+base64 between `JUNIT_BEGIN` and `JUNIT_END` with its sha256 and size. Extract with
the one-liner in the script header and compare the hash; no evidence document is written in the
guest (no ISO hash, no repository there). The seed does not depend on the ISO under test. The
serial port is then only a one-way log, so QEMU's `-serial` can go to a file.

`run.sh` never binds its stdout to the serial port. The guest's `serial-getty@ttyS0` has
`TTYVHangup=yes`: if agetty starts after a script has opened `/dev/ttyS0` (the old
`exec >/dev/ttyS0`), `vhangup(2)` revokes that descriptor, every later write fails with EIO, the
whole report is lost and the script's last write makes cloud-init print `Failed to run module
scripts-user`, although the runner ran to the end. So the runner writes to files under `/vm/out`
(`run.log`, `stdout.log`, `stderr.log`, `junit.xml`, `result-block.txt`), the port is opened afresh
for every write, the result block goes out once after the runner has ended, and `run.sh` exits 0
(the case's verdict is `VC-SEED-RC`). After a boot, `/vm/out/run.log` also records the signals the
script received and a heartbeat comparing the old descriptor with a fresh open. `VC_MODE` selects how
the case is started: `setsid` (default, same cgroup, so the `execution-context` step still passes),
`plain`, or `systemd-run` — **control only**: it runs the case in `vc-case.service`, a different
cgroup, which makes `execution-context` fail.

**Running against a guest with `--console`** (diagnosis). The serial port must be reachable over
TCP (`qemu ... -serial tcp:127.0.0.1:4460,server,nowait`). The cases need root (`systemctl`,
`/var/run/vyatta/configd`). The live image does ship an official account (`tmpuser`, level
admin, from `config.boot.default`; `handoff/verify/CORRECTION-live-account-20261027.md`), but
its shell is a restricted `vbash-sandbox` (no `sudo`, no `systemctl`), so root-level cases still
need a root shell: a root login on the console, with a password set as below. Booting under TCG
takes minutes; the fixture boots nothing, the caller guarantees the guest is up. The login
handshake is `console.py`'s own.

**Giving root a password: do not use cloud-init's `chpasswd` or `users:`.** On this image the
password change is wired to configd (`vyatta-update-password` calls `configd.Client()` from PAM)
and cloud-init changes passwords in its `init` stage, before configd runs: `chpasswd: (user root)
pam_chauthtok() failed`, then `Login incorrect`
(`handoff/verify/r4-r1c-hermes/boot-chpasswd-fail.log`). What worked (`boot-usermod-hash.log`) is
setting the hash directly, bypassing PAM, from `bootcmd`:

```yaml
#cloud-config
hostname: danos-ci-test
bootcmd:
  - [ sh, -c, "usermod -p '<output of: openssl passwd -6 yourpassword>' root" ]
```

(`$` in the hash needs the quoting shown.) The seed file used for that boot is not kept here.

**Authorization is not the premise of the cases any more.** An earlier version of this section
(and of the R4-r3 report) said root cannot `set` unless it is in `vyattacfg` and made a
`root-may-configure` step check that. That is withdrawn as a general statement: the
orchestrator observed `set` accepted by root from cloud-init's `runcmd` with no group change
(`SET_BEFORE_RC=0`). What is established:

- The text `Configuration path: [] is not valid ... authorization failed ... Set failed` is how
  `formatMultilineSetWarnings` prints any access-denied error that has no path
  (`configd/common/cli_format.go:53-54,210-233`); the request path was right.
- The ACM data (`config/auth/acm_auther.go:36-73`; shipped rule allows group `vyattacfg`;
  create/update/delete default deny) does explain a refusal for a caller that is not in
  `vyattacfg`, and a `set` from the serial-console login **was** refused, then accepted after
  joining the group and refused again after leaving it (`r43.out.raw`).
- **Why the cloud-init context is accepted without the group is not explained.** The cases do
  not depend on an answer: they pin the context they are written for and fail, with the
  server's own text, if `set` is refused.

`cases/f6-diagnose.yaml` runs the same `cfgcli -print set` under one varied condition at a time
(as it was, a clean environment, no controlling terminal, a fresh session) and records the ACM
files; a difference between the probes is the finding.

**Session lifecycle.** A configd session is held in memory: after `systemctl restart configd`
every earlier session id is gone (`session N does not exist`). The cases therefore:

1. create the session (new SID, `getSessionEnv`, `setupSession`) and assert
   `cli-shell-api inSession` returns 0 right after (`session-live-after-*`);
2. rebuild the session after **every** configd restart or kill and assert it again;
3. assert the current session is usable (`session-usable-before-*`) before any step that
   uses it (`set`, `commit`, `reconcile`) when it was not just asserted. A stale session is
   therefore a FAIL at that step, not a confusing one later. (Note f6's first recorded failures
   printed `authorization failed`, not `session does not exist`, so a stale session does not by
   itself explain them.)

**Skipped steps.** A step may declare `requires: {cmd, reason, timeout}`. A probe that fails
means the thing cannot be measured here (e.g. journald is unusable): the step is recorded
**SKIPPED** (JUnit `<skipped>`), never PASS. The other steps are still judged. The run exits 3
if nothing failed but something was skipped (1 if anything failed), and the evidence status is
FAIL, because `mk-release.py` derives PASS only when every case passed. A probe that cannot run
because the console is lost is a failure.

**Suite config.** `verify-case.py cases/f6.yaml cases/item12.yaml cases/p2p4.yaml
--validate --emit-suite-config suite.json` writes `danos-suite-config-v1` (item ->
`min_cases`, `required_cases`) for `mk-release.py --suite-config`. Keep it out of the evidence
directory.

**Runner semantics.** Each step's stdout and stderr are merged (`eval ... 2>&1`), regexes are
compiled multi-line, so `\A...\Z` anchor the whole output.

**The session and `VYATTA_CONFIG_SID`.** `eval "$(cli-shell-api getSessionEnv $SID)"`
exports `VYATTA_CONFIG_SID` and makes it readonly. Done in the persistent console shell, the
first session locks the variable: a second `eval` is refused, the shell (and `cfgcli`, which
reads the variable) keep using the first session, and the new one is set up but never used.
The cases now create every session inside a subshell (`( eval ...; cli-shell-api
setupSession )`), so nothing is locked, and give `cfgcli` its session explicitly with
`env VYATTA_CONFIG_SID=$SID`. This is also what the earlier 'cfgcli kept a dead session'
trouble in the P2/P4 capture was.

For the same reason the liveness check is `env VYATTA_CONFIG_SID=$SID cli-shell-api
inSession`, never `VYATTA_CONFIG_SID=$SID cli-shell-api inSession`. With the variable
exported and readonly, the prefix form makes bash print `readonly variable`, run the command
with the OLD value, and return its status: a session that was never set up passed (the real
guest's `session-live-after-session-setup` printed exactly that and passed). The step now
requires the output to be exactly `SID=<number>`, with no `readonly` and no `does not
exist`, as well as exit status 0. Unit tests reproduce the false pass of the old form (in a
non-interactive and in an interactive bash) and show the new form fails the same situation.

Run the diagnostic case, then `f6`:

```sh
T=build-iso/danos-sources/toolkit/vm
$T/verify-case.py $T/cases/f6-diagnose.yaml --console 127.0.0.1:4475 --user root \
    --password '<from the seed>' --junit out/f6-diagnose.junit.xml --transcript out/f6-diagnose.raw
$T/verify-case.py $T/cases/f6.yaml --console 127.0.0.1:4475 --user root \
    --password '<from the seed>' --junit out/f6.junit.xml --evidence out/f6.ev.json \
    --iso <the ISO under test> --allow-dirty --transcript out/f6.raw
```

Every step that creates a session is followed by `session-live-*`: `setupSession` and
`discard` print nothing, so passing them proved no session existed.

```sh
T=build-iso/danos-sources/toolkit
$T/vm/verify-case.py $T/vm/cases/f6.yaml --console 127.0.0.1:4460 --user root --password '<from the seed>' \
    --junit out/f6.junit.xml --evidence out/evidence.json --iso <the ISO under test> --transcript out/f6.raw
$T/vm/verify-case.py $T/vm/cases/selfcheck.yaml --exec local --junit /tmp/s.xml        # must exit 1
$T/vm/verify-case.py $T/vm/cases/selfcheck-pass.yaml --exec local --junit /tmp/p.xml   # must exit 0
$T/vm/verify-case.py $T/vm/cases/p2p4.yaml --validate                                  # check a case, run nothing
```

`--exec local` runs the same steps in a local bash through the same protocol and
the same assertion code; it exists for the self-checks and the unit tests. The
protocol lines the fixture types for a step contain no `?`, Tab or `!` (the vyatta
CLI shell binds `?` and Tab to completion/help, and `!` is history expansion): the
command travels as base64 and the exit status is read with `${PIPESTATUS[0]}`. The
login handshake is `console.py`'s: it types a bare CR, the user name, the password,
and `id -un` / `exit` when it finds a shell already open; `--user` and `--password` are
refused (exit 2) if they contain `?`, `!`, Tab or any control character, since
`console.py` sends them verbatim. Console noise (kernel `[ 12.3]` lines, systemd `[ OK ]`
status lines) is stripped from the output before matching and counted in the
JUnit; `--transcript` keeps the raw bytes.

`--evidence` writes a `danos-verification-evidence-v2` record whose
`result_sha256` binds the JUnit file (which must live inside the evidence file's
directory) and whose status is recounted from it. It also names the fixture that
produced it: `tool_sha256` (this file), `console_py_sha256`, and the repository's
`tool_commit` / `tool_dirty`. A case file that changes while it is running gets no
evidence at all (exit 2). The document is **unsigned**:
sign it with the release key before `mk-release.py` will look at it.
`suite_commit` is `auto` (HEAD of the repository holding the case file); a case
file with uncommitted changes is refused unless `--allow-dirty`, which is recorded
as `suite_dirty`. `--emit-suite-config` writes the `danos-suite-config-v1` entry
that makes every step of the case required.

The case files are `.yaml` but written as JSON text, which is valid YAML: PyYAML
is not installed on the build hosts, and a hand-written YAML parser inside an
assertion tool is a way to weaken a case by mis-parsing it. With PyYAML present a
case may use YAML syntax too.

The items named by the cases (`a02_f6_rule_without_action`,
`a02_item12_w2_journal_write_failure`, `a02_p2p4_seam_crash_journal`) are **not yet
rows of `VERIFICATION_ITEMS`**, so `mk-release.py` rejects their evidence as an
unknown item until they are added there, with a suite-config entry.

**`item12`'s W2 injector is a race against configd, so it is scheduled, not timed.** The case must make
the journal write at the *end* of a commit (W2) fail while every earlier write and the runfile write
succeed. The first injector polled `running.config`'s mtime every 0.5 ms; under TCG the tail of a commit
takes milliseconds and it won, under KVM it takes microseconds and the injector swapped the journal for a
directory only after W2 had been written (no warning, `commit: null` in the saved journal, hence
`commit/state: no such field`). It now (1) waits for the commit's own `persisting` journal write via
inotify, which comes before the runfile is rendered and written, (2) swaps the journal for a directory with one
`renameat2(RENAME_EXCHANGE)` on a directory prepared in advance, (3) pins configd's threads and itself to one
cpu and runs `SCHED_FIFO`, so it runs before configd's next instruction. Conditions: root, python3, inotify,
`renameat2`, and `CAP_SYS_NICE` for the pinning (without it the injector says so on `/tmp/w2watch.out` and is
best effort only). Measured in a container against real configd commits on tmpfs: the old injector produced the
warning in 25 of 200 commits, the new one in 240 of 240 (232 of 240 with `W2_PIN=0`). **Not yet measured in a
KVM guest**: until it has been, a `commit-reports-the-journal-failure` FAIL on KVM is a fixture result to
investigate (`/tmp/w2watch.out`, the saved `commit-state.json.bak`), not yet a product verdict. The assertions
of the case were not touched; if the injector cannot be made to land, run the case under TCG.

**P2 and P4 cannot be told apart from the journal.** At both seams `commit-state.json`
shows the same thing (`commit.state` applying, acmd `may_have_been_sent` true,
`settled` false), so `cases/p2p4.yaml` reads acmd's own state, which differs: at P2
the call has not been sent, so `acmd.conf` does not hold the new rule and none of the
three files acmd's `Set()` writes (`acmd.conf`, `configruleset.txt`, `vci-local.conf`)
is newer than a reference time; at P4 the rule is present, all three are newer, and the
acmd process is not stopped. A `Set()` that stopped half way (P3) leaves some files
old and is rejected as P4; the unit tests run these two steps against fake acmd files
in each state. Reading the hook's FIFO is *not* used to prove "configd is parked
here": the hook releases as soon as anything opens the FIFO for reading, so doing it
would release the seam before the kill.

`python3 -m unittest test_verify_case` (in `vm/`) checks: the planted failures of
`selfcheck` are reported, a timeout / exit-status mismatch / failed regex / bad
JSON field is FAIL, a refused connection or a wrong password is FAIL, invalid
cases are rejected, the console protocol against a pty-backed shell with echo,
noise and a login prompt, that nothing typed contains `?`, Tab or `!`, that the
evidence record's fields are complete and its hash is that of the real file, and
that the expectations in `f6`, `item12` and `p2p4` still match the recorded real
transcripts under `handoff/verify/evidence/` (a missing transcript directory is a
**failure**, not a skip; `VC_EVIDENCE_DIR` points the tests at it). What is **not**
covered: a run against a real guest, and `p2p4`'s design-derived steps, including every
acmd-side step above, which were never observed on a real image.

Known limitations, accepted: the nonce in `console-sync` is a synchronisation mark, not
authentication, so a console that is actively forging the markers is trusted; regexes
search the whole output and may match part of it, so cases anchor them (`^...$`);
`suite_dirty` covers the case file, while the fixture itself is identified by
`tool_sha256`; the JUnit file is hashed right after it is written and is not watched
afterwards; an evidence record from a run against a guest that was not booted from the
ISO named by `--iso` is not detected (the caller guarantees it).

## suite/ — the Robot suites

The DANOS suites were written in 2020–2021 and predate the current tooling.

`modernize-for-loops.py` converts `:FOR` to `FOR`/`END` (removed in Robot
Framework 5; the suites hit 7.x). `deswitch.py` rewrites Perl `given`/`when` as
`if`/`elsif` — removed in Perl 5.42, and on 5.40 the deprecation warnings print
**on stdout**, in the middle of op-mode output.

Both converters had to learn the same lesson: a naive line-by-line pass gets
the common case right and a rarer one silently wrong. `deswitch.py` first
treated every `when` as independent, which happens to be correct for the seven
blocks ending in `continue` and wrong for the other eleven.
`modernize-for-loops.py` ended a loop at the first non-continuation line, so a
comment inside a body put `END` in the middle. Both were caught by tests, not by
reading.

## seed/ — cloud-init

On a live boot with no datasource, `ds-identify` disables cloud-init, so none of
the DANOS integration runs and none of it can be verified. Attaching this seed
makes it run — but the units also require `cloud-init` on the kernel command
line, which is a DANOS convention (`vyatta-install-image` gates on it too):

```sh
CI_TOKEN=cloud-init SEED=$T/seed/seed.iso $T/vm/boot-vm.sh <image>.iso ci 2225
```

## What this found

Four defects that only a booted image would show. Full accounts in
[`docs/DEFECTS.md`](docs/DEFECTS.md).

| Defect | Fixed in | How it presented |
|---|---|---|
| Perl smartmatch warnings on stdout | `vyatta-security-vpn 2.17` | `show vpn ipsec sa` returned warnings instead of the SA table |
| XFRM policy path never committed its transaction | `vyatta-dataplane 3.14.28` | Configuring IPsec segfaulted the dataplane, 566 times in one run |
| `linux-headers-amd64` metapackage version race | `build-iso` package list | The image booted Debian's kernel, not DANOS's |
| cloud-init stage deadlock | `cloud-init …vyatta4` | Boot hung with a seed attached; hostname silently dropped |

The first two were hidden behind each other: the Perl warnings buried the SA
table, so the empty table underneath — caused by the crashing dataplane — was
invisible until they were cleaned up.
