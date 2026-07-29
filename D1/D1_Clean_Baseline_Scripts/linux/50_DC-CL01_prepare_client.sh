#!/usr/bin/env bash
set -euo pipefail
apt-get update || true
apt-get install -y curl dnsutils smbclient ldap-utils netcat-openbsd || true
mkdir -p /opt/grading/d1
cat >/opt/grading/d1/client-baseline-check.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ip route
dig +short dc-lnx01.dc.d1.skills
curl -fsS http://dc-lnx01.dc.d1.skills/healthz
EOF
chmod +x /opt/grading/d1/client-baseline-check.sh
