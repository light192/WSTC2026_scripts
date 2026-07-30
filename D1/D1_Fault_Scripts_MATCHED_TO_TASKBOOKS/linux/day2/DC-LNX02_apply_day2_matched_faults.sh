#!/usr/bin/env bash
set -euo pipefail
# T10: DC web works locally, HQ DNS works locally, but cross-site DNS recursion is unstable.
# Fault: DC-LNX02 recursion is restricted to DC networks only, excluding HQ clients.

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

apt-get update || true
apt-get install -y bind9 bind9-utils dnsutils || true
if [[ -f /etc/bind/named.conf.options ]]; then
  cp -a /etc/bind/named.conf.options /etc/bind/named.conf.options.before-D1-T10 || true
fi
cat >/etc/bind/named.conf.options <<'EOF'
options {
    directory "/var/cache/bind";
    recursion yes;
    # D1 T10 FAULT: recursion allowed for DC only; HQ cross-site recursive queries fail.
    allow-recursion { 10.19.110.0/24; 10.19.120.0/24; 127.0.0.1; };
    allow-query { 10.19.0.0/16; 127.0.0.1; };
    listen-on { any; };
    dnssec-validation no;
};
EOF
named-checkconf
systemctl restart bind9 || service bind9 restart
echo "T10 fault applied on DC-LNX02: DNS recursion excludes HQ networks."
