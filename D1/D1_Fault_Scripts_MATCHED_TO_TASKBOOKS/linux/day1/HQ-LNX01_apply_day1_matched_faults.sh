#!/usr/bin/env bash
set -euo pipefail
# G03: HQ-LNX01 logs do not appear on DC-SVC01.
# Fault: rsyslog forwards to a wrong port/destination.

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

apt-get update || true
apt-get install -y rsyslog || true
cat >/etc/rsyslog.d/60-d1-remote.conf <<'EOF'
# D1 G03 FAULT: wrong remote syslog destination/port.
# Correct baseline should send to DC-SVC01 on UDP/TCP 514.
*.* @@10.19.110.31:1514
EOF
systemctl restart rsyslog || service rsyslog restart || true
logger -t D1-G03-FAULT "D1 G03 test log after faulty rsyslog config"
echo "G03 fault applied on HQ-LNX01: rsyslog forwarding points to 10.19.110.31:1514 instead of port 514."
