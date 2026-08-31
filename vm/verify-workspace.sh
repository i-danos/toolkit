#!/bin/bash
# Check that a booted image lands a login in the vbash + sandbox workspace,
# the way official DANOS 2105 does.
#
# This is behaviour the package list cannot prove. Every piece can be present
# and correct -- vyatta-bash shipping /bin/vbash, pam-sandbox shipping
# pam_sandbox.so, cli-sandbox shipping the nspawn template -- and a login can
# still land in a plain shell, because what decides it is whether
# pam-auth-update wired the module into /etc/pam.d/common-session and whether
# the account was created with /bin/vbash. Both are decided at image build or
# first boot, not by what was installed.
#
# The expected values are read off the official 2105 image
# (danos-2105-base-amd64.iso, /live/filesystem.squashfs):
#
#   /etc/shells                 carries /bin/vbash and /usr/bin/vbash
#   /etc/pam.d/common-session   "session required pam_sandbox.so"
#   /bin/vbash                  symlink to bash
#   cli_sandbox.nspawn          [Network] Private=yes -- so a logged-in
#                               session is inside a systemd-nspawn container
#
# Usage: verify-workspace.sh <host> [user]
#        verify-workspace.sh local          check this filesystem instead
#
# Exit status is the number of checks that failed.

set -u

TARGET=${1:?usage: verify-workspace.sh <host>|local [user]}
USER_NAME=${2:-vyatta}

fail=0

run() {
	if [ "$TARGET" = local ]; then
		bash -c "$1" 2>/dev/null
	else
		ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
		    -o UserKnownHostsFile=/dev/null "$TARGET" "$1" 2>/dev/null
	fi
}

check() {
	local name=$1 cmd=$2 want=$3 got

	got=$(run "$cmd")
	if [ "$got" = "$want" ]; then
		printf '  ok    %-34s %s\n' "$name" "$got"
	else
		printf '  FAIL  %-34s got %-18s want %s\n' "$name" "${got:-<empty>}" "$want"
		fail=$((fail + 1))
	fi
}

echo "== static: the pieces are installed =="
check "/bin/vbash is a symlink to bash" \
      'readlink /bin/vbash' 'bash'
check "/bin/vbash in /etc/shells" \
      'grep -qx /bin/vbash /etc/shells && echo yes' 'yes'
check "pam_sandbox.so present" \
      'test -e /lib/security/pam_sandbox.so && echo yes' 'yes'
check "cli-sandbox present" \
      'test -x /opt/vyatta/sbin/cli-sandbox && echo yes' 'yes'

echo
echo "== wiring: the pieces are connected =="
# The one that is easiest to get wrong. pam-auth-update writes this during
# postinst; if the profile was not enabled the module is installed and never
# called, and a login succeeds into a shell outside the sandbox.
check "pam_sandbox wired into common-session" \
      'grep -q pam_sandbox /etc/pam.d/common-session && echo yes' 'yes'
check "login shell of $USER_NAME" \
      "getent passwd $USER_NAME | cut -d: -f7" '/bin/vbash'

echo
echo "== behaviour: a login actually lands in the workspace =="
# Only meaningful over ssh, as a real PAM session. cli_sandbox.nspawn sets
# [Network] Private=yes, so the session runs inside systemd-nspawn.
if [ "$TARGET" = local ]; then
	echo "  skip  behaviour checks need a real login session"
else
	check "session is inside the sandbox container" \
	      'systemd-detect-virt -c' 'systemd-nspawn'
	check "shell is vbash" \
	      'ps -o comm= -p $$' 'vbash'
	check "operational CLI answers" \
	      'show version >/dev/null 2>&1 && echo yes' 'yes'
fi

echo
if [ "$fail" -eq 0 ]; then
	echo "all checks passed"
else
	echo "$fail check(s) failed"
fi
exit "$fail"
