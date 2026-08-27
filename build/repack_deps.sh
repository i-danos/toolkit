#!/bin/bash
set -e
PACKAGES=$(dpkg-query --admindir=/tmp/squashfs_root/var/lib/dpkg -f '${Status} ${Package}\n' -W 'librte-*' | grep '^install ok installed' | cut -d ' ' -f 4)
PACKAGES="$PACKAGES bcm-linux-bde-modules-5.4.0-trunk-vyatta-amd64"

cd /build-iso/danos-build/local-repo

for pkg in $PACKAGES; do
    echo "Repacking $pkg..."
    dpkg-repack --root=/tmp/squashfs_root $pkg
done
