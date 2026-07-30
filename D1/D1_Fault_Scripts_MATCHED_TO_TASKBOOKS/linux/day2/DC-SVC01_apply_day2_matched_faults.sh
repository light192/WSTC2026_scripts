#!/usr/bin/env bash
set -euo pipefail
# T07: Service Desk page opens, but submitting a reply fails.

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

apt-get update || true
apt-get install -y nginx curl || true
mkdir -p /var/www/d1svc
cat >/var/www/d1svc/index.html <<'EOF'
D1_SERVICE_DESK_PAGE_OK
<form method="post" action="/submit"><button type="submit">Submit reply</button></form>
EOF
cat >/etc/nginx/sites-available/d1-svc <<'EOF'
server {
    listen 8080 default_server;
    root /var/www/d1svc;
    location / { try_files $uri /index.html; }
    location /healthz { default_type text/plain; return 200 "OK
"; }
    # D1 T07 FAULT: submit backend points to a non-existing local backend.
    location /submit {
        proxy_connect_timeout 1s;
        proxy_read_timeout 1s;
        proxy_pass http://127.0.0.1:18080/submit;
    }
}
EOF
ln -sf /etc/nginx/sites-available/d1-svc /etc/nginx/sites-enabled/d1-svc
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl restart nginx
echo "T07 fault applied on DC-SVC01: page works on 8080, /submit returns backend error."
