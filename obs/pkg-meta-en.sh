#!/bin/bash
# Rewrite the package _meta descriptions in English.
#
# They were written in Chinese while working through each package; OBS is a
# public archive, so the metadata belongs in English. Content is unchanged —
# each disabled package still states why it is disabled.

set -u
# OBS_DIR is where the operational state lives -- dsc/ (generated source
# packages), the osc wrapper, run/ (console sockets), fixes/. It is deliberately
# separate from this toolkit: the scripts are worth keeping in version control,
# 2 GB of build output is not. Override it if your working directory differs.
OBS=${OBS_DIR:-${OBS_DIR:-/home/aikon/danos/.obs}}
OSC="$OBS/osc -A https://api.opensuse.org"
PRJ=home:i-danos

put() {   # name  disabled(0/1)  description
  local name=$1 dis=$2 desc=$3
  {
    printf '<package name="%s" project="%s">\n' "$name" "$PRJ"
    printf '  <title>%s</title>\n' "$name"
    printf '  <description>%s</description>\n' "$desc"
    [ "$dis" = 1 ] && printf '  <build><disable/></build>\n'
    printf '</package>\n'
  } > /tmp/pm_en.xml
  printf '  %-34s ' "$name"
  timeout 60 $OSC api -X PUT "/source/$PRJ/$name/_meta" -f /tmp/pm_en.xml < /dev/null >/dev/null 2>&1 \
    && echo OK || echo FAIL
}

put golang-1.15 1 'Disabled: Debian 13 ships Go 1.24. This vendored Go 1.15 and
golang-defaults form a bootstrap cycle — golang-1.15 build-depends on
golang-any | golang-go | gccgo, while golang-defaults produces golang-go, which
depends on golang-1.15-go — so neither can resolve on OBS. The local build only
gets away with it because its chroot also has the Debian archive and apt picks
the installable one. The official DANOS OBS project does not build it either;
the DANOS Go libraries build-depend on golang-go (>= 2:1.4), satisfied by the
distribution.'

put golang-defaults 1 'Disabled: the other half of the Go 1.15 bootstrap cycle
described in golang-1.15. Debian 13 ships Go 1.24 and the official DANOS OBS
project builds neither package.'

put golang-golang-x-sys 1 'Disabled: Debian 13 provides golang-golang-x-sys-dev,
and both consumers (golang-github-mdlayher-genetlink, vyatta-service-dns)
require it without a version constraint. This copy is a 2021-01-24 snapshot
whose go test fails against the 6.12 kernel. The official DANOS OBS project
does not build it.'

put golang-dbus 1 'Disabled: this fork is 4.0.0~git20170308-0vyatta3 (2017),
below the 5.0.4 that Debian 13'"'"'s golang-github-coreos-go-systemd-dev
requires. OBS prefers packages from within the project, picked this one, and
declared the whole Go library chain unresolvable:

  nothing provides golang-dbus-dev >= 5.0.4 needed by
  golang-github-coreos-go-systemd-dev, (got version 4.0.0~git20170308-0vyatta3)

Consumers (config, configd, objtree, vci, vyatta-tacacs, yangd) mostly carry no
version constraint; vci asks for >= 4.0.0~git20160605-0vyatta4, which Debian'"'"'s
5.x also satisfies.'

put check 1 'Disabled: a build-time test framework that the image does not
install. Debian 13 provides check, which satisfies all four consumers (owamp,
radvd, sssd, vyatta-dataplane). Debian'"'"'s packaging carries
Build-Conflicts: gawk, which cannot be met in an OBS build root. The official
DANOS OBS project does not build it.'

put libvirt 1 'Disabled: a fork of libvirt 7.0.0 (2021) while Debian 13 ships
11.x, and the finished image contains no libvirt package at all — building it
produces nothing that gets installed. The official DANOS OBS project does not
build it.'

put host-sflow 1 'Disabled: produces only libhost-sflow-dev, which nothing in
the project build-depends on and the image does not install. The local build of
it fails as well. The official DANOS OBS project does not build it.'

put libpcap 1 'Disabled: a fork of libpcap 1.8.1 (2016) while Debian 13 ships
1.10.5, and the image installs Debian'"'"'s libpcap0.8t64 1.10.5-2 rather than
this one. All seven consumers (dpdk, libvirt, ndpi, ppp, vermont,
vyatta-dataplane, vyatta-ndpi-support) already build against Debian'"'"'s
libpcap-dev on OBS.

The fork also dropped Debian'"'"'s soname patch — debian/patches/series is empty —
so the upstream Makefile derives MAJOR_VER from the VERSION file and produces
libpcap.so.1, which does not match debian/libpcap0.8.symbols:

  dpkg-gensymbols: error: new libraries appeared in the symbols file:
    libpcap.so.1
  dpkg-gensymbols: error: some libraries disappeared in the symbols file:
    libpcap.so.0.8

Fixing that would mean restoring the soname patch or renaming the binary
package and every dependency on it, neither of which is needed.'

put vplane-config-npf-alg-scripts 1 'Disabled: it produces exactly the same
three binary packages as vplane-config-npf — vyatta-system-alg-v1-yang,
vyatta-system-alg-routing-instance-v1-yang and vyatta-op-system-alg-v1-yang —
which is a package name collision.

The official DANOS OBS project builds only vplane-config-npf; its binary index
lists those three at 4.5.0 with Source: vplane-config-npf, and does not build
alg-scripts at all. The local build gets the right answer by accident, because
build_order.txt puts alg-scripts (line 91) before vplane-config-npf (line 122)
and the later build overwrites. OBS has no such ordering, so 3.0.1 took the
index and the image would have received a downgraded ALG model.'

put pesign-obs-integration 0 'Provides dh-signobs, which the kernel
build-depends on (dh-signobs <!stage1 !noobs>). The project had no source for
it — only a prebuilt dh-signobs_10.0_all.deb in the local repository. The source
comes from the official home:danos:2110a published repository; its SHA256
matches that repository'"'"'s Sources index byte for byte.

Carries one fix: dh_signobs compared the full output of "pesign -h", which is
"<hash> <filename>", when checking that attaching a signature left the EFI hash
unchanged. The two invocations necessarily look at different paths, so the
comparison always failed even with identical hashes, breaking the signed builds
of linux and grub2-signed. Older pesign printed the hash alone.'

put cloud-init 0 'The DANOS cloud-init integration, ported from 18.3-5vyatta9 to
Debian 13'"'"'s 25.1.4.

It had been left out of the build: build_order.txt line 43 comments it out with
a note saying Debian stock is used instead, while the image has always shipped
this modified 25.1.4-1+deb13u1vyatta1.

Four fixes were needed. The important one restores what the 25.1.4 rebase lost:
debian/cloud.cfg had been regenerated from the upstream template, changing
system_info: distro: from vrouter to debian and dropping
apply-network-vyatta and ssh_vyatta from cloud_init_modules. Both modules and
cloudinit/distros/vrouter.py still shipped, but nothing scheduled them, and
config/modules.py compares distro.name against each module'"'"'s meta["distros"]
as plain strings — "debian" is not in ["vrouter"] — so they would have been
skipped anyway. The integration was inert in the finished image.

The others: build-depend on python3-vyatta-cfgclient (it was under Depends
only, so the tests could not import vyatta.configd); update the shellify tests
to expect the vcli shebang this fork emits; and run run-parts scripts through
/bin/vcli only where it exists, rather than overriding every script'"'"'s own
shebang and failing outright wherever vcli is absent.'

echo
echo "Done."
