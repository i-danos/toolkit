#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-only
# secure_boot_dataplane_requires_iommu: under Secure Boot the DANOS data plane needs an IOMMU (docs/DEFECTS.md section 19).
# Install the image onto a blank disk under OVMF Secure Boot, then boot independent copies of that disk and its NVRAM three ways:
#   d1  Secure Boot ON,  no IOMMU       -> the data plane must not start, the NIC stays enp0s2, vplane-uio says why and exits 255
#   d2  Secure Boot ON,  virtual IOMMU  -> data plane active, NIC bound to vfio-pci, named dp0p0s2, DHCP address
#   d3  Secure Boot OFF, no IOMMU       -> data plane active on uio_pci_generic (the control that d1's refusal is about Secure Boot)
# Everything asserted is read from the guest over the serial console, and the serial log of each direction is kept
# (serial-d1.log ...); the case greps those logs, not this script's own summary. KVM, -cpu host (uefi-vm.sh), one QEMU at a time,
# every wait capped, a trap kills the guest.
#
# Usage: verify-sb-iommu.sh <iso> <outdir> <virt-fw-vars>
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ISO=${1:?iso}; OUT=${2:?outdir}; VFV=${3:?virt-fw-vars}
. "$HERE/sb-lib.sh"
sb_init sbiommu "${SBIOMMU_PORT:-2273}"
if sb_other_qemu; then echo "REFUSED: another qemu-system is running"; exit 2; fi
mkdir -p "$OUT"; : > "$OUT/results.txt"
R() { echo "$*" >> "$OUT/results.txt"; }
echo "qemu: -enable-kvm -cpu host -smp 2 -m 3072 -machine q35,smm=on (d2: kernel-irqchip=split + intel-iommu), OVMF secboot (d3: OVMF without Secure Boot)"
R "iso_sha256=$(sha256sum "$ISO" | cut -d' ' -f1)"
R "ovmf=$(dpkg-query -W -f='${Package} ${Version}' ovmf 2>/dev/null)"
R "qemu=$(qemu-system-x86_64 --version | head -1)"

bash "$HERE/sb-make-vars.sh" "$ISO" "$OUT" "$VFV" > "$OUT/make-vars.out" 2>&1 || { R "STAGE vars FAIL"; exit 3; }
qemu-img create -q -f qcow2 "$OUT/disk.qcow2" 20G || exit 3
sb_install "$ISO" "$OUT/vars.fd" "$OUT/disk.qcow2" "$OUT/install.log"; rc=$?
R "stage-install rc=$rc"
[ $rc -eq 0 ] || exit 4

# one direction: independent copies of disk and NVRAM, boot, become superuser (a plain admin's shell is a sandbox), read the facts
direction() {   # direction <name> [dhcp] ; boot env (UEFI_*, OVMF_CODE) comes from the caller's environment
  local n=$1
  cp --reflink=auto "$OUT/disk.qcow2" "$OUT/$n.qcow2"; cp "$OUT/vars.fd" "$OUT/vars-$n.fd"
  sb_boot_disk "$OUT/vars-$n.fd" "$OUT/$n.qcow2"; local brc=$?
  R "$n boot rc=$brc"
  if [ $brc -eq 0 ]; then
    sb_make_superuser "$OUT/su-$n.out"; R "$n superuser rc=$?"
    # The typed command lines are echoed into the serial log too, so none of them spells the sentence the case looks for.
    sb_guest \
      "echo MARK_${n}_BEGIN" \
      "echo vyatta | sudo -S -p '' dmesg | grep -a 'Secure boot' | head -1" \
      "systemctl is-active vyatta-dataplane" \
      "echo vyatta | sudo -S -p '' journalctl -u vyatta-dataplane --no-pager | grep -a 'Secure Level' | tail -1" \
      "echo vyatta | sudo -S -p '' journalctl -u vyatta-dataplane --no-pager | grep -a 'Control process exited' | tail -1" \
      "echo vyatta | sudo -S -p '' systemctl show vyatta-dataplane -p NRestarts" \
      "ip -br link | grep -aE 'enp0s2|dp0p0s2'" \
      "echo PCIDRV=\$(basename \$(readlink /sys/bus/pci/devices/0000:00:02.0/driver))" \
      "echo IOMMUGROUPS=\$(ls /sys/kernel/iommu_groups | wc -l)" \
      "echo MARK_${n}_END" > "$OUT/guest-$n.out" 2>&1
    R "$n guest rc=$?"
    # where the data plane runs, the port must also carry traffic: ask for a DHCP address and read it back (QEMU's user network answers)
    if [ "${2:-}" = dhcp ]; then
      sb_guest 'SID=$$; eval "$(cli-shell-api getSessionEnv $SID)"; cli-shell-api setupSession; vcli -s $SID -c "set interfaces dataplane dp0p0s2 address dhcp" 2>&1 | grep -vi "node exists"; vcli -s $SID -c commit 2>&1 | tail -3; cli-shell-api teardownSession; echo DHCP_COMMITTED' > "$OUT/dhcp-$n.out" 2>&1
      sleep 45
      sb_guest "echo MARK_${n}_ADDR_BEGIN" "ip -br addr show dp0p0s2" "echo MARK_${n}_ADDR_END" >> "$OUT/guest-$n.out" 2>&1
    else
      sb_guest "echo MARK_${n}_ADDR_BEGIN" "ip -br addr show dp0p0s2" "echo MARK_${n}_ADDR_END" >> "$OUT/guest-$n.out" 2>&1
    fi
  fi
  cp "$SB_RUN/serial.log" "$OUT/serial-$n.log"
  "$HERE/uefi-vm.sh" stop "$SB_NAME" >/dev/null 2>&1
}

R "d1 = Secure Boot ON, no IOMMU";       direction d1 nodhcp
R "d2 = Secure Boot ON, virtual IOMMU"
UEFI_MACHINE=q35,smm=on,kernel-irqchip=split UEFI_EXTRA="-device intel-iommu,intremap=on,caching-mode=on" \
  UEFI_NIC=virtio-net-pci,netdev=n0,iommu_platform=on,disable-legacy=on direction d2 dhcp
R "d3 = Secure Boot OFF, no IOMMU"
OVMF_CODE=${OVMF_NOSB_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd} direction d3 dhcp
exit 0
