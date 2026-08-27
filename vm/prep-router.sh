#!/bin/bash
# Prepare one booted router for the DANOS test suites.
#
# The suites log in as vyatta/vyatta and drive the box over SSH, and the REST
# suite also needs the HTTPS listener, so each router needs the same three
# things set before a suite can run: the account, sshd, and lighttpd.
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
OBS=/home/aikon/danos/.obs

"$OBS/console.py" "$SOCK" tmpuser tmppwd \
  "eval \$(cli-shell-api getSessionEnv $SID); cli-shell-api setupSession; echo session=$SID" \
  "vcli -s $SID -c 'set system login user vyatta level superuser'; \
   vcli -s $SID -c 'set system login user vyatta authentication plaintext-password vyatta'; \
   vcli -s $SID -c 'set service ssh'; \
   vcli -s $SID -c 'set service https'; \
   vcli -s $SID -c 'commit' 2>&1 | tail -2" \
  "sudo dhclient ens31 2>/dev/null; ip -4 -br addr show ens31" \
  "id vyatta; systemctl is-active ssh lighttpd" \
  2>&1 | grep -v '__CONSOLE_DONE__\|__CONSOLE_READY__'
