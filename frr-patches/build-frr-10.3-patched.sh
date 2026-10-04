set -e
export DEBIAN_FRONTEND=noninteractive
echo "Acquire::Retries \"8\";" > /etc/apt/apt.conf.d/80retries; apt-get update -qq
apt-get install -y -qq --fix-missing build-essential dpkg-dev devscripts equivs fakeroot >/dev/null
cd /work && rm -rf src3 && mkdir src3 && cd src3
cp ../frr103/* .
dpkg-source -x frr_10.3-3+deb13u1.dsc frr-10.3 >/dev/null
cd frr-10.3
patch -p1  < /work/0001-zebra-nhg-do-not-reuse-old-nhe-with-inactive-member-10.3.patch
dch --force-bad-version -v 10.3-3+deb13u1danos1 -D unstable "zebra: do not reuse an old nexthop group that holds an inactive member (DANOS-Open 2608)." >/dev/null 2>&1
export DEB_BUILD_OPTIONS="nocheck"
apt-get install -y -qq --no-install-recommends bison chrpath flex gawk install-info libc-ares-dev libcap-dev libcrypt-dev libelf-dev libjson-c-dev liblua5.3-dev lua5.3 libpam0g-dev libpcre2-dev libprotobuf-c-dev libpython3-dev libreadline-dev librtr-dev libsnmp-dev libssh-dev libunwind-dev libyang-dev pkgconf protobuf-c-compiler python3-dev python3-pytest python3-sphinx python3 texinfo debhelper >/dev/null
dpkg-buildpackage -us -uc -b -d -Pnocheck -j$(nproc) > /work/build3.log 2>&1
echo BUILD_EXIT=$?
ls -la /work/src3/*.deb
