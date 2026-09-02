#!/bin/bash
# Prepare one booted router for the DANOS test suites.
#
# The suites log in as vyatta/vyatta and drive the box over SSH, the REST suite
# needs the HTTPS listener, and the FIREWALL suite's "TELNET allow" case expects
# a login prompt on port 23 of the far router, so each box needs the account,
# sshd, lighttpd and telnetd set before a suite can run. The image ships
# inetutils-telnetd and vyatta-service-telnet; nothing starts it by default, and
# without it that case only ever sees "Connection refused".
#
# Everything goes through vcli rather than useradd/systemctl, so the box ends up
# in a state the CLI agrees with -- a hand-made account would not appear in the
# configuration and the suites' own "clear configuration" step would not know
# about it.
#
# The console phase is CLI-only because it has to be. The image boots into the
# vbash sandbox, and inside it sudo, ip, dhclient and systemctl are all absent:
#
#     vbash-sandbox: ip: command not found
#     System has not been booted with systemd as init system (PID 1).
#
# That is the workspace working as designed, not a fault. Two things this script
# used to do from the console moved as a result:
#
#   - "sudo dhclient ens31" is gone. The management port now comes up at boot,
#     from /etc/network/interfaces.d/mgmt in the test overlay, which is where it
#     belongs: a real box does not need a test script to reach its own
#     management port.
#   - the blackhole route is now "set protocols static route ... blackhole",
#     which the CLI has, instead of "sudo ip route add blackhole".
#
# The one step with no CLI form -- the sudoers drop-in -- runs afterwards on the
# same console, logged in as the vyatta account this script just created. That
# is what an operator would do, and it needs no network: vyatta is a superuser,
# so it lands in vyattasu, and pam_sandbox's exclude_groups is
# { "vyattasu", NULL }. That session is exempt from the sandbox and has a full
# shell, sudo included.
#
# The level has to be superuser, not admin. DANOS maps levels to groups in
# /opt/vyatta/etc/level:
#
#   superuser:vyattacfg,vyattasu,adm,wireshark,systemd-journal
#   admin:vyattacfg,vyattaadm,adm,wireshark,systemd-journal
#
# and passwordless sudo comes from vyattasu (%vyattasu ALL= ALL in
# /etc/sudoers.d/0vyatta), which only superuser gets. The suites run
# "sudo ping" and "sudo nc" over a non-interactive session, so under admin they
# block on the password prompt and the prompt never returns -- reported as
# "No match found for '$' in N seconds", which looks like a timeout and is not.
# %vyattasu is granted without NOPASSWD, hence the drop-in below.
#
# About config sessions, learned the hard way twice:
#   - cli-shell-api getSessionEnv exports VYATTA_CONFIG_SID readonly, so a shell
#     holds one session id for its lifetime. The serial console shell outlives
#     every connection to it, so a second run against the same box would invent
#     a new id, have the assignment silently ignored, and then report
#     "session <new id> does not exist" for every vcli call. This script now
#     reuses whatever id the shell already carries and only allocates one when
#     there is none.
#   - The session has to be set up before vcli will accept -s at all.
#
# Usage: prep-router.sh <console.sock>

set -u
SOCK=${1:?usage: prep-router.sh <console.sock>}
# OBS_DIR is where the operational state lives -- dsc/ (generated source
# packages), the osc wrapper, run/ (console sockets), fixes/. It is deliberately
# separate from this toolkit: the scripts are worth keeping in version control,
# 2 GB of build output is not. Override it if your working directory differs.
OBS=${OBS_DIR:-/home/aikon/danos/.obs}
CONSOLE=${CONSOLE:-$(dirname "$0")/console.py}

# The default route dhclient installs has to be kept away from the suites, or
# they silently measure the wrong thing. Every connectivity check runs from one
# router to an address on another (172.16.1.2, 10.1.1.2, ...). When the routing
# protocol under test has the route, the probe goes over the topology and a
# firewall drop shows up as a timeout, which is what the assertions expect. When
# it does not, the probe falls back to the default route into QEMU's user-mode
# stack, out to the build host -- and that host may well have a route for the
# address. Here 172.16.1.2 matched "via 172.18.0.2 dev singbox_tun", a proxy
# that completes a TCP handshake to any destination, so
#
#     nc -vz 172.16.1.2 80  ->  "Connection ... succeeded!"
#
# came back for an address that was in fact unreachable. Every firewall "block"
# assertion then fails, and it reads exactly like the firewall not enforcing its
# rules.
#
# The blackhole beats the default route and loses to the /24s the topology
# installs, so a real route still wins whenever one exists and a probe for an
# unreachable address fails at once instead of leaking off-box. Two wider
# variants were tried first and both take management down, each ending every
# login with "Connection timed out during banner exchange": deleting the default
# route outright, and blackholing 0.0.0.0/1 plus 128.0.0.0/1. The connected
# 10.0.2.0/24 is more specific than either, so neither was supposed to touch the
# management path -- but both do, so keep it narrow.
BLACKHOLE=${BLACKHOLE:-172.16.0.0/12}

echo "== console: configuration, through the CLI only =="
"$CONSOLE" "$SOCK" tmpuser tmppwd \
  'SID=${VYATTA_CONFIG_SID:-$$}; eval "$(cli-shell-api getSessionEnv $SID)"; cli-shell-api setupSession; cli-shell-api inSession && echo "session=$SID ok" || echo "session=$SID FAILED"' \
  'for c in "set system login user vyatta level superuser" \
            "set system login user vyatta authentication plaintext-password vyatta" \
            "set service ssh" "set service https" "set service telnet" \
            "set protocols static route '"$BLACKHOLE"' blackhole"; do
     vcli -s $SID -c "$c" 2>&1 | grep -vi "node exists\|is not valid" || true
   done; echo set_done' \
  'vcli -s $SID -c "commit" 2>&1 | grep -viE "sssd|configuration db" | tail -3; echo committed' \
  'show configuration commands 2>/dev/null | grep -E "login user vyatta|service (ssh|https|telnet)|static route" | sed "s/^/  /"' \
  2>&1 | grep -v '__CONSOLE_DONE__\|__CONSOLE_READY__'

echo "== console as vyatta: the one step the CLI has no form for =="
# Log out of tmpuser and back in as the account just created. vyatta is a
# superuser, so it lands in vyattasu, and pam_sandbox's exclude_groups is
# { "vyattasu", NULL } -- that session is exempt from the sandbox and gets a
# full shell, sudo included. This is what an operator does: create an admin
# account through the CLI, then log in as it for the thing the CLI cannot
# express.
#
# sudo -S takes the password on stdin the way a person types it. %vyattasu is
# granted without NOPASSWD, which is the whole reason the drop-in has to exist.
"$CONSOLE" "$SOCK" tmpuser tmppwd 'exit' >/dev/null 2>&1 || true
sleep 2

"$CONSOLE" "$SOCK" vyatta vyatta \
  'echo "shell=$(ps -o comm= -p $$) sandbox=$(systemd-detect-virt -c 2>/dev/null || echo n/a)"' \
  'echo vyatta | sudo -S sh -c "printf \"vyatta ALL=(ALL) NOPASSWD: ALL\n\" > /etc/sudoers.d/99-test-nopasswd; chmod 440 /etc/sudoers.d/99-test-nopasswd" 2>/dev/null; echo wrote' \
  'sudo -n visudo -c -f /etc/sudoers.d/99-test-nopasswd' \
  'sudo -n true && echo NOPASSWD_OK || echo NOPASSWD_FAILED' \
  'ip -4 -br addr show ens31 2>/dev/null || ip -4 -br addr show ens30 2>/dev/null' \
  2>&1 | grep -v '__CONSOLE_DONE__\|__CONSOLE_READY__'
