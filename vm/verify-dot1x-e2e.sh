#!/bin/bash
# 802.1X end to end, through the CLI, on the image that ships it.
#
#   R1  supplicant     dp0s3 201.1.1.1
#   R2  authenticator  dp0s3 201.1.1.2, dp0s9 202.1.1.2
#   R3  RADIUS server  dp0s9 202.1.1.3
#
# Every piece here has been verified on its own -- the dataplane feature, the
# EAPOL punt, hostapd over a dataplane port, the component compiling, the YANG
# loading. This is the only test that says they connect:
#
#   commit -> component writes hostapd's configuration and enables the port in
#   the dataplane -> port blocks -> supplicant authenticates against RADIUS ->
#   hostapd emits AP-STA-CONNECTED -> dot1x-action authorises -> port forwards
#
# A real RADIUS server rather than hostapd's built-in EAP user file, because
# the model requires radius-server and testing the other path would not be
# testing what was built. hostapd itself provides it, so nothing outside the
# image is involved.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/verify-dot1x-e2e.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
SUPP=192.168.203.231
AUTH=192.168.203.232
RAD=192.168.203.233
IF=dp0s3
SECRET=testing123

exec > "$OUT" 2>&1
S() { docker exec danos-robot timeout 200 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$1" "$2" 2>&1; }

cli() {
	local h=$1; shift
	local c=""
	for x in "$@"; do c="$c vcli -s \$SID -c \"$x\" 2>&1;"; done
	S "$h" "SID=\$\$; eval \"\$(cli-shell-api getSessionEnv \$SID)\"; cli-shell-api setupSession; $c
	        vcli -s \$SID -c commit 2>&1 | grep -viE 'sssd|configuration db|grub|boot-loader|crash dump|^\s*$' | tail -3"
}

state() {
	S $AUTH "sudo /opt/vyatta/bin/vplsh -l -c 'dot1x show $IF'" \
	  | grep -oE '"port_state":"[a-z-]+"' | head -1
}

ping_ok() {
	S $SUPP "ping -c 4 -W 2 201.1.1.2 2>&1 | grep -oE '[0-9]+ received'" | tail -1
}

echo "===== 1. Addresses, and a RADIUS server on R3 ====="
cli $SUPP "set interfaces dataplane $IF address 201.1.1.1/24" > /dev/null
cli $AUTH "set interfaces dataplane $IF address 201.1.1.2/24" \
          "set interfaces dataplane dp0s9 address 202.1.1.2/24" > /dev/null
cli $RAD  "set interfaces dataplane dp0s9 address 202.1.1.3/24" > /dev/null
sleep 6

S $RAD "sudo mkdir -p /etc/hostapd
sudo tee /etc/hostapd/eap_user >/dev/null <<EOF
\"testuser\"	MD5	\"testpass\"
EOF
sudo tee /etc/hostapd/radius_clients >/dev/null <<EOF
202.1.1.0/24	$SECRET
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
printf '  RADIUS server: hostapd=%s listening on 1812=%s\n' \
  \"\$(pgrep -xc hostapd)\" \
  \"\$(awk 'NR>1{split(\$2,a,\":\"); print a[2]}' /proc/net/udp | grep -cx 0714)\"" | tail -1
S $AUTH "ping -c 2 -W 2 202.1.1.3 2>&1 | grep -oE '[0-9]+ received'" | tail -1 | sed 's/^/  R2 to RADIUS: /'

echo; echo "===== 2. Before 802.1X ====="
printf '  port_state: %s\n' "$(state)"
printf '  ping R1 -> R2: %s of 4\n' "$(ping_ok)"

echo; echo "===== 3. Configure 802.1X through the CLI ====="
cli $AUTH "set interfaces dataplane $IF dot1x radius-server address 202.1.1.3" \
          "set interfaces dataplane $IF dot1x radius-server secret $SECRET" | sed 's/^/  /'
sleep 10

# Stop here if the dataplane did not recognise the topic.
#
# The component stores its configuration under "vyatta:dot1x". If the dataplane
# has no handler registered for that topic, the store entry is replayed on every
# resync, the resync aborts, and the dataplane resets and reconnects every ten
# seconds -- forever. systemctl still reports it active and nothing dumps core.
# Restarting the dataplane does not clear it, restarting vplane-controller does
# not clear it, and deleting the configuration adds a second unknown topic. The
# router has to be reinstalled.
#
# That has happened once here, from a text command stored on a protobuf-only
# path. Continuing past it costs the rest of the run and the router with it, so
# check before going on.
# The package ships vyatta-dataplane.service with no Alias, so "journalctl -u
# dataplane" matches no unit -- and journalctl prints nothing and exits 0 for a
# unit that does not exist, so that spelling fails silently rather than loudly.
# Ask for the unit and the syslog identifier together and take whichever
# answers.
DPLOG="sudo journalctl --no-pager --since '-2min' -u vyatta-dataplane -t dataplane 2>/dev/null"
n=$(S $AUTH "$DPLOG | grep -cE 'unknown topic|RESET, reconnecting'" | tail -1 | tr -dc '0-9')
if [ -z "$n" ]; then
	echo "  WARN: could not read the dataplane log; continuing without this check."
elif [ "$n" -gt 0 ]; then
	echo "  ABORT: the dataplane is rejecting the store entry -- unknown topic."
	echo "  The store entry replays on every resync, so this does not clear by"
	echo "  itself. Removing the configuration adds another unknown topic."
	S $AUTH "$DPLOG | grep -E 'unknown topic|RESET, reconnecting' | tail -3" | sed 's/^/    /'
	echo "  Reinstall this router before retrying; do not commit anything else to it."
	exit 1
fi

echo "  -- what the component did --"
S $AUTH 'printf "  hostapd=%s hostapd_cli=%s\n" "$(pgrep -xc hostapd)" "$(pgrep -xc hostapd_cli)"
  echo "  generated configuration:"; sudo sed -n "1,4p;/auth_server/p" /run/vyatta-dot1x/'"$IF"'.conf 2>/dev/null | sed "s/^/    /"' | tail -8
printf '  port_state: %s\n' "$(state)"
printf '  ping R1 -> R2: %s of 4   (blocked is the point)\n' "$(ping_ok)"

echo; echo "===== 4. Authenticate ====="
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
sudo /usr/sbin/wpa_supplicant -B -t -f /tmp/supp.log -D wired -i $IF -c /etc/wpa_supplicant/wired.conf
sleep 3
printf '  supplicant running: %s\n' \"\$(pgrep -xc wpa_supplicant)\"" | tail -1
sleep 25

echo "  -- authenticator --"
S $AUTH "sudo grep -E 'EAP-SUCCESS|AP-STA-CONNECTED|RADIUS' /run/vyatta-dot1x/../../tmp/hostapd*.log 2>/dev/null | tail -3" | sed 's/^/    /'
S $AUTH "sudo journalctl -t vyatta-dot1x --no-pager -n 4 2>/dev/null" | tail -4 | sed 's/^/    /'
echo "  -- supplicant --"
S $SUPP "sudo grep -E 'CTRL-EVENT-EAP-SUCCESS|FAILURE' /tmp/supp.log | tail -2" | sed 's/^/    /'

echo; echo "===== 5. Result ====="
printf '  port_state: %s\n' "$(state)"
printf '  ping R1 -> R2: %s of 4\n' "$(ping_ok)"

echo; echo "===== 6. Remove the configuration ====="
cli $AUTH "delete interfaces dataplane $IF dot1x" > /dev/null
sleep 8
S $AUTH 'printf "  hostapd=%s hostapd_cli=%s (both should be 0)\n" "$(pgrep -xc hostapd)" "$(pgrep -xc hostapd_cli)"' | tail -1
printf '  port_state: %s\n' "$(state)"
printf '  ping R1 -> R2: %s of 4\n' "$(ping_ok)"
