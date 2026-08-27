#!/bin/bash
# Build a test-only ISO. The single difference from the product image is a
# preseeded dataplane exclude-interfaces entry, which leaves one NIC bound to
# its kernel driver to serve as an out-of-band management port.
#
# Why it is needed: the danos/tests suites open by clearing state with
# "delete interfaces dataplane". If the management path shares a dataplane port
# with the interfaces under test, the first commit cuts the connection and every
# later case reports "No existing session".
#
# Why it must be preseeded: vplane-uio resolves exclusions through
# /sys/class/net/<name>/device, but vplane-modules runs earlier in the service
# chain and by then the NIC is already unbound and has no name, so an exclusion
# added afterwards is silently skipped. The configuration has to be in place
# before the first boot.
#
# The overlay normally sits outside live-build's search path. It is staged only
# while this script runs and removed as soon as the build ends, so product
# builds are unaffected.

set -euo pipefail

BUILD_DIR=/build-iso/danos-sources/build-iso
OVERLAY="$BUILD_DIR/test-overlay"
TARGET="$BUILD_DIR/config/includes.chroot_after_packages"
LOG="$BUILD_DIR/build_test.log"

cleanup() {
    # Remove the overlay whether the build succeeded or not, so it cannot leak
    # into a later product build
    if [ -d "$OVERLAY" ]; then
        (cd "$OVERLAY" && find . -type f) | while read -r f; do
            rm -f "$TARGET/${f#./}"
        done
        find "$TARGET" -type d -empty -delete 2>/dev/null || true
    fi
    echo "I: test overlay removed"
}
trap cleanup EXIT

echo "I: staging test overlay"
(cd "$OVERLAY" && find . -type f) | while read -r f; do
    install -D -m644 "$OVERLAY/${f#./}" "$TARGET/${f#./}"
done
find "$TARGET" -type f | sed 's/^/  /'

echo "I: cleaning and building"
cd "$BUILD_DIR"
lb clean >/dev/null 2>&1
lb build noauto > "$LOG" 2>&1 && rc=0 || rc=$?
echo "I: build finished exit=$rc"

if [ "$rc" -eq 0 ]; then
    iso=$(ls -t "$BUILD_DIR"/*.iso 2>/dev/null | head -1)
    if [ -n "$iso" ] && [[ "$iso" != *-test.iso ]]; then
        # Rename so it cannot be confused with the product image
        mv "$iso" "${iso%.iso}-test.iso"
        echo "I: test image: ${iso%.iso}-test.iso"
    fi
else
    tail -15 "$LOG"
fi
exit "$rc"
