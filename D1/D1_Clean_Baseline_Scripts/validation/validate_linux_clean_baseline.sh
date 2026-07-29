#!/usr/bin/env bash
set -u
set -o pipefail

echo '=== Проверка базовой конфигурации D1 для Linux ==='
hostnamectl || hostname
ip -br addr
ip route
cat /etc/resolv.conf
for h in hq-ad01.corp.d1.skills hq-file01.corp.d1.skills dc-lnx01.dc.d1.skills dc-lnx02.dc.d1.skills dc-svc01.dc.d1.skills cloud-service.cloud.d1.skills; do
  echo "--- DNS $h"
  getent hosts "$h" || dig +short "$h"
done
for u in http://dc-lnx01.dc.d1.skills/healthz http://dc-svc01.dc.d1.skills:8080/healthz http://hq-file01.corp.d1.skills/; do
  echo "--- CURL $u"
  curl -m 3 -fsS "$u" || true
  echo
done
ping -c 2 10.19.110.1 || true
ping -c 2 10.19.210.1 || true
