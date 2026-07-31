#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -eu
set -o pipefail 2>/dev/null || true
# D1 clean baseline: HQ-LNX01 (PDF role: "Linux web/SSH/syslog client").
# Common prep already installs/enables sshd and rsyslog; this script adds the
# syslog forwarding to DC-SVC01 and the web/monitoring checks used by T09.
apt-get update || true
apt-get install -y rsyslog curl netcat-openbsd || true

cat >/etc/rsyslog.d/20-d1-forward.conf <<'EOF'
*.* @@dc-svc01.skill39.d1:514
EOF
systemctl restart rsyslog

mkdir -p /opt/d1-monitor
cat >/opt/d1-monitor/check-dc-svc01.sh <<'EOF'
#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -eu
set -o pipefail 2>/dev/null || true
curl -fsS http://dc-svc01.skill39.d1:8080/healthz
EOF
chmod +x /opt/d1-monitor/check-dc-svc01.sh

cat >/opt/d1-monitor/check-dc-portal.sh <<'EOF'
#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -eu
set -o pipefail 2>/dev/null || true
curl -fsS http://dc-lnx01.skill39.d1/healthz
EOF
chmod +x /opt/d1-monitor/check-dc-portal.sh
