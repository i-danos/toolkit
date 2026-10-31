# SPDX-License-Identifier: LGPL-2.1-only
# Shared by the Secure Boot acceptance scripts that need an INSTALLED disk (sourced, not run).
#
# Every wait here has a deadline and every script that sources this installs sb_cleanup as its trap, so a
# guest that never reaches a login is killed and reported, never left running: the 2026-10-31 sbkv
# machine lived for 5 h 59 min because uefi-install.sh leaves the VM RUNNING by design and the case that
# started it had neither a timeout nor a trap.
#
# Needs: HERE (the vm/ directory), OBS_DIR-style RUN dir via sb_init, the toolkit's uefi-vm.sh, grub-pick.py,
# console.py and console-install.py. QEMU is always KVM with -cpu host (uefi-vm.sh): nothing here runs under TCG.

SB_BOOT_CAP=${SB_BOOT_CAP:-900}         # seconds from QEMU start to a login prompt, per boot
SB_INSTALL_CAP=${SB_INSTALL_CAP:-1800}  # seconds for the installer itself (not a boot)

sb_init() {   # sb_init <name> <ssh-port>
  SB_NAME=$1; SB_PORT=$2
  SB_RUN=${OBS_DIR:-/home/aikon/danos/.obs}/run/$SB_NAME
  SB_BG_PIDS=()
  trap sb_cleanup EXIT INT TERM
}

sb_cleanup() {
  trap - EXIT INT TERM
  "$HERE/uefi-vm.sh" stop "$SB_NAME" >/dev/null 2>&1
  local p
  for p in "${SB_BG_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  return 0
}

sb_other_qemu() { ps -eo comm= | grep -q '^qemu-system'; }

# sb_wait_login <seconds>: the serial log shows a login prompt, or the deadline passes (rc 1)
sb_wait_login() {
  local end=$(( $(date +%s) + $1 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    grep -aq 'login:' "$SB_RUN/serial.log" 2>/dev/null && return 0
    sleep 3
  done
  return 1
}

# sb_install <iso> <vars.fd> <disk.qcow2> <install.log>: live boot under Secure Boot, install to the blank
# disk, clean power-off. 0 only if the installer printed "Setting up grub on /dev/vda: OK".
sb_install() {
  local iso=$1 vars=$2 disk=$3 log=$4
  "$HERE/uefi-vm.sh" start "$SB_NAME" "$vars" "$SB_PORT" --cdrom "$iso" --disk "$disk" || return 11
  timeout "$SB_BOOT_CAP" "$HERE/grub-pick.py" "$SB_RUN" 2 --wait "$SB_BOOT_CAP" || { echo "no GRUB menu within ${SB_BOOT_CAP}s"; return 12; }
  sb_wait_login "$SB_BOOT_CAP" || { echo "the live system reached no login within ${SB_BOOT_CAP}s"; return 13; }
  timeout "$((SB_INSTALL_CAP + 100))" "$HERE/console-install.py" "$SB_RUN/console.sock" --user tmpuser --password tmppwd \
    --admin-user vyatta --admin-password vyatta --timeout "$SB_INSTALL_CAP" > "$log" 2>&1
  grep -aq 'Setting up grub on /dev/vda: OK' "$log" || { echo "the installer did not finish: $(tail -3 "$log" | tr '\n' ' ')"; return 14; }
  python3 - "$SB_RUN/monitor.sock" <<'PY'
import socket, sys, time
m = socket.socket(socket.AF_UNIX); m.connect(sys.argv[1]); m.settimeout(3)
m.sendall(b"system_powerdown\n"); time.sleep(1)
PY
  local p; p=$(cat "$SB_RUN/qemu.pid" 2>/dev/null)
  for _ in $(seq 1 60); do kill -0 "$p" 2>/dev/null || break; sleep 3; done
  "$HERE/uefi-vm.sh" stop "$SB_NAME"
  return 0
}

# sb_boot_disk <vars.fd> <disk.qcow2> [extra uefi-vm args]: boot the installed disk ALONE with the NVRAM the
# installer wrote; 0 when a login prompt shows within SB_BOOT_CAP.
sb_boot_disk() {
  local vars=$1 disk=$2; shift 2
  "$HERE/uefi-vm.sh" start "$SB_NAME" "$vars" "$SB_PORT" --disk "$disk" "$@" || return 21
  sb_wait_login "$SB_BOOT_CAP" || { echo "the installed disk reached no login within ${SB_BOOT_CAP}s"; return 22; }
  return 0
}

# sb_guest <cmd>...: run commands as vyatta over the serial console (each is typed as one line; never use a
# question mark in them: the CLI shell binds it to completion). Prints console.py's "$ cmd" + output.
sb_guest() { timeout 400 "$HERE/console.py" "$SB_RUN/console.sock" vyatta vyatta "$@"; }

# sb_make_superuser: the installer creates a plain admin whose shell is a sandbox; superuser + a NEW login
# gives a real shell with sudo (the same steps accept-disk-install.sh takes).
sb_make_superuser() {
  timeout 400 "$HERE/console.py" "$SB_RUN/console.sock" vyatta vyatta \
    'SID=$$; eval "$(cli-shell-api getSessionEnv $SID)"; cli-shell-api setupSession; vcli -s $SID -c "set system login user vyatta level superuser" 2>&1 | grep -vi "node exists" || true; vcli -s $SID -c commit 2>&1 | tail -2; vcli -s $SID -c save 2>&1 | tail -1' \
    > "${1:-/dev/null}" 2>&1
  timeout 120 "$HERE/console.py" "$SB_RUN/console.sock" vyatta vyatta 'exit' >/dev/null 2>&1
  sb_guest 'id' | grep -q 'vyattasu'
}
