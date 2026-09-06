#!/bin/bash
# Build the product ISO -- the image an actual deployment would install.
#
# Everything this project has verified so far ran on the *test* image, which
# 90-mk-test-iso.sh produces by staging test-overlay/ into live-build's search
# path. That overlay is two files:
#
#   etc/vyatta/dataplane.conf          adds exclude-interfaces=ens31,ens30
#   etc/network/interfaces.d/mgmt      brings those NICs up by DHCP at boot
#
# Together they keep one NIC on its kernel driver as an out-of-band management
# port, which the test suites need because they open by running
# "delete interfaces dataplane" and would otherwise cut their own connection.
#
# The product image has neither. Every NIC is claimed by the dataplane, so
# management has to run over a dataplane port configured through the DANOS CLI,
# and before that configuration exists the only way in is the serial console.
# That is the real consequence of the difference and it is why this image has
# to be built and booted on its own rather than assumed to work because the
# test image does.
#
# This script does not stage the overlay and does not rename the output, so the
# ISO keeps its plain name -- an image ending in -test.iso is never a product
# image.

set -euo pipefail

BUILD_DIR=/build-iso/danos-sources/build-iso
OVERLAY="$BUILD_DIR/test-overlay"
TARGET="$BUILD_DIR/config/includes.chroot_after_packages"
LOG="$BUILD_DIR/build_product.log"

# Refuse to build if the test overlay is in live-build's search path. It is
# staged only for the duration of 90-mk-test-iso.sh and removed by its EXIT
# trap, but a killed build leaves it behind -- and a product image carrying
# exclude-interfaces would be wrong in a way nothing downstream would notice.
echo "I: checking that no test overlay is staged"
leaked=0
if [ -d "$OVERLAY" ]; then
	while read -r f; do
		if [ -e "$TARGET/${f#./}" ]; then
			echo "E: test overlay file staged: $TARGET/${f#./}" >&2
			leaked=1
		fi
	done < <(cd "$OVERLAY" && find . -type f)
fi
if [ "$leaked" -ne 0 ]; then
	echo "E: refusing to build a product image with the test overlay in place" >&2
	echo "E: remove those files, then rerun" >&2
	exit 1
fi
echo "I: search path is clean"

echo "I: cleaning and building"
cd "$BUILD_DIR"
lb clean >/dev/null 2>&1
lb build noauto > "$LOG" 2>&1 && rc=0 || rc=$?
echo "I: build finished exit=$rc"

if [ "$rc" -ne 0 ]; then
	tail -15 "$LOG"
	exit "$rc"
fi

iso=$(ls -t "$BUILD_DIR"/*.iso 2>/dev/null | head -1)
echo "I: product image: $iso"

# Prove it is the product image rather than assuming it. Both checks read the
# built tree, not the configuration that was supposed to produce it.
echo "I: verifying the image is not a test image"
# The file has to exist and lack the setting. "grep -q ... 2>/dev/null" alone
# passes when the file is absent, which would report a missing dataplane
# configuration as a clean product image.
dpconf="$BUILD_DIR/chroot/etc/vyatta/dataplane.conf"
if [ ! -f "$dpconf" ]; then
	echo "E: $dpconf does not exist -- the image has no dataplane configuration" >&2
	exit 1
fi
if grep -q '^exclude-interfaces=' "$dpconf"; then
	echo "E: dataplane.conf carries exclude-interfaces -- this is a test image" >&2
	exit 1
fi
echo "I:   dataplane.conf exists and has no exclude-interfaces"
if [ -e "$BUILD_DIR/chroot/etc/network/interfaces.d/mgmt" ]; then
	echo "E: /etc/network/interfaces.d/mgmt present -- this is a test image" >&2
	exit 1
fi
echo "I:   no /etc/network/interfaces.d/mgmt"
printf 'I:   errors in the build log: %s\n' "$(grep -cE '^E: ' "$LOG" 2>/dev/null || echo 0)"
