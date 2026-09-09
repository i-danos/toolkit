#!/bin/bash
# Does the YANG state container report what the dataplane actually has?
#
# verify-dot1x-e2e.sh proves the feature works, but it reads port state from
# the dataplane directly ("vplsh -c 'dot1x show'"). That says nothing about the
# model: the component's State.Get() could be absent, wrong, or reporting
# configuration back instead of a reading, and every case in that test would
# still pass.
#
# So this asks configd, not the dataplane, and compares the two:
#
#   tree_get_full_dict  config + state   -- state must be here
#   tree_get_dict       config only      -- state must NOT be here
#
# and walks the port through unconfigured -> blocked-except-eapol -> forwarding,
# checking the leaf against the dataplane at each step. authenticated-station is
# the leaf nothing has ever verified: it only has a value once a station has
# authenticated, which no earlier test reaches through the model.
#
#   R1  supplicant     dp0s9 10.9.9.2
#   R2  authenticator  dp0s3 10.9.9.1, dp0s8 10.8.8.1
#   R3  RADIUS server  dp0s8 10.8.8.2
#
# TOPO=ipsec wiring: R1.dp0s9 <-> R2.dp0s3, R2.dp0s8 <-> R3.dp0s8.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/verify-dot1x-yang-state.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
SUPP=192.168.203.155
AUTH=192.168.203.156
RAD=192.168.203.157
AIF=dp0s3          # authenticator port, the one under test
SIF=dp0s9          # supplicant port
SECRET=testing123

exec > "$OUT" 2>&1
S() { docker exec danos-robot timeout 200 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$1" "$2" 2>&1; }

cli() {
	local h=$1; shift
	local c=""
	for x in "$@"; do c="$c vcli -s \$SID -c \"$x\" 2>&1;"; done
	S "$h" "SID=\$\$; eval \"\$(cli-shell-api getSessionEnv \$SID)\"; cli-shell-api setupSession; $c
	        vcli -s \$SID -c commit 2>&1 | grep -viE 'sssd|configuration db|grub|boot-loader|crash dump|^\s*$' | tail -2"
}

# What the model says. Printed as a compact dict so a missing leaf is visible
# rather than being silently rendered as an empty string.
yang_state() {
	S $AUTH "python3 -c \"
import vyatta.configd as configd
c = configd.Client()
try:
    d = c.tree_get_full_dict('interfaces dataplane $AIF dot1x')
    print(d.get('dot1x', {}).get('state', {}))
except Exception as e:
    print('ERR', type(e).__name__, str(e)[:160])
\"" | tail -1
}

# Whether the state leaves the config-only view alone. A component that answers
# the state query with its configuration would pass every check above and fail
# this one.
yang_config_only() {
	S $AUTH "python3 -c \"
import vyatta.configd as configd
c = configd.Client()
try:
    d = c.tree_get_dict('interfaces dataplane $AIF dot1x')
    print('state' in d.get('dot1x', {}))
except Exception as e:
    print('ERR', type(e).__name__, str(e)[:160])
\"" | tail -1
}

# What the dataplane actually has, for comparison.
dp_state() {
	S $AUTH "sudo /opt/vyatta/bin/vplsh -l -c 'dot1x show $AIF'" \
	  | grep -oE '"port_state":"[a-z-]+"' | head -1 | cut -d'"' -f4
}

supp_mac() {
	S $SUPP "cat /sys/class/net/$SIF/address 2>/dev/null" | tail -1
}

# compare <label> <expected dataplane state> <expect-yang: reported|empty>
#
# "empty" is the correct answer for a port with no dot1x configured, not a
# defect. State.Get() walks the ports the component is configured for, so a port
# that is not configured has no dot1x subtree to carry state -- there is nothing
# to report, and reporting "unconfigured" would mean inventing a subtree.
#
# That does not make the "unconfigured" enum value dead. It is what the leaf
# shows when configuration says 802.1X is on and the dataplane disagrees, which
# is the disagreement the leaf exists to make visible.
compare() {
	local label=$1 want=$2 expect=$3
	local y d
	y=$(yang_state); d=$(dp_state)
	printf '  %-22s dataplane=%-22s yang=%s\n' "$label" "${d:-<none>}" "$y"
	printf '    dataplane 与期望一致: %s\n' "$([ "$d" = "$want" ] && echo PASS || echo "FAIL (want $want)")"
	if [ "$expect" = empty ]; then
		printf '    yang 无 dot1x 状态（应当如此）: %s\n' \
			"$([ "$y" = "{}" ] && echo PASS || echo "FAIL (got $y)")"
	else
		printf '    yang 与 dataplane 一致: %s\n' \
			"$(echo "$y" | grep -q "'port-state': '$d'" && echo PASS || echo FAIL)"
	fi
}

echo "===== 1. Addresses, and a RADIUS server on R3 ====="
cli $SUPP "set interfaces dataplane $SIF address 10.9.9.2/24" > /dev/null
cli $AUTH "set interfaces dataplane $AIF address 10.9.9.1/24" \
          "set interfaces dataplane dp0s8 address 10.8.8.1/24" > /dev/null
cli $RAD  "set interfaces dataplane dp0s8 address 10.8.8.2/24" > /dev/null
sleep 6

S $RAD "sudo mkdir -p /etc/hostapd
sudo tee /etc/hostapd/eap_user >/dev/null <<EOF
\"testuser\"	MD5	\"testpass\"
EOF
sudo tee /etc/hostapd/radius_clients >/dev/null <<EOF
10.8.8.0/24	$SECRET
EOF
sudo tee /etc/hostapd/radius.conf >/dev/null <<EOF
driver=none
interface=lo
logger_stdout=-1
logger_stdout_level=1
eap_server=1
eap_user_file=/etc/hostapd/eap_user
radius_server_clients=/etc/hostapd/radius_clients
radius_server_auth_port=1812
EOF
for p in \$(pgrep -x hostapd); do sudo kill \$p 2>/dev/null; done
sudo rm -f /tmp/radius.log
sudo /usr/sbin/hostapd -B -t -f /tmp/radius.log /etc/hostapd/radius.conf
sleep 3
printf '  RADIUS: hostapd=%s\n' \"\$(pgrep -xc hostapd)\"" | tail -1
S $AUTH "ping -c 2 -W 2 10.8.8.2 2>&1 | grep -oE '[0-9]+ received'" | tail -1 | sed 's/^/  R2 to RADIUS: /'

echo; echo "===== 2. Before 802.1X ====="
compare "unconfigured" "unconfigured" empty

echo; echo "===== 3. Configured, not yet authenticated ====="
cli $AUTH "set interfaces dataplane $AIF dot1x radius-server address 10.8.8.2" \
          "set interfaces dataplane $AIF dot1x radius-server secret $SECRET" | sed 's/^/  /'
sleep 10
compare "blocked-except-eapol" "blocked-except-eapol" reported
printf '    authenticated-station 缺席: %s\n' \
  "$(yang_state | grep -q 'authenticated-station' && echo 'FAIL (不该出现)' || echo PASS)"

echo; echo "===== 4. Authenticate ====="
MAC=$(supp_mac)
echo "  supplicant $SIF MAC: $MAC"
S $SUPP "sudo mkdir -p /etc/wpa_supplicant
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
for p in \$(pgrep -x wpa_supplicant); do sudo kill \$p 2>/dev/null; done
sudo rm -f /tmp/supp.log
sudo /usr/sbin/wpa_supplicant -B -t -f /tmp/supp.log -D wired -i $SIF -c /etc/wpa_supplicant/wired.conf
sleep 3
printf '  supplicant running: %s\n' \"\$(pgrep -xc wpa_supplicant)\"" | tail -1
sleep 25
S $SUPP "sudo grep -cE 'CTRL-EVENT-EAP-SUCCESS' /tmp/supp.log" | tail -1 | sed 's/^/  EAP success 次数: /'

echo; echo "===== 5. Authenticated ====="
compare "forwarding" "forwarding" reported
Y=$(yang_state)
printf '    authenticated-station 出现: %s\n' \
  "$(echo "$Y" | grep -q 'authenticated-station' && echo PASS || echo FAIL)"
printf '    与申请方 MAC 相符: %s\n' \
  "$(echo "$Y" | grep -qi "$MAC" && echo PASS || echo "FAIL (want $MAC)")"

echo; echo "===== 6. state 不得混入纯配置视图 ====="
printf '  tree_get_dict 含 state: %s  -> %s\n' "$(yang_config_only)" \
  "$([ "$(yang_config_only)" = "False" ] && echo PASS || echo FAIL)"

echo; echo "===== 7. Remove the configuration ====="
cli $AUTH "delete interfaces dataplane $AIF dot1x" > /dev/null
sleep 8
compare "unconfigured" "unconfigured" empty
