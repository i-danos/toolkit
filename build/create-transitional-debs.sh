#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=${1:-/build-iso/danos-build/local-repo}
BASE="$REPO_DIR/transitional"
mkdir -p "$BASE"

mktrans() {
  local name="$1" dep="$2" ver="1.0"
  local dir="$BASE/${name}_$ver"
  mkdir -p "$dir/DEBIAN"
  cat > "$dir/DEBIAN/control" <<EOF
Package: $name
Version: $ver
Section: misc
Priority: optional
Architecture: all
Maintainer: Local Build <builder@local>
Depends: $dep
Description: Transitional package for $name -> $dep
 This transitional package pulls in $dep.
EOF
  dpkg-deb --build "$dir" >/dev/null
}

mktrans configd-yang configd-v1-yang
mktrans vyatta-interfaces-yang vyatta-interfaces-v1-yang
mktrans vyatta-interfaces-bridge-yang vyatta-interfaces-bridge-v1-yang
mktrans vyatta-interfaces-dataplane-yang vyatta-interfaces-dataplane-v1-yang
mktrans vyatta-interfaces-bonding-yang vyatta-interfaces-bonding-v1-yang
mktrans vyatta-services-yang vyatta-services-v1-yang
mktrans vyatta-types-yang vyatta-types-v1-yang

# Minimal helper packages to satisfy missing feature deps
mkmeta() {
  local name="$1" ver="$2" depends="${3:-}"
  local dir="$BASE/${name}_$ver"
  mkdir -p "$dir/DEBIAN"
  {
    echo "Package: $name";
    echo "Version: $ver";
    echo "Section: misc";
    echo "Priority: optional";
    echo "Architecture: all";
    echo "Maintainer: Local Build <builder@local>";
    if [[ -n "$depends" ]]; then
      echo "Depends: $depends";
    fi
    echo "Description: Minimal meta package $name";
    echo " This meta package satisfies dependencies during ISO build.";
  } > "$dir/DEBIAN/control"
  dpkg-deb --build "$dir" >/dev/null
}

mkmeta monitord-feature-dbus 6.5.0
mkmeta vyatta-service-path-monitor-v1-yang 1.0 "configd-v1-yang"
mkmeta vyatta-interfaces-vhost-v1-yang 0.1.14 "configd-v1-yang, vyatta-interfaces-v1-yang"
mkmeta vyatta-interfaces-vhost-vif-v1-yang 0.1.14 "vyatta-interfaces-vhost-v1-yang"

find "$BASE" -maxdepth 2 -type f -name "*.deb" -exec mv -v {} "$REPO_DIR" \;

pushd "$REPO_DIR" >/dev/null
dpkg-scanpackages . /dev/null > Packages
gzip -c Packages > Packages.gz

PKG_SIZE=$(stat -c%s Packages || stat -f%z Packages 2>/dev/null || echo 0)
PKG_GZ_SIZE=$(stat -c%s Packages.gz || stat -f%z Packages.gz 2>/dev/null || echo 0)
MD5_PACKAGES=$(md5sum Packages | awk '{print $1}')
MD5_PACKAGES_GZ=$(md5sum Packages.gz | awk '{print $1}')
SHA1_PACKAGES=$(sha1sum Packages | awk '{print $1}')
SHA1_PACKAGES_GZ=$(sha1sum Packages.gz | awk '{print $1}')
SHA256_PACKAGES=$(sha256sum Packages | awk '{print $1}')
SHA256_PACKAGES_GZ=$(sha256sum Packages.gz | awk '{print $1}')
cat > Release <<REL
Archive: local
Codename: local
Origin: LocalRepo
Label: LocalRepo
Date: $(date -Ru)
Architectures: amd64 all
MD5Sum:
 $MD5_PACKAGES $PKG_SIZE Packages
 $MD5_PACKAGES_GZ $PKG_GZ_SIZE Packages.gz
SHA1:
 $SHA1_PACKAGES $PKG_SIZE Packages
 $SHA1_PACKAGES_GZ $PKG_GZ_SIZE Packages.gz
SHA256:
 $SHA256_PACKAGES $PKG_SIZE Packages
 $SHA256_PACKAGES_GZ $PKG_GZ_SIZE Packages.gz
REL
popd >/dev/null

echo "Transitional packages created and repo metadata updated in $REPO_DIR"