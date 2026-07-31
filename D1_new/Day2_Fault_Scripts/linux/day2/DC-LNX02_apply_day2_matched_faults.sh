#!/usr/bin/env bash
set -euo pipefail
# T10: DC web works locally, HQ DNS works locally, but cross-site DNS
# recursion is unstable.
# Fault: DC-LNX02's allow-recursion is restricted to the DC network only,
# excluding HQ (10.19.0.0/16), so recursive queries reaching DC-LNX02 from
# HQ networks are refused while DC-local recursion keeps working.

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

if [[ -f /etc/bind/named.conf.options ]]; then
  cp -a /etc/bind/named.conf.options /etc/bind/named.conf.options.before-D1-T10 || true
fi
cat >/etc/bind/named.conf.options <<'EOF'
options {
    directory "/var/cache/bind";
    recursion yes;
    # D1 T10 FAULT: recursion allowed for DC only; HQ cross-site recursive queries fail.
    allow-recursion { 10.21.10.0/24; 127.0.0.1; };
    allow-query { any; };
    forwarders { 10.19.20.10; };
    forward only;
    listen-on { any; };
    dnssec-validation no;
};
EOF
named-checkconf
systemctl restart bind9 || service bind9 restart
echo "T10 fault applied on DC-LNX02: DNS recursion excludes HQ networks (10.19.0.0/16)."
