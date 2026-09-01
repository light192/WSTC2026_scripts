#!/usr/bin/env bash
# A6 remote evaluator. Recommended launch point: ops-a6 (10.76.20.100).

set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/a6-common.sh"

A6_HOSTS_FILE="${A6_HOSTS_FILE:-$SCRIPT_DIR/a6-hosts.conf}"
A6_START_FROM="${A6_START_FROM:-A1.01}"
A6_DISRUPTIVE="${A6_DISRUPTIVE:-0}"
A6_LAST_RC=0
A6_LAST_OUT=""

usage() {
  cat <<'EOF'
Usage: sudo bash remote/a6-evaluate-remote.sh [options]
  --no-pause              do not pause after each aspect
  --pause                 pause after each aspect (default)
  --start-from C1.04      resume from an aspect
  --report-dir DIR        report output directory
  --disruptive            include controlled stop/restart/down/up checks
  --hosts-file FILE       override host map
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --no-pause) A6_PAUSE=0 ;;
    --pause) A6_PAUSE=1 ;;
    --disruptive) A6_DISRUPTIVE=1 ;;
    --start-from) shift; A6_START_FROM="${1:?missing --start-from value}" ;;
    --report-dir) shift; A6_REPORT_DIR="${1:?missing --report-dir value}" ;;
    --hosts-file) shift; A6_HOSTS_FILE="${1:?missing --hosts-file value}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

A6_RESULTS_TSV="$A6_REPORT_DIR/a6-results.tsv"
A6_DETAIL_LOG="$A6_REPORT_DIR/a6-detail.log"
mkdir -p "$A6_REPORT_DIR"
printf 'CriterionID\tMaxMark\tStatus\tMessage\n' > "$A6_RESULTS_TSV"
: > "$A6_DETAIL_LOG"

manual_commands_for() { printf '%s\n' "$2"; }

ssh_precheck() {
  section "Preliminary root SSH check from ops-a6"
  local name ip out
  while IFS='=' read -r name ip; do
    [[ "$name" =~ ^[[:space:]]*# ]] && continue
    [ -n "$name" ] || continue
    printf '%-16s %-15s ' "$name" "$ip"
    out="$(timeout "$A6_TIMEOUT" ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout="$A6_TIMEOUT" \
      root@"$ip" 'hostname -s' 2>&1)"
    [ "$out" = "$name" ] && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}NO ACCESS${NC}: $out"
  done < "$A6_HOSTS_FILE"
}

run_command() {
  local command="$1" tmp out_file
  tmp="$(mktemp)"; out_file="$(mktemp)"
  {
    cat <<EOF
#!/usr/bin/env bash
set -o pipefail
ssh() {
  local target="\${1:-unknown}" label
  case "\$target" in
    *@10.76.10.1) label='sh-edge-a6 (10.76.10.1)' ;;
    *@10.76.10.100) label='sh-user-a6 (10.76.10.100)' ;;
    *@10.76.20.1) label='sz-edge-a6 (10.76.20.1)' ;;
    *@10.76.20.100) label='ops-a6 (10.76.20.100)' ;;
    *@10.76.30.10) label='services-a6 (10.76.30.10)' ;;
    *@10.76.40.10) label='directory-a6 (10.76.40.10)' ;;
    *@10.76.40.20) label='network-a6 (10.76.40.20)' ;;
    *) label="\$target" ;;
  esac
  printf '\n[DEVICE: %s]\n' "\$label" >&2
  command timeout "${A6_TIMEOUT}s" /usr/bin/ssh \
    -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o ConnectTimeout="${A6_TIMEOUT}" -o ConnectionAttempts=1 \
    -o GSSAPIAuthentication=no "\$@"
}
EOF
    printf '%s\n' "$command"
  } > "$tmp"
  chmod 700 "$tmp"
  divider; echo -e "${BLUE}Full actual output (stdout/stderr):${NC}"
  echo -e "${BLUE}[COORDINATOR: $(hostname -s 2>/dev/null || hostname)]${NC}"
  timeout "$A6_CMD_TIMEOUT" bash "$tmp" </dev/null 2>&1 | tee -a "$A6_DETAIL_LOG" "$out_file"
  A6_LAST_RC="${PIPESTATUS[0]}"; A6_LAST_OUT="$(cat "$out_file")"
  [ -s "$out_file" ] || echo "(empty output)"
  rm -f "$tmp" "$out_file"
}

# Each automatic command prints A6_OK only after its complete aspect passes.
# Commands intentionally use IP addresses for transport and FQDNs only where DNS/TLS is assessed.
command_for() {
  case "$1" in
    A1.01) echo "for x in '10.76.10.1 sh-edge-a6' '10.76.10.100 sh-user-a6' '10.76.20.1 sz-edge-a6' '10.76.20.100 ops-a6' '10.76.30.10 services-a6' '10.76.40.10 directory-a6' '10.76.40.20 network-a6'; do set -- \$x; [ \"\$(ssh root@\$1 hostname -s)\" = \"\$2\" ] || exit 1; done; echo A6_OK" ;;
    A1.02) echo "for x in '10.76.10.1|10.76.10.1|198.18.76.10|' '10.76.20.1|198.18.76.20|10.76.20.1|10.76.30.1|10.76.40.1|' '10.76.30.10|10.76.30.10|default via 10.76.30.1|' '10.76.40.10|10.76.40.10|default via 10.76.40.1|' '10.76.40.20|10.76.40.20|default via 10.76.40.1|'; do IFS='|' read -r ip n1 n2 n3 n4 <<<\"\$x\"; o=\$(ssh root@\$ip 'ip -br -4 a; ip route'); for n in \"\$n1\" \"\$n2\" \"\$n3\" \"\$n4\"; do [ -z \"\$n\" ] || grep -Fq \"\$n\" <<<\"\$o\" || exit 1; done; done; while read -r h values; do p=\$(ssh root@\$h 'grep -RhEv \"^[[:space:]]*(#|\$)\" /etc/network/interfaces /etc/network/interfaces.d /etc/systemd/network /etc/NetworkManager/system-connections 2>/dev/null'); for v in \$values; do grep -Fq \$v <<<\"\$p\" || exit 1; done; done <<'EOF'
10.76.10.1 10.76.10.1 198.18.76.10
10.76.20.1 198.18.76.20 10.76.20.1 10.76.30.1 10.76.40.1
10.76.30.10 10.76.30.10 10.76.30.1
10.76.40.10 10.76.40.10 10.76.40.1
10.76.40.20 10.76.40.20 10.76.40.1
EOF
echo A6_OK" ;;
    A1.03) echo "for h in 10.76.10.100 10.76.20.100; do ssh root@\$h 'ip -4 -br a | grep -qE \"10\\.76\\.(10|20)\\.100/24\" && { nmcli -t -f ipv4.method con show 2>/dev/null | grep -qi auto || grep -RqiE \"^[[:space:]]*(iface .* inet dhcp|DHCP[[:space:]]*=[[:space:]]*(yes|ipv4|true))\" /etc/network/interfaces /etc/network/interfaces.d /etc/systemd/network 2>/dev/null; }' || exit 1; done; echo A6_OK" ;;
    A1.04) echo "for h in 10.76.10.1 10.76.20.1; do ssh root@\$h 'test \"\$(sysctl -n net.ipv4.ip_forward)\" = 1 && grep -RqsE \"net.ipv4.ip_forward[[:space:]]*=[[:space:]]*1\" /etc/sysctl.conf /etc/sysctl.d' || exit 1; done; ssh root@10.76.10.1 'for d in 10.76.20.10 10.76.30.10 10.76.40.20; do ip route get \$d | grep -q wg0 || exit 1; done' && ssh root@10.76.20.1 'ip route get 10.76.10.100 | grep -q wg0' && echo A6_OK" ;;
    A1.05) echo "a=\$(ssh root@10.76.10.1 'ip -4 a show wg0; wg show wg0'); b=\$(ssh root@10.76.20.1 'ip -4 a show wg0; wg show wg0'); aip=\$(sed -n 's/.*allowed ips: //p' <<<\"\$a\" | tr ',' '\\n' | xargs -n1 | sort | tr '\\n' ' '); bip=\$(sed -n 's/.*allowed ips: //p' <<<\"\$b\" | tr ',' '\\n' | xargs -n1 | sort | tr '\\n' ' '); grep -q '10.200.6.1/30' <<<\"\$a\" && grep -q 'listening port: 51820' <<<\"\$a\" && grep -q 'endpoint: 198.18.76.20:51820' <<<\"\$a\" && [ \"\$aip\" = '10.76.20.0/24 10.76.30.0/24 10.76.40.0/24 ' ] && grep -q '10.200.6.2/30' <<<\"\$b\" && grep -q 'listening port: 51820' <<<\"\$b\" && grep -q 'endpoint: 198.18.76.10:51820' <<<\"\$b\" && [ \"\$bip\" = '10.76.10.0/24 ' ] && echo A6_OK" ;;
    A1.06) echo "ssh root@10.76.10.1 'ping -c1 -W2 10.200.6.2 >/dev/null && hs=\$(wg show wg0 latest-handshakes | awk \"{print \\$2}\") && test \"\$hs\" -gt 0 && test \$((\$(date +%s)-hs)) -le 120 && systemctl is-active --quiet wg-quick@wg0 && systemctl is-enabled --quiet wg-quick@wg0' && ssh root@10.76.20.1 'systemctl is-active --quiet wg-quick@wg0 && systemctl is-enabled --quiet wg-quick@wg0' && echo A6_OK" ;;
    A1.07) echo "ssh root@10.76.10.1 'ip route get 10.76.30.10 | grep -q wg0 && ip route get 10.76.40.20 | grep -q wg0 && ip route get 198.18.76.20 | grep -vq wg0' && echo A6_OK" ;;
    A1.08) echo "ssh root@10.76.40.20 'kea-dhcp4 -t /etc/kea/kea-dhcp4.conf >/dev/null && python3 -c \"import json,re; t=open(\\\"/etc/kea/kea-dhcp4.conf\\\").read(); t=re.sub(r\\\"/[*].*?[*]/\\\",\\\"\\\",t,flags=re.S); t=re.sub(r\\\"(?m)//.*$\\\",\\\"\\\",t); t=re.sub(r\\\",(\\\\s*[}\\\\]])\\\",r\\\"\\\\1\\\",t); c=json.loads(t)[\\\"Dhcp4\\\"]; s={x[\\\"subnet\\\"]:x for x in c[\\\"subnet4\\\"]}; a=s[\\\"10.76.10.0/24\\\"]; b=s[\\\"10.76.20.0/24\\\"]; assert a[\\\"pools\\\"][0][\\\"pool\\\"].replace(\\\" \\\",\\\"\\\")==\\\"10.76.10.110-10.76.10.149\\\"; assert b[\\\"pools\\\"][0][\\\"pool\\\"].replace(\\\" \\\",\\\"\\\")==\\\"10.76.20.110-10.76.20.149\\\"; assert any(r.get(\\\"ip-address\\\")==\\\"10.76.10.100\\\" and r.get(\\\"hw-address\\\") for r in a[\\\"reservations\\\"]); assert any(r.get(\\\"ip-address\\\")==\\\"10.76.20.100\\\" and r.get(\\\"hw-address\\\") for r in b[\\\"reservations\\\"]); opts=lambda x:{o[\\\"name\\\"]:o[\\\"data\\\"] for o in x[\\\"option-data\\\"]}; assert opts(a)[\\\"routers\\\"]==\\\"10.76.10.1\\\" and opts(b)[\\\"routers\\\"]==\\\"10.76.20.1\\\"; assert all(\\\"10.76.40.10\\\" in opts(x)[\\\"domain-name-servers\\\"] and \\\"10.76.40.20\\\" in opts(x)[\\\"domain-name-servers\\\"] and opts(x)[\\\"domain-name\\\"]==\\\"nova.a6.test\\\" for x in (a,b))\"' && echo A6_OK" ;;
    A1.09) echo "ssh root@10.76.40.20 'systemctl restart kea-dhcp4-server && systemctl is-active --quiet kea-dhcp4-server' && for h in 10.76.10.1 10.76.20.1; do ssh root@\$h 'pgrep -fa dhcrelay | grep -q 10.76.40.20' || exit 1; done; ssh root@10.76.10.1 'ip route get 10.76.40.20 | grep -q wg0' || exit 1; for x in '10.76.10.100 10.76.10.100 10.76.10.1' '10.76.20.100 10.76.20.100 10.76.20.1'; do set -- \$x; h=\$1; addr=\$2; gw=\$3; ssh root@\$h 'if command -v dhclient >/dev/null; then i=\$(ip route show default | awk \"NR==1{print \\$5}\"); dhclient -1 -v \"\$i\"; elif command -v nmcli >/dev/null; then nmcli device reapply \"\$(ip route show default | awk \"NR==1{print \\$5}\")\"; else networkctl renew \"\$(ip route show default | awk \"NR==1{print \\$5}\")\"; fi' || exit 1; o=\$(ssh root@\$h 'ip -4 -br a; ip route; resolvectl status 2>/dev/null || cat /etc/resolv.conf'); for n in \$addr \$gw 10.76.40.10 10.76.40.20 nova.a6.test; do grep -Fq \$n <<<\"\$o\" || exit 1; done; done; echo A6_OK" ;;
    B1.01) echo "ssh root@10.76.40.10 'dig @127.0.0.1 nova.a6.test SOA +norecurse | grep -q \"flags:.* aa\"' || exit 1; check(){ got=\$(ssh root@10.76.40.10 \"dig @127.0.0.1 +short \$1.nova.a6.test A\" | tr -d '\\r'); [ \"\$got\" = \"\$2\" ]; }; while read -r n ip; do check \$n \$ip || { echo \"wrong A record: \$n -> \$(ssh root@10.76.40.10 \"dig @127.0.0.1 +short \$n.nova.a6.test A\")\"; exit 1; }; done <<'EOF'
ldap 10.76.40.10
dns1 10.76.40.10
dns2 10.76.40.20
files 10.76.30.10
portal 10.76.30.10
mail 10.76.30.10
monitor 10.76.20.100
portal-public 198.18.76.20
mail-public 198.18.76.20
sh-edge-a6 10.76.10.1
sh-user-a6 10.76.10.100
sz-edge-a6 10.76.20.1
ops-a6 10.76.20.100
services-a6 10.76.30.10
directory-a6 10.76.40.10
network-a6 10.76.40.20
EOF
mx=\$(ssh root@10.76.40.10 'dig @127.0.0.1 +short nova.a6.test MX'); srv=\$(ssh root@10.76.40.10 'dig @127.0.0.1 +short _ldap._tcp.nova.a6.test SRV'); grep -q 'mail.nova.a6.test.' <<<\"\$mx\" && grep -qE '[[:space:]]389[[:space:]]+ldap.nova.a6.test.\$' <<<\"\$srv\" && echo A6_OK" ;;
    B1.02) echo "a=\$(ssh root@10.76.40.10 'dig @127.0.0.1 nova.a6.test SOA +short' | awk '{print \$3}'); b=\$(ssh root@10.76.40.20 'dig @127.0.0.1 nova.a6.test SOA +short' | awk '{print \$3}'); auth=\$(ssh root@10.76.40.20 'dig @127.0.0.1 nova.a6.test SOA +norecurse'); [ -n \"\$a\" ] && [ \"\$a\" = \"\$b\" ] && grep -q 'flags:.* aa' <<<\"\$auth\" && ! grep -qiE 'SERVFAIL|REFUSED' <<<\"\$auth\" && echo A6_OK" ;;
    B1.03) echo "while read -r ip name; do got=\$(ssh root@10.76.40.10 \"dig @127.0.0.1 -x \$ip +short\" | tr -d '\\r'); [ \"\$got\" = \"\$name.nova.a6.test.\" ] || exit 1; done <<'EOF'
10.76.10.100 sh-user-a6
10.76.20.100 ops-a6
10.76.30.10 services-a6
10.76.40.10 directory-a6
10.76.40.20 network-a6
EOF
echo A6_OK" ;;
    B1.04) echo "ssh root@10.76.40.20 'dig @10.76.40.10 nova.a6.test AXFR | grep -q services-a6' || exit 1; o=\$(ssh root@10.76.10.100 'dig @10.76.40.10 nova.a6.test AXFR +time=3 +tries=1 2>&1') || true; [ -n \"\$o\" ] && ! grep -q services-a6 <<<\"\$o\" && grep -qiE 'REFUSED|Transfer failed|denied' <<<\"\$o\" && echo A6_OK" ;;
    B1.05) echo "ssh root@10.76.20.100 'dig @10.76.40.10 portal.nova.a6.test A | grep -qE \"status: (NOERROR|NXDOMAIN)\"' && ssh root@10.76.20.1 'dig -b 198.18.76.20 @10.76.40.10 example.invalid A +time=2 +tries=1 | grep -q REFUSED' && echo A6_OK" ;;
    B1.06) echo "for h in 10.76.10.100 10.76.20.100; do o=\$(ssh root@\$h 'resolvectl status 2>/dev/null || cat /etc/resolv.conf'); for n in 10.76.40.10 10.76.40.20 nova.a6.test; do grep -Fq \$n <<<\"\$o\" || exit 1; done; done; echo A6_OK" ;;
    B1.07) echo "[ \"$A6_DISRUPTIVE\" = 1 ] || exit 3; cleanup(){ ssh root@10.76.40.10 'systemctl start bind9' >/dev/null 2>&1 || true; }; trap cleanup EXIT INT TERM; ssh root@10.76.40.10 'systemctl stop bind9' && ssh root@10.76.10.100 'getent hosts portal.nova.a6.test' && cleanup && trap - EXIT INT TERM && echo A6_OK" ;;
    C1.01) echo "ssh root@10.76.40.10 'for ou in People Groups Services; do ldapsearch -x -LLL -H ldap://127.0.0.1 -s base -b \"ou=\$ou,dc=nova,dc=a6,dc=test\" dn | grep -qi \"dn: ou=\$ou\" || exit 1; done; m=\$(ldapsearch -x -LLL -H ldap://127.0.0.1 -b dc=nova,dc=a6,dc=test \"(uid=maya)\" uid uidNumber gidNumber); t=\$(ldapsearch -x -LLL -H ldap://127.0.0.1 -b dc=nova,dc=a6,dc=test \"(uid=timur)\" uid uidNumber gidNumber); l=\$(ldapsearch -x -LLL -H ldap://127.0.0.1 -b dc=nova,dc=a6,dc=test \"(cn=linuxusers)\" cn gidNumber member memberUid); f=\$(ldapsearch -x -LLL -H ldap://127.0.0.1 -b dc=nova,dc=a6,dc=test \"(cn=filewriters)\" cn gidNumber member memberUid); w=\$(ldapsearch -x -LLL -H ldap://127.0.0.1 -b dc=nova,dc=a6,dc=test \"(cn=webadmins)\" cn gidNumber member memberUid); grep -q \"uidNumber: 8601\" <<<\"\$m\" && grep -q \"gidNumber: 7600\" <<<\"\$m\" && grep -q \"uidNumber: 8602\" <<<\"\$t\" && grep -q \"gidNumber: 7600\" <<<\"\$t\" && grep -q \"gidNumber: 7600\" <<<\"\$l\" && grep -qi maya <<<\"\$l\" && grep -qi timur <<<\"\$l\" && grep -q \"gidNumber: 7601\" <<<\"\$f\" && grep -qi maya <<<\"\$f\" && ! grep -qi timur <<<\"\$f\" && grep -q \"gidNumber: 7610\" <<<\"\$w\" && grep -qi maya <<<\"\$w\" && ! grep -qi timur <<<\"\$w\"' && echo A6_OK" ;;
    C1.02) echo "ssh root@10.76.40.10 'ldapsearch -x -LLL -H ldap://127.0.0.1 -D uid=ldap-reader,ou=Services,dc=nova,dc=a6,dc=test -w Reader39@A6 -b ou=People,dc=nova,dc=a6,dc=test uid=maya uid uidNumber | grep -q \"uidNumber: 8601\" && ldapsearch -x -LLL -H ldap://127.0.0.1 -D uid=ldap-reader,ou=Services,dc=nova,dc=a6,dc=test -w Reader39@A6 -b ou=Groups,dc=nova,dc=a6,dc=test cn=linuxusers cn gidNumber | grep -q \"gidNumber: 7600\"' && echo A6_OK" ;;
    C1.03) echo "ssh root@10.76.40.10 'marker=A6-ACL-TEST-\$\$; cleanup(){ ldapmodify -x -H ldap://127.0.0.1 -D uid=ldap-reader,ou=Services,dc=nova,dc=a6,dc=test -w Reader39@A6 >/dev/null 2>&1 <<EOF || true
dn: uid=maya,ou=People,dc=nova,dc=a6,dc=test
changetype: modify
delete: description
description: \$marker
EOF
}; trap cleanup EXIT INT TERM; if ldapmodify -x -H ldap://127.0.0.1 -D uid=ldap-reader,ou=Services,dc=nova,dc=a6,dc=test -w Reader39@A6 >/tmp/a6-ldap-write-test.log 2>&1 <<EOF
dn: uid=maya,ou=People,dc=nova,dc=a6,dc=test
changetype: modify
add: description
description: \$marker
EOF
then cleanup; trap - EXIT INT TERM; exit 1; else grep -qiE \"insufficient|denied|no write\" /tmp/a6-ldap-write-test.log; rc=\$?; rm -f /tmp/a6-ldap-write-test.log; trap - EXIT INT TERM; exit \$rc; fi' && echo A6_OK" ;;
    C1.04) echo "ssh root@10.76.40.10 'ldapsearch -x -LLL -H ldap://127.0.0.1 -s base -b \"\" namingContexts | grep -q namingContexts && ! ldapsearch -x -LLL -H ldap://127.0.0.1 -b ou=People,dc=nova,dc=a6,dc=test uid=maya userPassword | grep -q \"^dn:\"' && echo A6_OK" ;;
    C1.05) echo "ssh root@10.76.40.10 'openssl s_client -starttls ldap -connect ldap.nova.a6.test:389 -servername ldap.nova.a6.test -verify_hostname ldap.nova.a6.test -verify_return_error </dev/null 2>&1 | grep -q \"Verify return code: 0\"' && echo A6_OK" ;;
    C1.06) echo "for h in 10.76.10.100 10.76.20.100 10.76.30.10; do ssh root@\$h 'getent passwd maya | grep -qE \"^[^:]+:[^:]*:8601:7600:\" && getent passwd timur | grep -qE \"^[^:]+:[^:]*:8602:7600:\" && getent group linuxusers | grep -qE \"^[^:]+:[^:]*:7600:\" && getent group filewriters | grep -qE \"^[^:]+:[^:]*:7601:\" && getent group webadmins | grep -qE \"^[^:]+:[^:]*:7610:\" && ! getent -s files passwd maya | grep -q . && ! getent -s files passwd timur | grep -q .' || exit 1; done; echo A6_OK" ;;
    C1.07) echo "ssh root@10.76.10.100 'command -v pamtester >/dev/null || exit 4; printf \"%s\\n\" Skill39@A6 | pamtester login maya authenticate' && echo A6_OK" ;;
    C1.08) echo "for h in 10.76.10.100 10.76.20.100 10.76.30.10; do o=\$(ssh root@\$h 'grep -RhiE \"ldap_uri|ldap_id_use_start_tls|ldap_tls_reqcert|TLS_REQCERT\" /etc/sssd /etc/ldap 2>/dev/null'); grep -qiE 'start_tls.*true|ldap://ldap.nova.a6.test' <<<\"\$o\" && ! grep -qiE 'reqcert.*never|insecure_skip_verify' <<<\"\$o\" || exit 1; done; echo A6_OK" ;;
    D1.01) echo "o=\$(ssh root@10.76.30.10 'exportfs -v; testparm -s 2>/dev/null'); [ \$(grep -Fc /srv/files/team <<<\"\$o\") -ge 2 ] && echo A6_OK" ;;
    D1.02) echo "ssh root@10.76.30.10 'o=\$(getfacl -cp /srv/files/team) && grep -qE \"^group:filewriters:rwx\" <<<\"\$o\" && grep -qE \"^group:linuxusers:r-x\" <<<\"\$o\" && grep -qE \"^default:group:filewriters:rwx\" <<<\"\$o\" && grep -qE \"^default:group:linuxusers:r-x\" <<<\"\$o\"' && echo A6_OK" ;;
    D1.03) echo "o=\$(ssh root@10.76.30.10 'exportfs -v'); grep -q /srv/files/team <<<\"\$o\" && grep -q root_squash <<<\"\$o\" && grep -q 10.76.10.0/24 <<<\"\$o\" && grep -q 10.76.20.0/24 <<<\"\$o\" && echo A6_OK" ;;
    D1.04) echo "ssh root@10.76.10.100 'm=\$(mktemp -d); cleanup(){ umount \"\$m\" >/dev/null 2>&1 || true; rmdir \"\$m\" >/dev/null 2>&1 || true; }; trap cleanup EXIT INT TERM; ip route get 10.76.30.10 | grep -q 10.76.10.1 || exit 1; mounted=0; for e in /team / /srv/files/team; do mount -t nfs4 \"files.nova.a6.test:\$e\" \"\$m\" 2>/dev/null && { mounted=1; break; }; done; test \$mounted -eq 1 && findmnt -T \"\$m\" -t nfs4 >/dev/null && ls -la \"\$m\" >/dev/null' && ssh root@10.76.10.1 'ip route get 10.76.30.10 | grep -q wg0' && echo A6_OK" ;;
    D1.05) echo "o=\$(ssh root@10.76.30.10 'testparm -s 2>/dev/null'); grep -qi '\[team\]' <<<\"\$o\" && grep -q /srv/files/team <<<\"\$o\" && grep -qiE 'guest ok = No|map to guest = Never' <<<\"\$o\" && grep -qi linuxusers <<<\"\$o\" && grep -qi filewriters <<<\"\$o\" && echo A6_OK" ;;
    D1.06) echo "for u in maya timur; do smbclient //files.nova.a6.test/team -U \"\$u%Skill39@A6\" -c ls >/dev/null || exit 1; done; ssh root@10.76.30.10 'getent passwd maya | grep -qE \"^[^:]+:[^:]*:8601:7600:\" && getent passwd timur | grep -qE \"^[^:]+:[^:]*:8602:7600:\"' && echo A6_OK" ;;
    D1.07) echo "ssh root@10.76.10.100 'set -e; m=\$(mktemp -d); n=a6-nfs-\$\$.txt; s=a6-smb-\$\$.txt; l=\$(mktemp); cleanup(){ smbclient //files.nova.a6.test/team -U \"maya%Skill39@A6\" -c \"del \$n; del \$s\" >/dev/null 2>&1 || true; umount \"\$m\" >/dev/null 2>&1 || true; rm -rf \"\$m\" \"\$l\"; }; trap cleanup EXIT INT TERM; export_used=; for e in /team / /srv/files/team; do mount -t nfs4 \"files.nova.a6.test:\$e\" \"\$m\" 2>/dev/null && { export_used=\$e; break; }; done; test -n \"\$export_used\"; team=\$m; if [ \"\$export_used\" = / ]; then found=\$(find \"\$m\" -maxdepth 3 -type d -name team | head -n1); [ -z \"\$found\" ] || team=\$found; fi; runuser -u maya -- sh -c \"printf nfs-visible > '\"\$team\"/\$n'\"; smbclient //files.nova.a6.test/team -U \"maya%Skill39@A6\" -c \"get \$n \$l\" >/dev/null; grep -qx nfs-visible \"\$l\"; printf smb-visible >\"\$l\"; smbclient //files.nova.a6.test/team -U \"maya%Skill39@A6\" -c \"put \$l \$s\" >/dev/null; grep -qx smb-visible \"\$team/\$s\"' && echo A6_OK" ;;
    D1.08) echo "ssh root@10.76.10.100 'set -e; m=\$(mktemp -d); n=a6-perm-\$\$.txt; l=\$(mktemp); cleanup(){ smbclient //files.nova.a6.test/team -U \"maya%Skill39@A6\" -c \"del \$n; del maya-\$n; del timur-\$n; del renamed-\$n\" >/dev/null 2>&1 || true; umount \"\$m\" >/dev/null 2>&1 || true; rm -rf \"\$m\" \"\$l\"; }; trap cleanup EXIT INT TERM; export_used=; for e in /team / /srv/files/team; do mount -t nfs4 \"files.nova.a6.test:\$e\" \"\$m\" 2>/dev/null && { export_used=\$e; break; }; done; test -n \"\$export_used\"; team=\$m; if [ \"\$export_used\" = / ]; then found=\$(find \"\$m\" -maxdepth 3 -type d -name team | head -n1); [ -z \"\$found\" ] || team=\$found; fi; runuser -u maya -- sh -c \"printf readable > '\"\$team\"/\$n' && printf changed >> '\"\$team\"/\$n' && mv '\"\$team\"/\$n' '\"\$team\"/renamed-\$n' && mv '\"\$team\"/renamed-\$n' '\"\$team\"/\$n' && touch '\"\$team\"/maya-\$n' && rm '\"\$team\"/maya-\$n'\"; runuser -u timur -- grep -q readable \"\$team/\$n\"; ! runuser -u timur -- sh -c \"echo bad >> '\"\$team\"/\$n'\"; ! runuser -u timur -- sh -c \"touch '\"\$team\"/timur-\$n'\"; ! runuser -u timur -- mv \"\$team/\$n\" \"\$team/renamed-\$n\"; ! runuser -u timur -- rm \"\$team/\$n\"; smbclient //files.nova.a6.test/team -U \"timur%Skill39@A6\" -c \"get \$n \$l\" >/dev/null; ! smbclient //files.nova.a6.test/team -U \"timur%Skill39@A6\" -c \"put \$l timur-\$n\" >/dev/null 2>&1; ! smbclient //files.nova.a6.test/team -U \"timur%Skill39@A6\" -c \"rename \$n renamed-\$n\" >/dev/null 2>&1; ! smbclient //files.nova.a6.test/team -U \"timur%Skill39@A6\" -c \"del \$n\" >/dev/null 2>&1; smbclient //files.nova.a6.test/team -U \"maya%Skill39@A6\" -c \"put \$l maya-\$n; del \$n; rename maya-\$n \$n; del \$n\" >/dev/null' && echo A6_OK" ;;
    E1.01) echo "curl --fail --silent --show-error https://portal.nova.a6.test/ | grep -q 'NOVA A6 SERVICES' && echo A6_OK" ;;
    E1.02) echo "openssl s_client -connect portal.nova.a6.test:443 -servername portal.nova.a6.test -verify_hostname portal.nova.a6.test -verify_return_error </dev/null 2>&1 | grep -q 'Verify return code: 0' && openssl s_client -connect portal.nova.a6.test:443 -servername portal.nova.a6.test </dev/null 2>/dev/null | openssl x509 -noout -ext subjectAltName | grep -q portal-public.nova.a6.test && echo A6_OK" ;;
    E1.03) echo "curl -sSI http://portal.nova.a6.test/ | grep -qiE '^location: https://portal.nova.a6.test' && echo A6_OK" ;;
    E1.04) echo "o=\$(ssh root@10.76.30.10 'apachectl -t >/dev/null && { apachectl -t -D DUMP_RUN_CFG 2>&1; grep -RhiE \"AuthLDAPURL|LDAPTrustedGlobalCert|LDAPVerifyServerCert|LDAPTrustedMode\" /etc/apache2; }') || exit 1; grep -qi AuthLDAPURL <<<\"\$o\" && grep -qiE 'LDAPTrustedMode[[:space:]]+TLS|AuthLDAPURL.*ldap://.*TLS' <<<\"\$o\" && ! grep -qi 'VerifyServerCert.*off' <<<\"\$o\" && echo A6_OK" ;;
    E1.05) echo "a=\$(curl -sk -o /dev/null -w '%{http_code}' https://portal.nova.a6.test/staff/); m=\$(curl -sk -u maya:Skill39@A6 -o /dev/null -w '%{http_code}' https://portal.nova.a6.test/staff/); t=\$(curl -sk -u timur:Skill39@A6 -o /dev/null -w '%{http_code}' https://portal.nova.a6.test/staff/); [ \"\$m\" = 200 ] && [[ \"\$a\" =~ ^(401|403)$ ]] && [[ \"\$t\" =~ ^(401|403)$ ]] && echo A6_OK" ;;
    E1.06) echo "ssh root@10.76.30.10 'systemctl is-active --quiet postfix dovecot && postconf -h mydestination | grep -q nova.a6.test && { doveconf -h mail_driver 2>/dev/null | grep -qi maildir || doveconf -n | grep -qi maildir; } && for p in 25 587 993; do ss -ltn | grep -qE \":\$p[[:space:]]\" || exit 1; done' && echo A6_OK" ;;
    E1.07) echo "printf 'EHLO test\r\nMAIL FROM:<maya@nova.a6.test>\r\nRCPT TO:<timur@nova.a6.test>\r\nQUIT\r\n' | nc -w4 mail.nova.a6.test 25 | tee /dev/stderr | grep -qE '^250 .*Recipient|^250 2\\.1\\.5' && echo A6_OK" ;;
    E1.08) echo "python3 -c 'import smtplib,ssl; s=smtplib.SMTP(\"mail.nova.a6.test\",587,timeout=8); s.ehlo(); assert s.has_extn(\"starttls\"); s.starttls(context=ssl.create_default_context()); s.ehlo(); assert s.has_extn(\"auth\"); s.mail(\"maya@nova.a6.test\"); code,_=s.rcpt(\"timur@nova.a6.test\"); assert code>=400; s.rset(); s.login(\"maya\",\"Skill39@A6\"); s.quit()' && echo A6_OK" ;;
    E1.09) echo "for u in maya timur; do curl --fail --silent --user \"\$u:Skill39@A6\" imaps://mail.nova.a6.test:993/INBOX >/dev/null || exit 1; done; echo A6_OK" ;;
    E1.10) echo "openssl s_client -connect mail.nova.a6.test:993 -servername mail.nova.a6.test -verify_hostname mail.nova.a6.test -verify_return_error </dev/null 2>&1 | grep -q 'Verify return code: 0' && openssl s_client -connect mail.nova.a6.test:993 -servername mail.nova.a6.test </dev/null 2>/dev/null | openssl x509 -noout -ext subjectAltName | grep -q mail-public.nova.a6.test && echo A6_OK" ;;
    E1.11) echo "python3 - <<'PY'
import email.message, imaplib, smtplib, ssl, time
host = 'mail.nova.a6.test'
ctx = ssl.create_default_context()
with smtplib.SMTP(host, 25, timeout=8) as s:
    s.ehlo(); s.mail('probe@nova.a6.test'); code, _ = s.rcpt('user@example.invalid'); assert code >= 400
msg = email.message.EmailMessage()
msg['From'] = 'maya@nova.a6.test'; msg['To'] = 'timur@nova.a6.test'; msg['Subject'] = 'A6-MAIL-TEST'
msg.set_content('A6 evaluator end-to-end test')
with smtplib.SMTP(host, 587, timeout=8) as s:
    s.ehlo(); s.starttls(context=ctx); s.ehlo(); s.login('maya', 'Skill39@A6')
    s.mail('maya@nova.a6.test'); code, _ = s.rcpt('user@example.invalid'); assert code >= 400
    s.rset(); s.send_message(msg)
found = False
for _ in range(6):
    with imaplib.IMAP4_SSL(host, 993, ssl_context=ctx, timeout=8) as i:
        i.login('timur', 'Skill39@A6'); i.select('INBOX'); status, data = i.search(None, 'SUBJECT', 'A6-MAIL-TEST')
        found = status == 'OK' and bool(data and data[0].split())
    if found: break
    time.sleep(2)
assert found
PY
rc=\$?; [ \$rc -eq 0 ] && echo A6_OK; exit \$rc" ;;
    F1.01) echo "for h in 10.76.10.1 10.76.20.1; do o=\$(ssh root@\$h 'systemctl is-active nftables; systemctl is-enabled nftables; nft -c -f /etc/nftables.conf >/dev/null && nft list ruleset') || exit 1; grep -qx active <<<\"\$o\" && grep -qx enabled <<<\"\$o\" && grep -qE 'hook input.*policy drop' <<<\"\$o\" && grep -qE 'hook forward.*policy drop' <<<\"\$o\" && grep -qE 'established.*related|related.*established' <<<\"\$o\" || exit 1; done; echo A6_OK" ;;
    F1.02) echo "ssh root@10.76.10.1 'ping -c1 -W2 10.200.6.2 >/dev/null && wg show wg0 latest-handshakes | grep -qv \" 0\$\"' && ssh root@10.76.10.100 '! nc -z -w2 198.18.76.20 53 && ! nc -z -w2 198.18.76.20 389 && ! dig @198.18.76.20 portal.nova.a6.test A +time=2 +tries=1 | grep -q \"status: NOERROR\"' && echo A6_OK" ;;
    F1.03) echo "for x in '10.76.40.10 53' '10.76.40.10 389' '10.76.30.10 443' '10.76.30.10 587'; do nc -z -w3 \$x || exit 1; done; o=\$(ssh root@10.76.20.1 'nft list ruleset') || exit 1; ! grep -qE '^[[:space:]]*accept[[:space:]]*(comment .*)?\$' <<<\"\$o\" && echo A6_OK" ;;
    F1.04) echo "ssh root@10.76.10.100 'for p in 445 2049; do nc -z -w3 10.76.30.10 \$p || exit 1; ! nc -z -w2 198.18.76.20 \$p || exit 1; done' && echo A6_OK" ;;
    F1.05) echo "for p in 3000 9090 9115; do nc -z -w3 10.76.20.100 \$p || exit 1; done; for h in 10.76.40.10 10.76.40.20 10.76.30.10; do nc -z -w3 \$h 9100 || exit 1; done; ssh root@10.76.10.100 'for p in 3000 9090 9100 9115; do ! nc -z -w2 198.18.76.20 \$p || exit 1; done' && echo A6_OK" ;;
    F1.06) echo "echo 'Exact two-site SNAT verification requires expert-selected permitted WAN listeners and coordinated captures; use the displayed procedure.'; exit 4" ;;
    F1.07) echo "tmp=\$(mktemp); cleanup(){ rm -f \"\$tmp\"; }; trap cleanup EXIT INT TERM; ssh root@10.76.30.10 'timeout 10 tcpdump -lnni any src 10.76.10.100 and tcp port 443 -c 1' >\"\$tmp\" 2>&1 & pid=\$!; sleep 1; ssh root@10.76.10.100 'curl -skf https://portal.nova.a6.test/ >/dev/null' || exit 1; wait \$pid || exit 1; grep -q '10.76.10.100' \"\$tmp\" && ! grep -qE '198.18.76.(10|20)' \"\$tmp\" && echo A6_OK" ;;
    F1.08) echo "ssh root@10.76.10.100 'curl -skf https://198.18.76.20:8443/ | grep -q \"NOVA A6 SERVICES\" && openssl s_client -starttls smtp -connect 198.18.76.20:2587 </dev/null 2>&1 | grep -q \"CONNECTED\" && openssl s_client -connect 198.18.76.20:2993 </dev/null 2>&1 | grep -q \"CONNECTED\"' || exit 1; o=\$(ssh root@10.76.20.1 'nft list ruleset'); for n in '8443.*10.76.30.10.*443' '2587.*10.76.30.10.*587' '2993.*10.76.30.10.*993'; do grep -Eq \"\$n\" <<<\"\$o\" || exit 1; done; ! grep -Ei 'dnat.*(:(53|389|445|2049|3000|9090|9100|9115)([^0-9]|\$))' <<<\"\$o\" && echo A6_OK" ;;
    G1.01) echo "cd /opt/a6-monitoring && docker image inspect a6-prometheus:local a6-grafana:local >/dev/null && o=\$(docker compose config); grep -q 'image: a6-prometheus:local' <<<\"\$o\" && grep -q 'image: a6-grafana:local' <<<\"\$o\" && ! grep -qE '^[[:space:]]*build:' <<<\"\$o\" && echo A6_OK" ;;
    G1.02) echo "cd /opt/a6-monitoring && [ \"\$(docker compose config --services | sort | tr '\n' ' ')\" = 'grafana prometheus ' ] && docker ps --format '{{.Names}}' | grep -qx a6-prometheus && docker ps --format '{{.Names}}' | grep -qx a6-grafana && echo A6_OK" ;;
    G1.03) echo "docker network inspect a6-monitoring >/dev/null && docker volume inspect a6-prometheus-data a6-grafana-data >/dev/null && for c in a6-prometheus a6-grafana; do [ \"\$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' \$c)\" = unless-stopped ] && docker inspect -f '{{json .NetworkSettings.Networks}}' \$c | grep -q a6-monitoring || exit 1; done; docker inspect -f '{{range .Mounts}}{{println .Name .Destination}}{{end}}' a6-prometheus | grep -q '^a6-prometheus-data ' && docker inspect -f '{{range .Mounts}}{{println .Name .Destination}}{{end}}' a6-grafana | grep -q '^a6-grafana-data ' && echo A6_OK" ;;
    G1.04) echo "for c in a6-prometheus a6-grafana; do o=\$(docker inspect -f '{{json .HostConfig.Dns}}' \$c); grep -q 10.76.40.10 <<<\"\$o\" && grep -q 10.76.40.20 <<<\"\$o\" && docker exec \$c getent hosts portal.nova.a6.test >/dev/null || exit 1; done; echo A6_OK" ;;
    G1.05) echo "for h in 10.76.40.10 10.76.40.20 10.76.30.10; do ssh root@\$h 'ok=0; for s in prometheus-node-exporter node_exporter; do systemctl is-active --quiet \$s 2>/dev/null && systemctl is-enabled --quiet \$s 2>/dev/null && ok=1; done; test \$ok -eq 1 && ss -ltn | grep -q :9100' || exit 1; done; echo A6_OK" ;;
    G1.06) echo "cfg=\$(curl -fsS http://127.0.0.1:9090/api/v1/status/config) && grep -q 'scrape_interval: 15s' <<<\"\$cfg\" || exit 1; for q in 'up' 'node_cpu_seconds_total' 'node_memory_MemAvailable_bytes' 'node_filesystem_size_bytes{mountpoint=\"/\"}' 'node_load1' 'node_boot_time_seconds'; do o=\$(curl -fsSG --data-urlencode \"query=\$q\" http://127.0.0.1:9090/api/v1/query) || exit 1; for h in directory-a6 network-a6 services-a6; do grep -q \$h <<<\"\$o\" || exit 1; done; done; self=\$(curl -fsSG --data-urlencode 'query=up{job=~\"prometheus.*\"}' http://127.0.0.1:9090/api/v1/query); grep -q '\"1\"' <<<\"\$self\" && echo A6_OK" ;;
    G1.07) echo "ok=0; for s in prometheus-blackbox-exporter blackbox_exporter; do systemctl is-active --quiet \$s 2>/dev/null && systemctl is-enabled --quiet \$s 2>/dev/null && ok=1; done; test \$ok -eq 1 && ss -ltn | grep -q :9115 && o=\$(grep -RhiE 'prober:|query_name|insecure_skip_verify' /etc/prometheus /etc/blackbox* 2>/dev/null); grep -q 'prober: dns' <<<\"\$o\" && grep -q 'query_name' <<<\"\$o\" && grep -q 'prober: http' <<<\"\$o\" && ! grep -q 'insecure_skip_verify: true' <<<\"\$o\" && echo A6_OK" ;;
    G1.08) echo "o=\$(curl -fsSG --data-urlencode 'query=probe_success' http://127.0.0.1:9090/api/v1/query); [ \$(grep -o '\"value\":\[[^]]*,\"1\"\]' <<<\"\$o\" | wc -l) -ge 8 ] && for n in dns1 dns2 ldap portal 587 993 445 2049; do grep -q \$n <<<\"\$o\" || exit 1; done; echo A6_OK" ;;
    H1.01) echo "[ \"\$(curl -s -o /dev/null -w '%{http_code}' -u 'admin:Skill39-A6-Monitor!' http://127.0.0.1:3000/api/user)\" = 200 ] && [ \"\$(curl -s -o /dev/null -w '%{http_code}' -u admin:wrong http://127.0.0.1:3000/api/user)\" = 401 ] && { docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' a6-grafana | grep -qi '^GF_USERS_ALLOW_SIGN_UP=false\$' || docker exec a6-grafana sh -c 'grep -Eq \"^[[:space:]]*allow_sign_up[[:space:]]*=[[:space:]]*false\" /etc/grafana/grafana.ini'; } && echo A6_OK" ;;
    H1.02) echo "o=\$(curl -fsS -u 'admin:Skill39-A6-Monitor!' http://127.0.0.1:3000/api/datasources/uid/prometheus-a6); for n in Prometheus-A6 prometheus-a6 http://prometheus:9090 'isDefault\":true'; do grep -Fq \"\$n\" <<<\"\$o\" || exit 1; done; grep -Rqs prometheus-a6 /opt/a6-monitoring && echo A6_OK" ;;
    H1.03) echo "o=\$(curl -fsS -u 'admin:Skill39-A6-Monitor!' http://127.0.0.1:3000/api/dashboards/uid/a6-integrated-infra); s=\$(curl -fsS -u 'admin:Skill39-A6-Monitor!' 'http://127.0.0.1:3000/api/search?query=A6%20Integrated%20Infrastructure'); for n in 'A6 Integrated Infrastructure' a6-integrated-infra; do grep -Fq \"\$n\" <<<\"\$o\" || exit 1; done; grep -Eq '\"refresh\":\"([1-9]|[12][0-9]|30)s\"' <<<\"\$o\" && grep -q '\"folderTitle\":\"A6\"' <<<\"\$s\" && grep -Rqs a6-integrated-infra /opt/a6-monitoring && echo A6_OK" ;;
    H1.04) echo "o=\$(curl -fsS -u 'admin:Skill39-A6-Monitor!' http://127.0.0.1:3000/api/dashboards/uid/a6-integrated-infra); grep -q 'Target Availability' <<<\"\$o\" && grep -q '\"expr\":\"up' <<<\"\$o\" || exit 1; live=\$(curl -fsSG --data-urlencode 'query=up' http://127.0.0.1:9090/api/v1/query); for h in directory-a6 network-a6 services-a6; do grep -q \$h <<<\"\$live\" || exit 1; done; echo A6_OK" ;;
    H1.05) echo "o=\$(curl -fsS -u 'admin:Skill39-A6-Monitor!' http://127.0.0.1:3000/api/dashboards/uid/a6-integrated-infra); grep -q 'Service Availability' <<<\"\$o\" && grep -q probe_success <<<\"\$o\" || exit 1; live=\$(curl -fsSG --data-urlencode 'query=probe_success' http://127.0.0.1:9090/api/v1/query); for n in dns1 dns2 ldap portal 587 993 445 2049; do grep -q \$n <<<\"\$live\" || exit 1; done; echo A6_OK" ;;
    H1.06) echo "o=\$(curl -fsS -u 'admin:Skill39-A6-Monitor!' http://127.0.0.1:3000/api/dashboards/uid/a6-integrated-infra); grep -q 'CPU Utilization' <<<\"\$o\" && grep -q node_cpu_seconds_total <<<\"\$o\" || exit 1; live=\$(curl -fsSG --data-urlencode 'query=node_cpu_seconds_total' http://127.0.0.1:9090/api/v1/query); for h in directory-a6 network-a6 services-a6; do grep -q \$h <<<\"\$live\" || exit 1; done; echo A6_OK" ;;
    H1.07) echo "o=\$(curl -fsS -u 'admin:Skill39-A6-Monitor!' http://127.0.0.1:3000/api/dashboards/uid/a6-integrated-infra); grep -q 'Available Memory' <<<\"\$o\" && grep -q node_memory_MemAvailable_bytes <<<\"\$o\" || exit 1; live=\$(curl -fsSG --data-urlencode 'query=node_memory_MemAvailable_bytes' http://127.0.0.1:9090/api/v1/query); for h in directory-a6 network-a6 services-a6; do grep -q \$h <<<\"\$live\" || exit 1; done; echo A6_OK" ;;
    H1.08) echo "o=\$(curl -fsS -u 'admin:Skill39-A6-Monitor!' http://127.0.0.1:3000/api/dashboards/uid/a6-integrated-infra); grep -q 'Root Filesystem Usage' <<<\"\$o\" && grep -q 'mountpoint.*[/]' <<<\"\$o\" || exit 1; live=\$(curl -fsSG --data-urlencode 'query=node_filesystem_size_bytes{mountpoint=\"/\"}' http://127.0.0.1:9090/api/v1/query); for h in directory-a6 network-a6 services-a6; do grep -q \$h <<<\"\$live\" || exit 1; done; echo A6_OK" ;;
    I1.01) echo "[ \"$A6_DISRUPTIVE\" = 1 ] || exit 3; cleanup(){ ssh root@10.76.30.10 'systemctl start smbd' >/dev/null 2>&1 || true; }; trap cleanup EXIT INT TERM; before=\$(curl -fsSG --data-urlencode 'query=probe_success{instance=~\".*:445\"}' http://127.0.0.1:9090/api/v1/query) && grep -q '\"1\"' <<<\"\$before\" || exit 1; ssh root@10.76.30.10 'systemctl stop smbd' || exit 1; sleep 35; down=\$(curl -fsSG --data-urlencode 'query=probe_success{instance=~\".*:445\"}' http://127.0.0.1:9090/api/v1/query) && grep -q '\"0\"' <<<\"\$down\" || exit 1; cleanup; sleep 35; up=\$(curl -fsSG --data-urlencode 'query=probe_success{instance=~\".*:445\"}' http://127.0.0.1:9090/api/v1/query) && grep -q '\"1\"' <<<\"\$up\" && trap - EXIT INT TERM && echo A6_OK" ;;
    I1.02) echo "ssh root@10.76.10.1 'ip route get 10.76.30.10 | grep -q wg0 && ip route get 198.18.76.20 | grep -vq wg0' && ssh root@10.76.10.100 'curl -skf https://portal.nova.a6.test/ >/dev/null && curl -skf https://portal-public.nova.a6.test:8443/ >/dev/null' && echo A6_OK" ;;
    I1.03) echo "[ \"$A6_DISRUPTIVE\" = 1 ] || exit 3; cd /opt/a6-monitoring || exit 1; end=\$(date +%s); start=\$((end-120)); before=\$(curl -fsSG --data-urlencode 'query=up' --data-urlencode \"start=\$start\" --data-urlencode \"end=\$end\" --data-urlencode 'step=15' http://127.0.0.1:9090/api/v1/query_range); grep -q '\"values\"' <<<\"\$before\" || exit 1; cleanup(){ docker compose up -d --pull never >/dev/null 2>&1 || true; }; trap cleanup EXIT INT TERM; docker compose down && docker compose up -d --pull never && timeout 90 bash -c 'until curl -fsS http://127.0.0.1:9090/-/ready && curl -fsS -u \"admin:Skill39-A6-Monitor!\" http://127.0.0.1:3000/api/dashboards/uid/a6-integrated-infra; do sleep 3; done' || exit 1; after=\$(curl -fsSG --data-urlencode 'query=up' --data-urlencode \"start=\$start\" --data-urlencode \"end=\$end\" --data-urlencode 'step=15' http://127.0.0.1:9090/api/v1/query_range); grep -q '\"values\"' <<<\"\$after\" && docker volume inspect a6-prometheus-data a6-grafana-data >/dev/null && trap - EXIT INT TERM && echo A6_OK" ;;
    I1.04) echo "[ \"$A6_DISRUPTIVE\" = 1 ] || exit 3; cleanup(){ systemctl start docker >/dev/null 2>&1 || true; }; trap cleanup EXIT INT TERM; systemctl restart docker && timeout 90 bash -c 'until [ \"\$(docker inspect -f {{.State.Running}} a6-prometheus 2>/dev/null)\" = true ] && [ \"\$(docker inspect -f {{.State.Running}} a6-grafana 2>/dev/null)\" = true ]; do sleep 3; done' && trap - EXIT INT TERM && echo A6_OK" ;;
    I1.05) echo "[ \"$A6_DISRUPTIVE\" = 1 ] || exit 3; cleanup(){ ssh root@10.76.40.10 'systemctl start bind9 slapd prometheus-node-exporter' >/dev/null 2>&1 || true; ssh root@10.76.40.20 'systemctl start bind9 kea-dhcp4-server prometheus-node-exporter' >/dev/null 2>&1 || true; ssh root@10.76.30.10 'systemctl start apache2 postfix dovecot nfs-kernel-server smbd prometheus-node-exporter' >/dev/null 2>&1 || true; ssh root@10.76.20.100 'systemctl start prometheus-blackbox-exporter' >/dev/null 2>&1 || true; }; trap cleanup EXIT INT TERM; while read -r h services; do for s in \$services; do ssh root@\$h \"systemctl is-enabled --quiet \$s && systemctl restart \$s && systemctl is-active --quiet \$s\" || exit 1; done; done <<'EOF'
10.76.40.10 bind9 slapd prometheus-node-exporter
10.76.40.20 bind9 kea-dhcp4-server prometheus-node-exporter
10.76.30.10 apache2 postfix dovecot nfs-kernel-server smbd prometheus-node-exporter
10.76.20.100 prometheus-blackbox-exporter
EOF
trap - EXIT INT TERM; echo A6_OK" ;;
    I1.06) echo "getent hosts portal.nova.a6.test >/dev/null && getent passwd maya | grep -q 8601 && smbclient //files.nova.a6.test/team -U 'maya%Skill39@A6' -c ls >/dev/null && curl -sf -u maya:Skill39@A6 https://portal.nova.a6.test/staff/ >/dev/null && curl -sf --user 'timur:Skill39@A6' imaps://mail.nova.a6.test:993/INBOX >/dev/null && curl -fsS http://127.0.0.1:9090/-/ready >/dev/null && curl -fsSG --data-urlencode 'query=probe_success' http://127.0.0.1:9090/api/v1/query | grep -q '\"1\"' && echo A6_OK" ;;
    *) echo "exit 4" ;;
  esac
}

section_name=""
started=0
ssh_precheck
while IFS=$'\t' read -r id subsection description mark runfrom commands expected notes; do
  [ "$id" = CriterionID ] && continue
  [ "$started" = 1 ] || { [ "$id" = "$A6_START_FROM" ] && started=1 || continue; }
  current="${id%%.*}"
  if [ "$current" != "$section_name" ]; then section_name="$current"; section "A6 criterion $current"; fi
  step "$id" "$description"
  cmd_show "$id" "$commands"
  automatic="$(command_for "$id")"
  run_command "$automatic"
  case "$A6_LAST_RC" in
    0) grep -q A6_OK <<<"$A6_LAST_OUT" && pass "$id" "$mark" "complete automatic check passed" || fail "$id" "$mark" "command exited without the required success marker" ;;
    3) skip "$id" "$mark" "disruptive check disabled; rerun with --disruptive at the end of marking" ;;
    4) warn "$id" "$mark" "supervised live verification required; use the displayed marking procedure" ;;
    *) fail "$id" "$mark" "automatic check failed (exit $A6_LAST_RC)" ;;
  esac
done < "$A6_CRITERIA_MAP"

write_summary
