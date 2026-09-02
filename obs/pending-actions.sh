#!/bin/bash
# The OBS work that piled up while the login was expired, run in one go.
#
# Prerequisite: a valid session cookie. First run
#   ${OBS_DIR:-/home/aikon/danos/.obs}/osc -A https://api.opensuse.org whois i-danos
# and enter the i-danos password at the prompt yourself; this script never
# enters it for you.

set -u
# OBS_DIR is where the operational state lives -- dsc/ (generated source
# packages), the osc wrapper, run/ (console sockets), fixes/. It is deliberately
# separate from this toolkit: the scripts are worth keeping in version control,
# 2 GB of build output is not. Override it if your working directory differs.
OBS=${OBS_DIR:-/home/aikon/danos/.obs}
# push.sh is a sibling in this toolkit, not something under $OBS. It used to be
# invoked from $OBS, back when the scripts were duplicated into the operational
# directory; that copy is gone and $OBS now holds only state.
HERE=$(cd "$(dirname "$0")" && pwd)
OSC="$OBS/osc -A https://api.opensuse.org"
PRJ=home:i-danos

if ! timeout 45 $OSC api /person/i-danos < /dev/null > /dev/null 2>&1; then
  echo "Authentication failed: log in manually once first." >&2
  exit 1
fi

disable_pkg() {   # name  description
  printf '  disable %-24s ' "$1"
  printf '<package name="%s" project="%s"><title>%s</title><description>%s</description><build><disable/></build></package>\n' \
    "$1" "$PRJ" "$1" "$2" > /tmp/dis.xml
  timeout 60 $OSC api -X PUT "/source/$PRJ/$1/_meta" -f /tmp/dis.xml < /dev/null >/dev/null 2>&1 \
    && { timeout 120 $OSC wipebinaries --all "$PRJ" "$1" < /dev/null >/dev/null 2>&1; echo OK; } || echo FAILED
}

echo "== 1. delete the empty golang package created by mistake =="
# The golang directory produces a source package named golang-1.15, not golang.
# An earlier attempt to disable it via PUT /source/<prj>/golang/_meta created
# the package instead, because that API creates when the target does not exist.
# The result was an empty package out of nowhere, while the real golang-1.15 was
# never disabled at all.
timeout 60 $OSC rdelete -m "Empty package created by mistake: the golang directory produces golang-1.15" "$PRJ" golang < /dev/null 2>&1 | tail -1

echo "== 2. disable the actual Go 1.15 toolchain =="
disable_pkg golang-1.15 "Debian 13 ships Go 1.24. This vendored Go 1.15 and golang-defaults form a bootstrap cycle that cannot resolve on OBS; the official DANOS OBS project does not build it either."

echo "== 3. disable packages the image does not install, which Debian provides or nothing uses =="
disable_pkg check "A build-time test framework the image does not install. Debian 13 provides check, which satisfies all four consumers (owamp, radvd, sssd, vyatta-dataplane). Debian's packaging carries Build-Conflicts: gawk, which cannot be met in an OBS build root."
disable_pkg libvirt "A fork of libvirt 7.0.0 (2021) while Debian 13 ships 11.x, and the finished image contains no libvirt package at all. The official DANOS OBS project does not build it either."
disable_pkg host-sflow "Produces only libhost-sflow-dev, which nothing in the project build-depends on and the image does not install. The local build of it fails as well. The official DANOS OBS project does not build it."

echo "== 4. push the fixes that are ready =="
MSG="Create the runtime dirs the tests write to; normalize leading-zero IPv4 as decimal" \
  "$HERE/push.sh" configd
MSG="Drop --pep8; pytest-pep8 is gone from Debian and was never in Build-Depends" \
  "$HERE/push.sh" vyatta-vrrp

echo
echo "Done. Check status with:"
echo "  $OSC api \"/build/$PRJ/_result?repository=2608&arch=x86_64\" | grep -oP 'code=\"\\K[^\"]+' | sort | uniq -c"
