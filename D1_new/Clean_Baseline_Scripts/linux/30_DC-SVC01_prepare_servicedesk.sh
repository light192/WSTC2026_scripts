#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -eu
set -o pipefail 2>/dev/null || true
# D1 clean baseline: DC-SVC01 Service Desk / monitoring / app (PDF role: "Other services").
apt-get update || true
apt-get install -y rsyslog nginx netcat-openbsd jq curl || true
mkdir -p /var/log/remote /var/www/d1svc

cat >/etc/rsyslog.d/10-d1-receiver.conf <<'EOF'
module(load="imudp")
input(type="imudp" port="514")
module(load="imtcp")
input(type="imtcp" port="514")
template(name="D1Remote" type="string" string="/var/log/remote/%HOSTNAME%.log")
*.* ?D1Remote
& stop
EOF
systemctl restart rsyslog

mkdir -p /var/www/d1svc
cat >/var/www/d1svc/index.html <<'EOF'
D1_SERVICE_DESK_PAGE_OK
<form method="post" action="/submit"><button type="submit">Submit reply</button></form>
EOF

# Real backend behind /submit so the clean baseline actually works end to end;
# the Day 2 T07 fault script points /submit at a non-existing backend instead.
cat >/opt/d1svc-backend.py <<'EOF'
#!/usr/bin/env python3
import http.server
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.end_headers()
        self.wfile.write(b'D1_SUBMIT_OK\n')
    def log_message(self, *args):
        pass
http.server.HTTPServer(('127.0.0.1', 18080), Handler).serve_forever()
EOF
chmod +x /opt/d1svc-backend.py

cat >/etc/systemd/system/d1svc-backend.service <<'EOF'
[Unit]
Description=D1 Service Desk backend (submit handler)
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/d1svc-backend.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now d1svc-backend

cat >/etc/nginx/sites-available/d1-svc <<'EOF'
server {
    listen 8080 default_server;
    root /var/www/d1svc;
    location / { try_files $uri /index.html; }
    location /healthz { default_type text/plain; return 200 "OK\n"; }
    location /submit {
        proxy_pass http://127.0.0.1:18080/submit;
    }
}
EOF
ln -sf /etc/nginx/sites-available/d1-svc /etc/nginx/sites-enabled/d1-svc
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable --now nginx

cat >/opt/d1-healthcheck.sh <<'EOF'
#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -eu
set -o pipefail 2>/dev/null || true
printf '{"host":"DC-SVC01","nginx":"%s","rsyslog":"%s","backend":"%s"}\n' "$(systemctl is-active nginx)" "$(systemctl is-active rsyslog)" "$(systemctl is-active d1svc-backend)"
EOF
chmod +x /opt/d1-healthcheck.sh
