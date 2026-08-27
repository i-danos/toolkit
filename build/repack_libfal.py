import os
import shutil

source_root = "/build-iso/temp_extraction/squashfs-root"
dest_root = "/build-iso/repack_libfal"
list_file = "/build-iso/temp_extraction/squashfs-root/var/lib/dpkg/info/libfal-opennsl1.list"

if os.path.exists(dest_root):
    shutil.rmtree(dest_root)
os.makedirs(dest_root)

# Create DEBIAN directory
os.makedirs(os.path.join(dest_root, "DEBIAN"))

# Write control file
control_content = """Package: libfal-opennsl1
Priority: optional
Section: net
Installed-Size: 155
Maintainer: Vyatta Package Maintainers <DL-vyatta-help@att.com>
Architecture: amd64
Source: libfal-opennsl
Version: 2.7
Depends: libopennsl1 (>= 3.8.0.3-0vyatta3), python3, python3-ufispace-bsp-utils, python3-accton-as5916-54xks-sfp-helper, fal-l2-upd-port-status, bcm-linux-bde-modules-signed | bcm-linux-bde-modules-unsigned | bcm-linux-bde-modules, libc6 (>= 2.14), libinih1 (>= 40), librte-eal20.0 (>= 19.11), librte-ethdev20.0 (>= 19.11), librte-mbuf20.0 (>= 19.11), librte-mempool20.0 (>= 19.11), librte-net20.0 (>= 19.11), librte-pmd-ixgbe20.0 (>= 18.05), libvyatta-dpdk-swport1 (>= 0.1.6)
Description: Broadcom forwarding abstraction layer integration based on OpenNSL
 Broadcom switch FAL based on OpenNSL
"""
with open(os.path.join(dest_root, "DEBIAN", "control"), "w") as f:
    f.write(control_content)

# Copy files
with open(list_file, "r") as f:
    for line in f:
        path = line.strip()
        if not path or path == "/.":
            continue
        
        src_path = os.path.join(source_root, path.lstrip("/"))
        dst_path = os.path.join(dest_root, path.lstrip("/"))
        
        if os.path.isdir(src_path):
            if not os.path.exists(dst_path):
                os.makedirs(dst_path)
        elif os.path.isfile(src_path) or os.path.islink(src_path):
            # Ensure parent dir exists
            parent = os.path.dirname(dst_path)
            if not os.path.exists(parent):
                os.makedirs(parent)
            # Copy file or link
            if os.path.islink(src_path):
                link_target = os.readlink(src_path)
                os.symlink(link_target, dst_path)
            else:
                shutil.copy2(src_path, dst_path)
        else:
            print(f"Warning: {src_path} not found or not a regular file/dir")

print("Repackaging preparation complete.")
