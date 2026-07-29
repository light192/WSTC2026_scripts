#!/usr/bin/env bash
set -euo pipefail
apt-get update || true
apt-get install -y bind9 bind9-utils dnsutils || true
cat >/etc/bind/named.conf.options <<'EOF'
options {
    directory "/var/cache/bind";
    recursion yes;
    allow-recursion { 10.19.0.0/16; 127.0.0.1; };
    listen-on { any; };
    dnssec-validation no;
};
EOF
cat >/etc/bind/named.conf.local <<'EOF'
zone "dc.d1.skills" { type master; file "/etc/bind/db.dc.d1.skills"; };
zone "cloud.d1.skills" { type master; file "/etc/bind/db.cloud.d1.skills"; };
EOF
cat >/etc/bind/db.dc.d1.skills <<'EOF'
$TTL 300
@ IN SOA dc-lnx02.dc.d1.skills. admin.d1.skills. (2026072001 300 120 604800 300)
@ IN NS dc-lnx02.dc.d1.skills.
dc-lnx01 IN A 10.19.110.11
dc-lnx02 IN A 10.19.110.12
dc-win01 IN A 10.19.110.21
dc-svc01 IN A 10.19.110.31
dc-cl01 IN A 10.19.120.11
portal IN CNAME dc-lnx01
svc IN CNAME dc-svc01
EOF
cat >/etc/bind/db.cloud.d1.skills <<'EOF'
$TTL 300
@ IN SOA dc-lnx02.dc.d1.skills. admin.d1.skills. (2026072001 300 120 604800 300)
@ IN NS dc-lnx02.dc.d1.skills.
cloud-service IN A 10.19.210.1
cloud-backup IN A 10.19.220.1
EOF
named-checkconf
named-checkzone dc.d1.skills /etc/bind/db.dc.d1.skills
named-checkzone cloud.d1.skills /etc/bind/db.cloud.d1.skills
systemctl enable --now bind9
