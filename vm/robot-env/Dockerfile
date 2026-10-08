# SPDX-License-Identifier: LGPL-2.1-only
# One image for the three roles the Robot regression (vm/regression.sh) needs:
#
#   danos-robot        runs the Robot Framework suites
#   danos-relay:socat  one tiny container per router, relaying ssh/https (vm/relays.sh)
#   danos-build:trixie the REST suite's client host: sshd + curl (vm/restclient.sh)
#
# vm/robot-env.sh builds it once and tags it with all three names. Everything is
# installed at build time on purpose: installing at container start has hung on
# the apt lock before and the failure showed up much later as a suite that could
# not connect.
FROM debian:trixie-slim

# Mirror used while building the image only. Override with --build-arg.
ARG DEBIAN_MIRROR=http://deb.debian.org/debian
ARG DEBIAN_SECURITY_MIRROR=http://deb.debian.org/debian-security

ENV DEBIAN_FRONTEND=noninteractive

RUN for f in /etc/apt/sources.list.d/*; do \
      sed -i "s|http://deb.debian.org/debian-security|${DEBIAN_SECURITY_MIRROR}|; s|http://deb.debian.org/debian|${DEBIAN_MIRROR}|" "$f"; \
    done \
 && apt-get -o Acquire::Retries=8 update \
 && apt-get -o Acquire::Retries=8 install -y --no-install-recommends \
      python3 python3-venv python3-pip ca-certificates \
      openssh-client openssh-server sshpass iputils-ping perl socat curl \
 && rm -rf /var/lib/apt/lists/*

# robotframework: the runner. robotframework-sshlibrary and vymgmt: how the
# suites reach the routers (vymgmt drives the CLI over pxssh).
RUN python3 -m venv /opt/robotenv \
 && /opt/robotenv/bin/pip install --no-cache-dir robotframework robotframework-sshlibrary vymgmt \
 && ln -s /opt/robotenv/bin/robot /usr/local/bin/robot

CMD ["sleep", "infinity"]
