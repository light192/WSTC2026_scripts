#!/usr/bin/env bash
set -euo pipefail
# D1 clean baseline: DC-CL01 (PDF role: "DC test client").
apt-get update || true
apt-get install -y curl dnsutils smbclient ldap-utils netcat-openbsd || true
mkdir -p /opt/grading/d1
cat >/opt/grading/d1/client-baseline-check.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ip route
dig +short dc-lnx01.skill39.d1
curl -fsS http://dc-lnx01.skill39.d1/healthz
curl -fsS http://dc1.cloud.skill39.d1/
EOF
chmod +x /opt/grading/d1/client-baseline-check.sh
