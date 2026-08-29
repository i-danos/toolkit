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
# All of it goes through vcli rather than useradd/systemctl, so the box ends up
# in a state the CLI agrees with -- a hand-made account would not appear in the
# configuration and the suites' own "clear configuration" step would not know
# about it.
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
#
# Two things about config sessions, both learned the hard way:
#   - cli-shell-api getSessionEnv exports VYATTA_CONFIG_SID as readonly, so one
#     shell can only ever hold one session id. Reusing a shell with a different
#     id silently keeps the old one and every vcli call reports
#     "session <new id> does not exist".
#   - The session has to be set up before vcli will accept -s at all.
#
# Usage: prep-router.sh <console.sock> [<session id>]

set -u
SOCK=${1:?usage: prep-router.sh <console.sock> [session-id]}
SID=${2:-$((RANDOM + 9000))}
# OBS_DIR is where the operational state lives -- dsc/ (generated source
# packages), the osc wrapper, run/ (console sockets), fixes/. It is deliberately
# separate from this toolkit: the scripts are worth keeping in version control,
# 2 GB of build output is not. Override it if your working directory differs.
OBS=${OBS_DIR:-${OBS_DIR:-/home/aikon/danos/.obs}}

# The sudoers drop-in is what lets the suites run at all. DANOS grants
# "%vyattasu ALL= ALL" with no NOPASSWD, so sudo asks for a password, and over a
# non-interactive session nothing answers it. The suite keywords run "sudo ping"
# and "sudo timeout 5 tcpdump", so they hang until vymgmt gives up and reports
#
#     VyOSError: Connection timed out
#
# which reads like an unreachable router and is not one. Written by tmpuser,
# which the image already grants NOPASSWD, and checked with visudo -c: a syntax
# error in a sudoers file takes sudo away entirely.
#
# The default route dhclient installs has to go, or the suites silently measure
# the wrong thing. Every connectivity check runs from one router to an address
# on another (172.16.1.2, 10.1.1.2, ...). When the routing protocol under test
# has the route, the probe goes over the topology and a firewall drop shows up
# as a timeout, which is what the assertions expect. When it does not, the probe
# falls back to the default route into QEMU's user-mode stack, out to this host
# -- and this host may well have a route for that address. Here 172.16.1.2
# matched "via 172.18.0.2 dev singbox_tun", a proxy that accepts a TCP
# connection to any destination and completes the handshake, so
#
#     nc -vz 172.16.1.2 80  ->  "Connection ... succeeded!"
#
# came back for an address that was in fact unreachable. Every firewall "block"
# assertion then fails, and it reads exactly like the firewall not enforcing its
# rules.
#
# The blackhole below closes that path for the range the suites probe. It beats
# the default route and loses to the /24s the topology installs, so a real route
# still wins whenever one exists and a probe for an unreachable address fails at
# once instead of leaking off-box.
#
# Two wider variants were tried first and both take management down, each ending
# every login with "Connection timed out during banner exchange":
#   - deleting the default route outright
#   - blackholing 0.0.0.0/1 and 128.0.0.0/1
# The connected 10.0.2.0/24 is more specific than either, so this was not
# supposed to touch the management path -- but it does, so keep the blackhole
# narrow and confined to the range under test.

"$OBS/console.py" "$SOCK" tmpuser tmppwd \
  "eval \$(cli-shell-api getSessionEnv $SID); cli-shell-api setupSession; echo session=$SID" \
  "vcli -s $SID -c 'set system login user vyatta level superuser'; \
   vcli -s $SID -c 'set system login user vyatta authentication plaintext-password vyatta'; \
   vcli -s $SID -c 'set service ssh'; \
   vcli -s $SID -c 'set service https'; \
   vcli -s $SID -c 'set service telnet'; \
   vcli -s $SID -c 'commit' 2>&1 | tail -2" \
  "sudo sh -c 'printf \"vyatta ALL=(ALL) NOPASSWD: ALL\\n\" > /etc/sudoers.d/99-test-nopasswd; chmod 440 /etc/sudoers.d/99-test-nopasswd'; sudo visudo -c -f /etc/sudoers.d/99-test-nopasswd" \
  "sudo dhclient ens31 2>/dev/null; sudo ip route add blackhole 172.16.0.0/12 2>/dev/null; ip -4 -br addr show ens31; ip route show | grep -c blackhole" \
  "id vyatta; systemctl is-active ssh lighttpd; sudo -n -u vyatta true 2>&1 | head -1" \
  2>&1 | grep -v '__CONSOLE_DONE__\|__CONSOLE_READY__'
