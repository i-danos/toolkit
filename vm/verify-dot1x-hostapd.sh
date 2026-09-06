#!/bin/bash
# Run 802.1X across a real dataplane link: hostapd as authenticator on R2's
# dp0s3, wpa_supplicant as supplicant on R1's dp0s3, over the DPDK path.
#
# The earlier viability check (verify-dot1x-viability.sh) put both ends on a
# kernel veth pair, deliberately keeping DPDK out of it, and EAP-MD5 completed.
# That proved the userland works and said nothing about forwarding. This runs
# the same exchange over a dataplane port, which needs the EAPOL punt in
# ether_forward_process() -- without it every frame is dropped as an unknown
# protocol and counted only in rx_non_ip.
#
# Both routers need the punt: the supplicant has to receive the authenticator's
# EAP-Request just as much as the other way round.
#
# EAP-MD5 needs no certificates, so it is the shortest path to exercising the
# exchange itself rather than a TLS setup.
#
# Traps already paid for, kept here so they are not paid again:
#   - hostapd and wpa_supplicant live in /usr/sbin, which is not on vbash's
#     PATH. "command -v hostapd" reports nothing on a system where it works.
#   - pkill -f "hostapd" matches the ssh command line carrying it and kills the
#     session; ssh then exits 255 with no output. Kill by pid from pgrep -x.
#   - with -B, hostapd writes nothing to stdout. Only the log file says whether
#     it started.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/verify-dot1x-hostapd.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
AUTH=192.168.203.232      # R2, authenticator
SUPP=192.168.203.231      # R1, supplicant
IF=dp0s3

exec > "$OUT" 2>&1
S() { docker exec danos-robot timeout 180 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$1" "$2" 2>&1; }

echo "===== 1. Prerequisites on both ends ====="
# hostapd and wpasupplicant are NOT in the DANOS image -- neither is in
# filesystem.packages or the OBS repository. Shipping 802.1X means adding them
# to config/package-lists/; until then they have to be installed by hand, and
# this refuses to run without them rather than reporting an authentication
# failure that is really a missing binary.
missing=0
for h in $AUTH $SUPP; do
	printf '  %-16s ' "$h"
	line=$(S "$h" 'printf "dataplane=%s hostapd=%s supplicant=%s\n" \
	          "$(systemctl is-active vyatta-dataplane)" \
	          "$([ -x /usr/sbin/hostapd ] && echo yes || echo MISSING)" \
	          "$([ -x /usr/sbin/wpa_supplicant ] && echo yes || echo MISSING)"' | tail -1)
	echo "$line"
	case "$line" in *MISSING*) missing=1 ;; esac
done
if [ "$missing" -ne 0 ]; then
	echo "  hostapd or wpa_supplicant is absent -- install them and rerun:" >&2
	echo "    echo 'deb http://deb.debian.org/debian trixie main' | sudo tee /etc/apt/sources.list.d/tmp-debian.list" >&2
	echo "    sudo apt-get update && sudo apt-get install -y hostapd wpasupplicant" >&2
	exit 1
fi

echo; echo "===== 2. Stop anything left over, and write the configuration ====="
for h in $AUTH $SUPP; do
	S "$h" 'for p in $(pgrep -x hostapd; pgrep -x wpa_supplicant); do sudo kill "$p" 2>/dev/null; done; sleep 1; echo cleared' | tail -1
done

S $AUTH "sudo mkdir -p /etc/hostapd
sudo tee /etc/hostapd/eap_user >/dev/null <<EOF
\"testuser\"	MD5	\"testpass\"
EOF
sudo tee /etc/hostapd/wired.conf >/dev/null <<EOF
interface=$IF
driver=wired
logger_stdout=-1
logger_stdout_level=1
ieee8021x=1
eap_reauth_period=3600
use_pae_group_addr=1
eap_server=1
eap_user_file=/etc/hostapd/eap_user
EOF
echo '  authenticator configuration written'" | tail -1

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
echo '  supplicant configuration written'" | tail -1

echo; echo "===== 3. Start hostapd on $IF ====="
S $AUTH "sudo rm -f /tmp/hostapd.log
sudo /usr/sbin/hostapd -B -t -f /tmp/hostapd.log /etc/hostapd/wired.conf
sleep 3
printf '  hostapd pid: %s\n' \"\$(pgrep -x hostapd | tr '\n' ' ')\"
sudo tail -5 /tmp/hostapd.log" | tail -7

echo; echo "===== 4. Has the interface joined the PAE group address ====="
# local_packet_filter() drops a multicast the interface has not joined, so this
# decides whether the supplicant's first frame -- sent to 01:80:c2:00:00:03 --
# can reach hostapd at all.
S $AUTH "ip maddr show $IF | sed 's/^/    /'" | tail -6

echo; echo "===== 5. Start the supplicant on $IF ====="
S $SUPP "sudo rm -f /tmp/supp.log
sudo /usr/sbin/wpa_supplicant -B -t -f /tmp/supp.log -D wired -i $IF -c /etc/wpa_supplicant/wired.conf
sleep 3
printf '  wpa_supplicant pid: %s\n' \"\$(pgrep -x wpa_supplicant | tr '\n' ' ')\"" | tail -2

echo; echo "===== 6. Wait for the exchange ====="
sleep 20

echo "--- authenticator log ---"
S $AUTH "sudo grep -iE 'EAP|authent|RADIUS|success|fail' /tmp/hostapd.log | tail -12" | sed 's/^/    /'
echo "--- supplicant log ---"
S $SUPP "sudo grep -iE 'EAP|authent|success|fail|state' /tmp/supp.log | tail -12" | sed 's/^/    /'

echo; echo "===== 7. Verdict ====="
ok_auth=$(S $AUTH "sudo grep -c 'authentication.*success\|EAP-Success\|CTRL-EVENT-EAP-SUCCESS' /tmp/hostapd.log" | tail -1)
ok_supp=$(S $SUPP "sudo grep -c 'CTRL-EVENT-EAP-SUCCESS\|EAP-Success\|authentication completed successfully' /tmp/supp.log" | tail -1)
echo "  success lines: authenticator ${ok_auth:-0}, supplicant ${ok_supp:-0}"
if [ "${ok_supp:-0}" -ge 1 ] || [ "${ok_auth:-0}" -ge 1 ]; then
	echo "  802.1X completed over a dataplane port"
else
	echo "  no success on either side -- read the logs above before concluding"
fi

echo; echo "===== 8. Stop both ====="
for h in $AUTH $SUPP; do
	S "$h" 'for p in $(pgrep -x hostapd; pgrep -x wpa_supplicant); do sudo kill "$p" 2>/dev/null; done; echo stopped' | tail -1
done
