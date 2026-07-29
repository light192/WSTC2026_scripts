#!/usr/bin/env bash
set -euo pipefail
apt-get update || true
apt-get install -y rsync curl netcat-openbsd rsyslog || true
mkdir -p /opt/d1-backup /var/log/d1
cat >/opt/d1-backup/run-backup-check.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
TS=$(date +%Y%m%d-%H%M%S)
mkdir -p /opt/d1-backup/$TS
curl -fsS http://dc-lnx01.dc.d1.skills/healthz > /opt/d1-backup/$TS/dc-portal-health.txt || true
dig +short dc-lnx01.dc.d1.skills > /opt/d1-backup/$TS/dns.txt || true
echo "D1_BACKUP_CHECK_DONE $TS"
EOF
chmod +x /opt/d1-backup/run-backup-check.sh
