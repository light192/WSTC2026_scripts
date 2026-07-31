#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -eu
set -o pipefail 2>/dev/null || true
# T07: Service Desk page opens, but submitting a reply fails.
# Clean baseline has a working backend on 127.0.0.1:18080 behind /submit
# (see 30_DC-SVC01_prepare_servicedesk.sh); this fault repoints /submit at a
# port nothing listens on, without touching the working page itself.

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Run as root" >&2
  exit 1
fi

CONF=/etc/nginx/sites-available/d1-svc
if [ ! -f "$CONF" ]; then
  echo "Expected $CONF from the clean baseline was not found." >&2
  exit 1
fi
cp -a "$CONF" "${CONF}.before-D1-T07"

cat >"$CONF" <<'EOF'
server {
    listen 8080 default_server;
    root /var/www/d1svc;
    location / { try_files $uri /index.html; }
    location /healthz { default_type text/plain; return 200 "OK\n"; }
    # D1 T07 FAULT: submit backend points to a non-existing local port.
    location /submit {
        proxy_connect_timeout 1s;
        proxy_read_timeout 1s;
        proxy_pass http://127.0.0.1:19999/submit;
    }
}
EOF
nginx -t
systemctl restart nginx
echo "T07 fault applied on DC-SVC01: page works on 8080, /submit now proxies to a dead backend port (19999)."
