#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -u
set -o pipefail 2>/dev/null || true

echo '=== D1 clean-baseline check (Linux) ==='
hostnamectl || hostname
ip -br addr
ip route
cat /etc/resolv.conf
for h in hq-ad01.skill39.d1 hq-file01.skill39.d1 dc-lnx01.skill39.d1 dc-lnx02.skill39.d1 dc-svc01.skill39.d1 dc1.cloud.skill39.d1 dc2.cloud.skill39.d1; do
  echo "--- DNS $h"
  getent hosts "$h" || dig +short "$h"
done
for u in http://dc-lnx01.skill39.d1/healthz http://dc-svc01.skill39.d1:8080/healthz; do
  echo "--- CURL $u"
  curl -m 3 -fsS "$u" || true
  echo
done
ping -c 2 10.21.10.1 || true
ping -c 2 10.201.1.1 || true
