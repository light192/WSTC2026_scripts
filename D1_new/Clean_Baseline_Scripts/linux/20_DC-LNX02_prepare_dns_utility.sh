#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -eu
set -o pipefail 2>/dev/null || true
# D1 clean baseline: DC-LNX02 DNS/utility service (PDF role: "DNS/utility service").
# DC-LNX02 is the local resolver for DC hosts. It forwards everything (including the
# skill39.d1 zone) to the authoritative DNS on HQ-AD01 and caches the answers, so both
# DC-local and cross-site (DC<->HQ) recursive lookups work in the clean state.
apt-get update || true
apt-get install -y bind9 bind9-utils dnsutils || true
cat >/etc/bind/named.conf.options <<'EOF'
options {
    directory "/var/cache/bind";
    recursion yes;
    allow-recursion { 10.21.10.0/24; 10.19.0.0/16; 127.0.0.1; };
    allow-query { any; };
    forwarders { 10.19.20.10; };
    forward only;
    listen-on { any; };
    dnssec-validation no;
};
EOF
cat >/etc/bind/named.conf.local <<'EOF'
// DC-LNX02 is a pure forwarding/caching resolver: skill39.d1 is authoritative on
// HQ-AD01 only, no local zone files are hosted here.
EOF
named-checkconf
systemctl enable --now bind9
