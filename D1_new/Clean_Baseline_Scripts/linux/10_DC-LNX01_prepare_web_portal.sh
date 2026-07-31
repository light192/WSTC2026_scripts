#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -eu
set -o pipefail 2>/dev/null || true
# D1 clean baseline: DC-LNX01 intranet web service (PDF role: "intranet web service").
apt-get update || true
apt-get install -y nginx curl || true
mkdir -p /var/www/d1
cat >/var/www/d1/index.html <<'EOF'
D1_DC_PORTAL_OK
EOF
cat >/var/www/d1/healthz <<'EOF'
OK
EOF
cat >/etc/nginx/sites-available/d1-portal <<'EOF'
server {
    listen 80 default_server;
    server_name dc-lnx01.skill39.d1;
    root /var/www/d1;
    location / { try_files $uri /index.html; }
    location = /healthz { default_type text/plain; return 200 "OK\n"; }
}
EOF
ln -sf /etc/nginx/sites-available/d1-portal /etc/nginx/sites-enabled/d1-portal
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable --now nginx
