#!/bin/bash
# Minimal 802.1x viability check on DANOS, before any dataplane work.
#
# Two questions, deliberately separated, because answering them together is how
# a dataplane gap gets mistaken for a broken control plane and the other way
# round.
#
#   Step 1  Does the authentication stack run on DANOS at all?
#           hostapd as authenticator with its built-in RADIUS server,
#           wpa_supplicant as the supplicant, over a kernel veth pair. No DPDK
#           anywhere, so a failure here is about the userland, not forwarding.
#
#   Step 2  What exactly does the dataplane not do?
#           The same hostapd on a dp0s interface. This is expected to fail;
#           the point is to see how, so the dataplane work can be scoped from
#           evidence rather than from a guess.
#
# Three things this got wrong before it got them right, all worth keeping out
# of the next person's way:
#
#   - hostapd lives in /usr/sbin, which is not on vbash's PATH. "command -v
#     hostapd" reports nothing on a system where it is installed and working.
#   - pkill -f "hostapd|wpa_supplicant" matches the ssh command line carrying
#     it and kills the session, which surfaces as ssh exit 255 and no output.
#     Kill by pid from pgrep -x instead.
#   - with -B and -f, hostapd writes nothing to stdout. Reading the log file is
#     the only way to see whether it started; an empty stdout says nothing.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/dot1x-test.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
H=${H:-192.168.203.232}
HOSTAPD=/usr/sbin/hostapd
SUPP=/usr/sbin/wpa_supplicant

exec > "$OUT" 2>&1
S() { docker exec danos-robot timeout 180 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$H" "$1" 2>&1; }

echo "===== 1. Set up the veth pair and the configuration ====="
S 'sudo ip link del vauth 2>/dev/null; sudo ip link add vauth type veth peer name vsupp
   sudo ip link set vauth up; sudo ip link set vsupp up
   ip -br link show vauth; ip -br link show vsupp'

# hostapd with the wired driver and its built-in RADIUS server. The eap_user
# file holds one MD5 account: EAP-MD5 needs no certificates, which is the
# shortest path to exercising the exchange itself.
S 'sudo tee /etc/hostapd/eap_user >/dev/null <<EOF
"testuser"	MD5	"testpass"
EOF
sudo tee /etc/hostapd/wired.conf >/dev/null <<EOF
interface=vauth
driver=wired
logger_stdout=-1
logger_stdout_level=1
ieee8021x=1
eap_reauth_period=3600
use_pae_group_addr=1
eap_server=1
eap_user_file=/etc/hostapd/eap_user
EOF
sudo tee /etc/wpa_supplicant/wired.conf >/dev/null <<EOF
ctrl_interface=/run/wpa_supplicant
ap_scan=0
network={
	key_mgmt=IEEE8021X
	eap=MD5
	identity="testuser"
	password="testpass"
	eapol_flags=0
}
EOF
echo "  configuration written"'

echo; echo "===== 2. Start the authenticator and the supplicant ====="
S "for p in \$(pgrep -x hostapd; pgrep -x wpa_supplicant); do sudo kill \"\$p\" 2>/dev/null; done
   sudo $HOSTAPD -B -t -f /tmp/hostapd.log /etc/hostapd/wired.conf
   sleep 3
   sudo $SUPP -B -Dwired -ivsupp -c /etc/wpa_supplicant/wired.conf -f /tmp/supp.log 2>&1 | tail -2
   sleep 8
   printf '  hostapd=%s supplicant=%s\n' \"\$(pgrep -c hostapd)\" \"\$(pgrep -c wpa_supplicant)\""

echo; echo "===== 3. Authentication result ====="
echo "--- hostapd log ---"
S 'sudo grep -iE "authentic|success|fail|EAP" /tmp/hostapd.log 2>/dev/null | tail -8'
echo "--- supplicant state ---"
S "sudo $SUPP -Dwired -ivsupp -c /etc/wpa_supplicant/wired.conf -B -f /tmp/supp2.log 2>/dev/null
   sleep 5
   sudo grep -iE 'EAP|authenticat|success|state' /tmp/supp.log 2>/dev/null | tail -8"

echo; echo "===== 4. Port authorisation, as hostapd decided it ====="
S 'sudo grep -iE "authorizing|unauthorized|AUTHORIZED" /tmp/hostapd.log 2>/dev/null | tail -4'

echo; echo "===== 5. Step two: the same hostapd on a dp0s interface ====="
S "sudo pkill -f hostapd 2>/dev/null; sleep 1
   sudo sed 's/^interface=vauth/interface=dp0s9/' /etc/hostapd/wired.conf > /tmp/wired-dp.conf
   sudo $HOSTAPD -B -t -f /tmp/hostapd-dp.log /tmp/wired-dp.conf 2>&1 | tail -3
   sleep 5
   printf '  hostapd on dp0s9=%s\n' \"\$(pgrep -c hostapd)\"
   sudo tail -6 /tmp/hostapd-dp.log 2>/dev/null"

echo; echo "===== Cleanup ====="
S 'for p in $(pgrep -x hostapd; pgrep -x wpa_supplicant); do sudo kill "$p" 2>/dev/null; done
   sudo ip link del vauth 2>/dev/null; echo cleaned up'
echo "===== Done ====="
