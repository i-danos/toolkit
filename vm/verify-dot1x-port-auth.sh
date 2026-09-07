#!/bin/bash
# Does an unauthorised port stop forwarding, and can it still authenticate?
#
# Both halves matter and they pull in opposite directions. A port that blocks
# everything is useless -- authentication could never happen on it. A port that
# blocks nothing is not authorisation. So the check is not "traffic stops" but
# "traffic stops AND 802.1X still completes", measured in the same blocked
# state.
#
# Note what step 4 shows and does not show. Authentication succeeding does not
# unblock the port: the ping is still 0 of 4 afterwards, because nothing yet
# turns "hostapd authenticated this station" into "detach the feature". That
# link is the next piece of work, not a fault here.
#
# There are three states, not two, and the earlier version of this script could
# not tell two of them apart because the dataplane could not either:
#
#   unconfigured           no 802.1X on the port
#   blocked-except-eapol   configured, not yet authenticated
#   forwarding             configured and authenticated
#
# "dot1x show" reports which, and the feature's attachment -- listed under
# ether_lookup_features in "vplsh -l -c 'ifconfig <if>'" -- says only whether
# the port is configured. This script reads both rather than trusting the
# command it just ran.
#
# Runs on the bgp topology, which wires R1.dp0s3 to R2.dp0s3.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/verify-dot1x-port-auth.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R1=192.168.203.231; R2=192.168.203.232
IF=dp0s3
HERE=$(dirname "$0")

exec > "$OUT" 2>&1
S() { docker exec danos-robot timeout 180 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$1" "$2" 2>&1; }

cli() {
	local h=$1; shift
	local c=""
	for x in "$@"; do c="$c vcli -s \$SID -c \"$x\" >/dev/null 2>&1;"; done
	S "$h" "SID=\$\$; eval \"\$(cli-shell-api getSessionEnv \$SID)\"; cli-shell-api setupSession; $c
	        vcli -s \$SID -c commit 2>&1 | grep -viE 'sssd|configuration db|grub|boot-loader|crash dump' | tail -1"
}

# Read the attachment from the interface's own feature list, not from the
# command's exit status.
feat_attached() {
	S "$1" "sudo /opt/vyatta/bin/vplsh -l -c 'ifconfig $IF' 2>/dev/null" \
	  | grep -c "dot1x-ether-in"
}

rx_dropped() {
	S "$1" "sudo /opt/vyatta/bin/vplsh -l -c 'ifconfig' 2>/dev/null" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print(-1); raise SystemExit
for i in d.get('interfaces', []):
    if i['name'] == '$IF':
        print(i.get('statistics', {}).get('rx_dropped', -1)); break
else:
    print(-1)
"
}

ping_ok() {
	S $R1 "ping -c 4 -W 2 201.1.1.2 2>&1 | grep -oE '[0-9]+ received'" | tail -1
}

echo "===== 1. Bring the link up ====="
cli $R1 "set interfaces dataplane $IF address 201.1.1.1/24" > /dev/null
cli $R2 "set interfaces dataplane $IF address 201.1.1.2/24" > /dev/null
sleep 5
S $R1 "ip -4 -br addr show $IF" | sed 's/^/  R1 /'
S $R2 "ip -4 -br addr show $IF" | sed 's/^/  R2 /'
S $R2 "sudo /opt/vyatta/bin/vplsh -l -c 'dot1x disable $IF'" > /dev/null
sleep 2

echo; echo "===== 2. Authorised: the port forwards ====="
printf '  feature attached on R2: %s\n' "$(feat_attached $R2)"
printf '  ping R1 -> R2         : %s of 4\n' "$(ping_ok)"

echo; echo "===== 3. Block the port ====="
S $R2 "sudo /opt/vyatta/bin/vplsh -l -c 'dot1x enable $IF'; sudo /opt/vyatta/bin/vplsh -l -c 'dot1x show $IF'" | tail -3 | sed 's/^/  /'
sleep 2
printf '  feature attached on R2: %s\n' "$(feat_attached $R2)"
before=$(rx_dropped $R2)
printf '  rx_dropped before     : %s\n' "$before"
printf '  ping R1 -> R2         : %s of 4\n' "$(ping_ok)"
after=$(rx_dropped $R2)
printf '  rx_dropped after      : %s' "$after"
if [ "$before" -ge 0 ] && [ "$after" -ge 0 ]; then
	printf '   (delta %s)\n' "$((after - before))"
else
	printf '\n'
fi

echo; echo "===== 4. Blocked, but authentication still completes ====="
# The question is not "does an EAPOL frame appear somewhere" but "can a port
# still authenticate while it is blocked". Run the real exchange.
#
# Measuring it with tcpdump and no listener does not work, and the way it fails
# is misleading: punted EAPOL only surfaces on the kernel device when something
# has the interface open. Measured on a router with no dot1x feature at all --
# hostapd stopped, tcpdump captured 0 of 30; hostapd running, tcpdump captured
# them and hostapd logged all 30. A first version of this script checked with
# tcpdump alone and read that 0 as the feature dropping EAPOL.
S $R2 "sudo mkdir -p /etc/hostapd
sudo tee /etc/hostapd/eap_user >/dev/null <<EOF
\"testuser\"	MD5	\"testpass\"
EOF
sudo tee /etc/hostapd/wired.conf >/dev/null <<EOF
interface=$IF
driver=wired
logger_stdout=-1
logger_stdout_level=1
ieee8021x=1
use_pae_group_addr=1
eap_server=1
eap_user_file=/etc/hostapd/eap_user
EOF
sudo rm -f /tmp/ha.log
sudo /usr/sbin/hostapd -B -t -f /tmp/ha.log /etc/hostapd/wired.conf
sleep 3
printf '  hostapd running: %s\n' \"\$(pgrep -xc hostapd)\"" | tail -1

S $R1 "sudo mkdir -p /etc/wpa_supplicant
sudo tee /etc/wpa_supplicant/wired.conf >/dev/null <<EOF
ctrl_interface=/run/wpa_supplicant
ap_scan=0
network={
	key_mgmt=IEEE8021X
	eap=MD5
	identity=\"testuser\"
	password=\"testpass\"
	eapol_flags=0
}
EOF
sudo rm -f /tmp/supp.log
sudo /usr/sbin/wpa_supplicant -B -t -f /tmp/supp.log -D wired -i $IF -c /etc/wpa_supplicant/wired.conf
sleep 3
printf '  supplicant running: %s\n' \"\$(pgrep -xc wpa_supplicant)\"" | tail -1

sleep 20
printf '  feature still attached: %s\n' "$(feat_attached $R2)"
auth=$(S $R2 "sudo grep -c 'CTRL-EVENT-EAP-SUCCESS' /tmp/ha.log" | tail -1)
supp=$(S $R1 "sudo grep -c 'CTRL-EVENT-EAP-SUCCESS' /tmp/supp.log" | tail -1)
printf '  EAP success on a BLOCKED port: authenticator %s, supplicant %s\n' "${auth:-0}" "${supp:-0}"
S $R2 "sudo grep -E 'EAPOL-Start|authenticated' /tmp/ha.log | tail -2" | sed 's/^/    /'
printf '  ping while blocked and authenticated: %s of 4\n' "$(ping_ok)"
for h in $R2 $R1; do
	S "$h" 'for p in $(pgrep -x hostapd; pgrep -x wpa_supplicant); do sudo kill "$p" 2>/dev/null; done' > /dev/null
done

echo; echo "===== 4b. Authorise, as the authenticator's watcher would ====="
# This is the step the exchange above cannot take on its own: nothing yet
# turns "hostapd authenticated this station" into "authorise the port".
S $R2 "sudo /opt/vyatta/bin/vplsh -l -c 'dot1x authorize $IF'" > /dev/null
sleep 2
S $R2 "sudo /opt/vyatta/bin/vplsh -l -c 'dot1x show $IF'" | head -1 | sed 's/^/  /'
printf '  ping while authorised: %s of 4\n' "$(ping_ok)"
S $R2 "sudo /opt/vyatta/bin/vplsh -l -c 'dot1x unauthorize $IF'" > /dev/null
sleep 2
printf '  ping after unauthorise: %s of 4\n' "$(ping_ok)"

echo; echo "===== 5. Disable: forwarding returns ====="
S $R2 "sudo /opt/vyatta/bin/vplsh -l -c 'dot1x disable $IF'" > /dev/null
sleep 2
printf '  feature attached on R2: %s\n' "$(feat_attached $R2)"
printf '  ping R1 -> R2         : %s of 4\n' "$(ping_ok)"

echo; echo "===== Verdict ====="
echo "  unconfigured -> forwards; enabled -> blocked but still able to"
echo "  authenticate; authorised -> forwards; unauthorised -> blocked again."
echo "  Step 4b is done by hand here: nothing yet turns hostapd's success into"
echo "  an authorise call, and that is the remaining piece of 802.1X."
