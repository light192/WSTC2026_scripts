#!/usr/bin/env bash
set -euo pipefail
# G08: Service Desk opens from DC but is intermittently unreachable from HQ.
# Fault: random-drop firewall rules for HQ sources to Service Desk TCP/8080.

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

apt-get update || true
apt-get install -y iptables || true
# Remove old copies to keep script idempotent.
while iptables -C INPUT -s 10.19.10.0/24 -p tcp --dport 8080 -m statistic --mode random --probability 0.45 -j DROP 2>/dev/null; do iptables -D INPUT -s 10.19.10.0/24 -p tcp --dport 8080 -m statistic --mode random --probability 0.45 -j DROP; done
while iptables -C INPUT -s 10.19.20.0/24 -p tcp --dport 8080 -m statistic --mode random --probability 0.45 -j DROP 2>/dev/null; do iptables -D INPUT -s 10.19.20.0/24 -p tcp --dport 8080 -m statistic --mode random --probability 0.45 -j DROP; done
while iptables -C INPUT -s 10.19.99.0/24 -p tcp --dport 8080 -m statistic --mode random --probability 0.45 -j DROP 2>/dev/null; do iptables -D INPUT -s 10.19.99.0/24 -p tcp --dport 8080 -m statistic --mode random --probability 0.45 -j DROP; done
iptables -I INPUT 1 -s 10.19.10.0/24 -p tcp --dport 8080 -m statistic --mode random --probability 0.45 -j DROP
iptables -I INPUT 1 -s 10.19.20.0/24 -p tcp --dport 8080 -m statistic --mode random --probability 0.45 -j DROP
iptables -I INPUT 1 -s 10.19.99.0/24 -p tcp --dport 8080 -m statistic --mode random --probability 0.45 -j DROP
systemctl restart nginx || true
echo "G08 fault applied on DC-SVC01: intermittent drops for HQ sources to TCP/8080."
