#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# docker run with host names resolved over DNS-over-HTTPS and handed to the container with --add-host.
#
# Why this exists: on bench, UDP/53 stopped working on 2026-11-06 -- the gateway, 1.1.1.1 and 8.8.8.8 all time out, while TCP/443 and
# DoH work (handoff/ENV-NOTES-20261106.md). The host resolver (systemd-resolved) then only answers names it already has cached, and
# a container that needs deb.debian.org or security.debian.org fails with "Temporary failure resolving" or, worse, with apt's
# "Unable to locate package" because the index never downloaded. Fixing the network is not this script's business; it works around it
# without touching the user's network configuration.
#
# What it resolves: deb.debian.org and security.debian.org by default (what a debian:13-slim apt needs), plus any --host NAME.
# A name is first asked of the normal resolver; its answer is used only when it is a real address. clash's fake-ip range
# (198.18.0.0/15, e.g. r2.aikon.qzz.io -> 198.18.9.206) is NOT real, so such an answer is discarded and DoH is asked instead. A name
# that DoH cannot resolve either is an error (exit 3) unless --best-effort is given. DANOS's own R2 apt repository needs a working
# proxy, not a resolver, and cannot be repaired this way.
#
# Command:  docker-run-doh.sh [--host NAME]... [--no-default-hosts] [--best-effort] -- <arguments of docker run>
#           docker-run-doh.sh --print-add-hosts [--host NAME]...        prints the --add-host arguments (for docker build, or your own docker run)
# Library:  source this file; then   doh_ip4 NAME        prints one IPv4 address
#                                    doh_add_host_args NAME...   prints "--add-host NAME:IP ..." for each name that resolves
# Env:      DOH_URLS (space separated, default "https://dns.google/resolve https://cloudflare-dns.com/dns-query"), DOH_TIMEOUT (s, default 8)
#
# Every resolution is reported on stderr as "doh: NAME -> IP (via SOURCE)", so a log shows what a container was told.

DOH_URLS=${DOH_URLS:-"https://dns.google/resolve https://cloudflare-dns.com/dns-query"}
DOH_TIMEOUT=${DOH_TIMEOUT:-8}
DOH_DEFAULT_HOSTS="deb.debian.org security.debian.org"

_doh_is_real() {   # a usable address: dotted quad, not loopback/unspecified, not inside clash's fake-ip 198.18.0.0/15
	local ip=$1
	[[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
	case "$ip" in 0.*|127.*|198.18.*|198.19.*) return 1 ;; esac
	return 0
}

doh_ip4() {
	local name=$1 ip url
	ip=$(getent ahostsv4 "$name" 2>/dev/null | awk 'NR==1{print $1}')
	if _doh_is_real "$ip"; then echo "doh: $name -> $ip (via system resolver)" >&2; echo "$ip"; return 0; fi
	for url in $DOH_URLS; do
		ip=$(curl -s -m "$DOH_TIMEOUT" -H 'accept: application/dns-json' "$url?name=$name&type=A" 2>/dev/null \
			| python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
    print(next(a["data"] for a in d.get("Answer",[]) if a.get("type")==1))
except Exception:
    pass' 2>/dev/null)
		if _doh_is_real "$ip"; then echo "doh: $name -> $ip (via ${url%%\?*})" >&2; echo "$ip"; return 0; fi
	done
	echo "doh: $name -> NOT RESOLVED (system resolver: '${ip:-no answer}'; DoH: $DOH_URLS)" >&2
	return 1
}

doh_add_host_args() {
	local n ip rc=0
	for n in "$@"; do
		if ip=$(doh_ip4 "$n"); then printf -- '--add-host %s:%s ' "$n" "$ip"; else rc=3; fi
	done
	return $rc
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	set -u
	hosts=(); defaults=1; best=0; print=0
	while [ $# -gt 0 ]; do
		case "$1" in
			--host) hosts+=("$2"); shift 2 ;;
			--no-default-hosts) defaults=0; shift ;;
			--best-effort) best=1; shift ;;
			--print-add-hosts) print=1; shift ;;
			--) shift; break ;;
			-h|--help) sed -n 2,28p "$0"; exit 0 ;;
			*) echo "unknown argument: $1 (docker run arguments go after --)" >&2; exit 2 ;;
		esac
	done
	[ "$defaults" = 1 ] && hosts=($DOH_DEFAULT_HOSTS "${hosts[@]}")
	args=$(doh_add_host_args "${hosts[@]}"); rc=$?
	if [ $rc -ne 0 ] && [ "$best" != 1 ]; then echo "docker-run-doh: not every name resolved; refusing to start the container (use --best-effort to go on)" >&2; exit 3; fi
	if [ "$print" = 1 ]; then echo "$args"; exit 0; fi
	[ $# -gt 0 ] || { echo "usage: $0 [--host NAME]... -- <docker run arguments>" >&2; exit 2; }
	# shellcheck disable=SC2086  # $args is a deliberate word-split list of --add-host pairs
	exec docker run $args "$@"
fi
