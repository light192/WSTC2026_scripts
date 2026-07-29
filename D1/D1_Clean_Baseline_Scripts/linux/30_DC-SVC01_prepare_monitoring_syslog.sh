#!/usr/bin/env bash
set -euo pipefail
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
cat >/var/www/d1svc/index.html <<'EOF'
D1_SVC_OK
EOF
cat >/etc/nginx/sites-available/d1-svc <<'EOF'
server { listen 8080 default_server; root /var/www/d1svc; location /healthz { return 200 "OK\n"; } }
EOF
ln -sf /etc/nginx/sites-available/d1-svc /etc/nginx/sites-enabled/d1-svc
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable --now nginx
cat >/opt/d1-healthcheck.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '{"host":"DC-SVC01","nginx":"%s","rsyslog":"%s"}\n' "$(systemctl is-active nginx)" "$(systemctl is-active rsyslog)"
EOF
chmod +x /opt/d1-healthcheck.sh
