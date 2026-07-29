#!/usr/bin/env bash
set -euo pipefail
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
    server_name dc-lnx01.dc.d1.skills portal.dc.d1.skills;
    root /var/www/d1;
    location / { try_files $uri /index.html; }
    location = /healthz { default_type text/plain; return 200 "OK\n"; }
}
EOF
ln -sf /etc/nginx/sites-available/d1-portal /etc/nginx/sites-enabled/d1-portal
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable --now nginx
