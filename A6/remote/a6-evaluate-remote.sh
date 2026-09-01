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
for tool_name in curl nc openssl docker smbclient getent systemctl python3; do
  tool_path="\$(type -P "\$tool_name" 2>/dev/null || true)"
  printf -v "A6_REAL_\${tool_name^^}" '%s' "\$tool_path"
done
a6_local_tool() {
  local tool="\$1"; shift
  local name display rc
  name="\$(basename "\${tool:-missing-tool}")"
  display="\$(printf '%s ' "\$@")"
  printf '\n[DEVICE: ops-a6 (local coordinator)]\n' >&2
  printf '[COMMAND] %s %s\n' "\$name" "\$display" >&2
  printf '[OUTPUT]\n' >&2
  if [ -z "\$tool" ]; then
    printf '%s: command not found\n' "\$name" >&2
    rc=127
  elif [ "\${BASH_SUBSHELL:-0}" -gt 0 ]; then
    command "\$tool" "\$@" | tee /dev/stderr
    rc="\${PIPESTATUS[0]}"
  else
    command "\$tool" "\$@"
    rc="\$?"
  fi
  printf '[RESULT: exit=%s]\n' "\$rc" >&2
  return "\$rc"
}
curl() { a6_local_tool "\$A6_REAL_CURL" "\$@"; }
nc() { a6_local_tool "\$A6_REAL_NC" "\$@"; }
openssl() { a6_local_tool "\$A6_REAL_OPENSSL" "\$@"; }
docker() { a6_local_tool "\$A6_REAL_DOCKER" "\$@"; }
smbclient() { a6_local_tool "\$A6_REAL_SMBCLIENT" "\$@"; }
getent() { a6_local_tool "\$A6_REAL_GETENT" "\$@"; }
systemctl() { a6_local_tool "\$A6_REAL_SYSTEMCTL" "\$@"; }
python3() { a6_local_tool "\$A6_REAL_PYTHON3" "\$@"; }
ssh() {
  local target="\${1:-unknown}" label display rc
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
  display="\$(printf '%s ' "\${@:2}")"
  printf '[COMMAND] %s\n' "\${display:-<interactive shell>}" >&2
  printf '[OUTPUT]\n' >&2
  if [ "\${BASH_SUBSHELL:-0}" -gt 0 ]; then
    command timeout "${A6_SSH_COMMAND_TIMEOUT}s" /usr/bin/ssh \
      -o BatchMode=yes -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      -o ConnectTimeout="${A6_TIMEOUT}" -o ConnectionAttempts=1 \
      -o GSSAPIAuthentication=no "\$@" | tee /dev/stderr
    rc="\${PIPESTATUS[0]}"
  else
    command timeout "${A6_SSH_COMMAND_TIMEOUT}s" /usr/bin/ssh \
      -o BatchMode=yes -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      -o ConnectTimeout="${A6_TIMEOUT}" -o ConnectionAttempts=1 \
      -o GSSAPIAuthentication=no "\$@"
    rc="\$?"
  fi
  if [ "\$rc" -eq 0 ]; then
    printf '[RESULT: exit=0]\n' >&2
  else
    printf '[RESULT: exit=%s]\n' "\$rc" >&2
  fi
  return "\$rc"
}
EOF
    printf '%s\n' "$command"
  } > "$tmp"
  chmod 700 "$tmp"
  divider; echo -e "${BLUE}Automatic command execution:${NC}"
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
    A1.03) echo "failed=0; for x in '10.76.10.100 10.76.10.100' '10.76.20.100 10.76.20.100'; do set -- \$x; h=\$1; expected=\$2; o=\$(ssh root@\$h 'echo ===IPV4===; ip -4 -br addr; echo ===DEFAULT-ROUTE===; ip route show default; echo ===DHCP-LEASES===; find /run/systemd/netif/leases /var/lib/dhcp /var/lib/NetworkManager -maxdepth 2 -type f -exec grep -HE \"ADDRESS=|fixed-address|ip_address=|dhcp\" {} + 2>/dev/null || true; echo ===PERSISTENT-PROFILE===; nmcli -t -f NAME,TYPE,ipv4.method con show 2>/dev/null || grep -RhEv \"^[[:space:]]*(#|\$)\" /etc/network/interfaces /etc/network/interfaces.d /etc/systemd/network 2>/dev/null'); rc=\$?; printf '%s\\n' \"\$o\"; live=\$(sed -n '/^===IPV4===\$/,/^===DEFAULT-ROUTE===\$/p' <<<\"\$o\"); if [ \$rc -eq 0 ] && grep -Eq \"\$expected/24([[:space:]]|\$)\" <<<\"\$live\"; then echo \"ADDRESS_OK: \$expected/24\"; else echo \"ADDRESS_FAIL: expected \$expected/24\"; failed=1; fi; if grep -qiE 'ipv4.method:auto|iface .* inet dhcp|DHCP[[:space:]]*=[[:space:]]*(yes|ipv4|true)|:(ADDRESS=|fixed-address|ip_address=)' <<<\"\$o\"; then echo 'DHCP_PROFILE_OK'; else echo 'DHCP_PROFILE_FAIL: no active lease or persistent DHCP profile found'; failed=1; fi; done; [ \$failed -eq 0 ] && echo A6_OK" ;;
    A1.04) echo "for h in 10.76.10.1 10.76.20.1; do ssh root@\$h 'test \"\$(sysctl -n net.ipv4.ip_forward)\" = 1 && grep -RqsE \"net.ipv4.ip_forward[[:space:]]*=[[:space:]]*1\" /etc/sysctl.conf /etc/sysctl.d' || exit 1; done; ssh root@10.76.10.1 'for d in 10.76.20.10 10.76.30.10 10.76.40.20; do ip route get \$d | grep -q wg0 || exit 1; done' && ssh root@10.76.20.1 'ip route get 10.76.10.100 | grep -q wg0' && echo A6_OK" ;;
    A1.05) echo "a=\$(ssh root@10.76.10.1 'ip -4 a show wg0; wg show wg0'); b=\$(ssh root@10.76.20.1 'ip -4 a show wg0; wg show wg0'); aip=\$(sed -n 's/.*allowed ips: //p' <<<\"\$a\" | tr ',' '\\n' | xargs -n1 | sort | tr '\\n' ' '); bip=\$(sed -n 's/.*allowed ips: //p' <<<\"\$b\" | tr ',' '\\n' | xargs -n1 | sort | tr '\\n' ' '); grep -q '10.200.6.1/30' <<<\"\$a\" && grep -q 'listening port: 51820' <<<\"\$a\" && grep -q 'endpoint: 198.18.76.20:51820' <<<\"\$a\" && [ \"\$aip\" = '10.76.20.0/24 10.76.30.0/24 10.76.40.0/24 ' ] && grep -q '10.200.6.2/30' <<<\"\$b\" && grep -q 'listening port: 51820' <<<\"\$b\" && grep -q 'endpoint: 198.18.76.10:51820' <<<\"\$b\" && [ \"\$bip\" = '10.76.10.0/24 ' ] && echo A6_OK" ;;
    A1.06) echo "ssh root@10.76.10.1 'ping -c1 -W2 10.200.6.2 >/dev/null && hs=\$(wg show wg0 latest-handshakes | awk \"{print \\$2}\") && test \"\$hs\" -gt 0 && test \$((\$(date +%s)-hs)) -le 120 && systemctl is-active --quiet wg-quick@wg0 && systemctl is-enabled --quiet wg-quick@wg0' && ssh root@10.76.20.1 'systemctl is-active --quiet wg-quick@wg0 && systemctl is-enabled --quiet wg-quick@wg0' && echo A6_OK" ;;
    A1.07) echo "ssh root@10.76.10.1 'ip route get 10.76.30.10 | grep -q wg0 && ip route get 10.76.40.20 | grep -q wg0 && ip route get 198.18.76.20 | grep -vq wg0' && echo A6_OK" ;;
    A1.08) echo "ssh root@10.76.40.20 'cfg=\$(systemctl show kea-dhcp4-server -p ExecStart --value 2>/dev/null | sed -n \"s/.*[[:space:]]-c[[:space:]]\\([^ ;}]*\\).*/\\1/p\" | head -n1); if [ -z \"\$cfg\" ]; then for f in /etc/kea/kea-dhcp4.conf /usr/local/etc/kea/kea-dhcp4.conf; do [ -r \"\$f\" ] && { cfg=\$f; break; }; done; fi; [ -n \"\$cfg\" ] && [ -r \"\$cfg\" ] || { echo \"Kea configuration file not found in service ExecStart or standard locations\"; exit 1; }; echo \"CONFIG_FILE: \$cfg\"; kea-dhcp4 -t \"\$cfg\" && python3 -c \"import json,re,sys; t=open(sys.argv[1]).read(); t=re.sub(r\\\"/[*].*?[*]/\\\",\\\"\\\",t,flags=re.S); t=re.sub(r\\\"(?m)//.*$\\\",\\\"\\\",t); t=re.sub(r\\\",(\\\\s*[}\\\\]])\\\",r\\\"\\\\1\\\",t); c=json.loads(t)[\\\"Dhcp4\\\"]; s={x[\\\"subnet\\\"]:x for x in c[\\\"subnet4\\\"]}; a=s[\\\"10.76.10.0/24\\\"]; b=s[\\\"10.76.20.0/24\\\"]; assert a[\\\"pools\\\"][0][\\\"pool\\\"].replace(\\\" \\\",\\\"\\\")==\\\"10.76.10.110-10.76.10.149\\\"; assert b[\\\"pools\\\"][0][\\\"pool\\\"].replace(\\\" \\\",\\\"\\\")==\\\"10.76.20.110-10.76.20.149\\\"; assert any(r.get(\\\"ip-address\\\")==\\\"10.76.10.100\\\" and r.get(\\\"hw-address\\\") for r in a[\\\"reservations\\\"]); assert any(r.get(\\\"ip-address\\\")==\\\"10.76.20.100\\\" and r.get(\\\"hw-address\\\") for r in b[\\\"reservations\\\"]); opts=lambda x:{o[\\\"name\\\"]:o[\\\"data\\\"] for o in x[\\\"option-data\\\"]}; assert opts(a)[\\\"routers\\\"]==\\\"10.76.10.1\\\" and opts(b)[\\\"routers\\\"]==\\\"10.76.20.1\\\"; assert all(\\\"10.76.40.10\\\" in opts(x)[\\\"domain-name-servers\\\"] and \\\"10.76.40.20\\\" in opts(x)[\\\"domain-name-servers\\\"] and opts(x)[\\\"domain-name\\\"]==\\\"nova.a6.test\\\" for x in (a,b))\" \"\$cfg\"' && echo A6_OK" ;;
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
    C1.01) echo "failed=0; ssh root@10.76.40.10 'ldif=\$(slapcat -b dc=nova,dc=a6,dc=test) || exit 1; printf \"%s\\n\" \"\$ldif\" | grep -Ei \"^(dn|ou|uid|uidNumber|gidNumber|cn):\"; record(){ awk -v key=\"\$1\" \"BEGIN { RS=\\\"\\\" } index(tolower(\\\$0),tolower(key)) { print; found=1 } END { exit !found }\" <<<\"\$ldif\"; }; failed=0; check(){ label=\$1; pattern=\$2; data=\$3; if grep -qiE \"\$pattern\" <<<\"\$data\"; then echo \"[OK] \$label\"; else echo \"[FAIL] \$label; expected: \$pattern\"; failed=1; fi; }; for ou in People Groups Services; do check \"OU \$ou exists\" \"^dn: ou=\$ou,dc=nova,dc=a6,dc=test\$\" \"\$ldif\"; done; m=\$(record \"uid: maya\") || true; t=\$(record \"uid: timur\") || true; l=\$(record \"cn: linuxusers\") || true; f=\$(record \"cn: filewriters\") || true; w=\$(record \"cn: webadmins\") || true; check \"maya uidNumber=8601\" \"^uidNumber: 8601\$\" \"\$m\"; check \"maya primary gidNumber=7600\" \"^gidNumber: 7600\$\" \"\$m\"; check \"timur uidNumber=8602\" \"^uidNumber: 8602\$\" \"\$t\"; check \"timur primary gidNumber=7600\" \"^gidNumber: 7600\$\" \"\$t\"; check \"linuxusers gidNumber=7600\" \"^gidNumber: 7600\$\" \"\$l\"; check \"filewriters gidNumber=7601\" \"^gidNumber: 7601\$\" \"\$f\"; check \"webadmins gidNumber=7610\" \"^gidNumber: 7610\$\" \"\$w\"; exit \$failed' || failed=1; has_group(){ case \" \$1 \" in *\" \$2 \"*) return 0;; *) return 1;; esac; }; report_member(){ host=\$1; user=\$2; group=\$3; groups=\$4; expected=\$5; if has_group \"\$groups\" \"\$group\"; then actual=present; else actual=absent; fi; if [ \"\$actual\" = \"\$expected\" ]; then echo \"[OK] \$host: \$user membership in \$group is \$actual\"; else echo \"[FAIL] \$host: \$user membership in \$group is \$actual; expected \$expected; resolved groups: \$groups\"; failed=1; fi; }; for x in '10.76.10.100 sh-user-a6' '10.76.20.100 ops-a6' '10.76.30.10 services-a6'; do set -- \$x; ip=\$1; host=\$2; memberships=\$(ssh root@\$ip 'printf \"maya: \"; id -nG maya; printf \"timur: \"; id -nG timur') || { echo \"[FAIL] \$host: unable to resolve LDAP users through NSS/SSSD\"; failed=1; continue; }; maya_groups=\$(sed -n 's/^maya: //p' <<<\"\$memberships\"); timur_groups=\$(sed -n 's/^timur: //p' <<<\"\$memberships\"); for g in linuxusers filewriters webadmins; do report_member \"\$host\" maya \"\$g\" \"\$maya_groups\" present; done; report_member \"\$host\" timur linuxusers \"\$timur_groups\" present; report_member \"\$host\" timur filewriters \"\$timur_groups\" absent; report_member \"\$host\" timur webadmins \"\$timur_groups\" absent; done; [ \$failed -eq 0 ] && echo A6_OK" ;;
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
    C1.06) echo "failed=0; for h in 10.76.10.100 10.76.20.100 10.76.30.10; do ssh root@\$h 'failed=0; check(){ label=\$1; pattern=\$2; data=\$3; if grep -qE \"\$pattern\" <<<\"\$data\"; then echo \"[OK] \$label\"; else echo \"[FAIL] \$label; expected: \$pattern\"; failed=1; fi; }; collect(){ label=\$1; shift; echo \"--- \$label ---\" >&2; out=\$(\"\$@\" 2>&1); rc=\$?; printf \"%s\\n\" \"\$out\" >&2; echo \"command exit=\$rc\" >&2; printf \"%s\" \"\$out\"; return \$rc; }; maya=\$(collect \"getent passwd maya\" getent passwd maya); maya_rc=\$?; timur=\$(collect \"getent passwd timur\" getent passwd timur); timur_rc=\$?; maya_id=\$(collect \"id maya\" id maya); maya_id_rc=\$?; timur_id=\$(collect \"id timur\" id timur); timur_id_rc=\$?; linux=\$(collect \"getent group linuxusers\" getent group linuxusers); linux_rc=\$?; writers=\$(collect \"getent group filewriters\" getent group filewriters); writers_rc=\$?; web=\$(collect \"getent group webadmins\" getent group webadmins); web_rc=\$?; local_maya=\$(getent -s files passwd maya 2>&1); local_maya_rc=\$?; local_timur=\$(getent -s files passwd timur 2>&1); local_timur_rc=\$?; check \"maya resolves as UID 8601/GID 7600\" \"^[^:]+:[^:]*:8601:7600:\" \"\$maya\"; check \"timur resolves as UID 8602/GID 7600\" \"^[^:]+:[^:]*:8602:7600:\" \"\$timur\"; [ \$maya_id_rc -eq 0 ] || { echo \"[FAIL] id maya failed (exit \$maya_id_rc)\"; failed=1; }; [ \$timur_id_rc -eq 0 ] || { echo \"[FAIL] id timur failed (exit \$timur_id_rc)\"; failed=1; }; check \"linuxusers resolves as GID 7600\" \"^[^:]+:[^:]*:7600:\" \"\$linux\"; check \"filewriters resolves as GID 7601\" \"^[^:]+:[^:]*:7601:\" \"\$writers\"; check \"webadmins resolves as GID 7610\" \"^[^:]+:[^:]*:7610:\" \"\$web\"; [ \$linux_rc -eq 0 ] || { echo \"[FAIL] getent group linuxusers failed (exit \$linux_rc)\"; failed=1; }; [ \$writers_rc -eq 0 ] || { echo \"[FAIL] getent group filewriters failed (exit \$writers_rc)\"; failed=1; }; [ \$web_rc -eq 0 ] || { echo \"[FAIL] getent group webadmins failed (exit \$web_rc)\"; failed=1; }; if [ \$local_maya_rc -ne 0 ] && [ -z \"\$local_maya\" ]; then echo \"[OK] no local files entry for maya\"; else echo \"[FAIL] local files entry/error for maya: \$local_maya\"; failed=1; fi; if [ \$local_timur_rc -ne 0 ] && [ -z \"\$local_timur\" ]; then echo \"[OK] no local files entry for timur\"; else echo \"[FAIL] local files entry/error for timur: \$local_timur\"; failed=1; fi; exit \$failed' || failed=1; done; [ \$failed -eq 0 ] && echo A6_OK" ;;
    C1.07) echo "ssh root@10.76.10.100 'command -v pamtester >/dev/null || exit 4; printf \"%s\\n\" Skill39@A6 | pamtester login maya authenticate' && echo A6_OK" ;;
    C1.08) echo "for h in 10.76.10.100 10.76.20.100 10.76.30.10; do o=\$(ssh root@\$h 'grep -RhiE \"ldap_uri|ldap_id_use_start_tls|ldap_tls_reqcert|TLS_REQCERT\" /etc/sssd /etc/ldap 2>/dev/null'); grep -qiE 'start_tls.*true|ldap://ldap.nova.a6.test' <<<\"\$o\" && ! grep -qiE 'reqcert.*never|insecure_skip_verify' <<<\"\$o\" || exit 1; done; echo A6_OK" ;;
    D1.01) echo "o=\$(ssh root@10.76.30.10 'exportfs -v; testparm -s 2>/dev/null'); [ \$(grep -Fc /srv/files/team <<<\"\$o\") -ge 2 ] && echo A6_OK" ;;
    D1.02) echo "ssh root@10.76.30.10 'failed=0; echo \"--- namei -l /srv/files/team ---\"; namei -l /srv/files/team; namei_rc=\$?; echo \"command exit=\$namei_rc\"; echo \"--- getfacl -cp /srv/files/team ---\"; o=\$(getfacl -cp /srv/files/team 2>&1); acl_rc=\$?; printf \"%s\\n\" \"\$o\"; echo \"command exit=\$acl_rc\"; [ \$namei_rc -eq 0 ] || { echo \"[FAIL] path traversal/ownership inspection failed\"; failed=1; }; [ \$acl_rc -eq 0 ] || { echo \"[FAIL] getfacl failed\"; failed=1; }; check(){ label=\$1; pattern=\$2; if grep -qE \"\$pattern\" <<<\"\$o\"; then echo \"[OK] \$label\"; else echo \"[FAIL] \$label; expected ACL line matching: \$pattern\"; failed=1; fi; }; check \"filewriters has rwx on existing objects\" \"^group:filewriters:rwx([[:space:]]|\$)\"; check \"linuxusers has read/execute on existing objects\" \"^group:linuxusers:r-x([[:space:]]|\$)\"; check \"new objects inherit filewriters rwx\" \"^default:group:filewriters:rwx([[:space:]]|\$)\"; check \"new objects inherit linuxusers read/execute\" \"^default:group:linuxusers:r-x([[:space:]]|\$)\"; exit \$failed' && echo A6_OK" ;;
    D1.03) echo "o=\$(ssh root@10.76.30.10 'exportfs -v'); grep -q /srv/files/team <<<\"\$o\" && grep -q root_squash <<<\"\$o\" && grep -q 10.76.10.0/24 <<<\"\$o\" && grep -q 10.76.20.0/24 <<<\"\$o\" && echo A6_OK" ;;
    D1.04) echo "failed=0; ssh root@10.76.10.100 'failed=0; m=\$(mktemp -d); cleanup(){ umount \"\$m\" >/dev/null 2>&1 || true; rmdir \"\$m\" >/dev/null 2>&1 || true; }; trap cleanup EXIT INT TERM; echo \"--- route from sh-user-a6 ---\"; route=\$(ip route get 10.76.30.10 2>&1); route_rc=\$?; printf \"%s\\n\" \"\$route\"; if [ \$route_rc -eq 0 ] && grep -q 10.76.10.1 <<<\"\$route\"; then echo \"[OK] client route uses sh-edge-a6 (10.76.10.1)\"; else echo \"[FAIL] expected route via 10.76.10.1\"; failed=1; fi; mounted=0; for e in /team / /srv/files/team; do echo \"--- timeout 8 mount -t nfs4 files.nova.a6.test:\$e \$m ---\"; mount_out=\$(timeout 8 mount -v -t nfs4 \"files.nova.a6.test:\$e\" \"\$m\" 2>&1); mount_rc=\$?; printf \"%s\\n\" \"\$mount_out\"; echo \"command exit=\$mount_rc\"; if [ \$mount_rc -eq 0 ]; then mounted=1; export_used=\$e; echo \"[OK] mounted export \$e\"; break; elif [ \$mount_rc -eq 124 ]; then echo \"[FAIL] mount of export \$e timed out after 8 seconds\"; else echo \"[FAIL] mount of export \$e failed (exit \$mount_rc)\"; fi; done; if [ \$mounted -eq 1 ]; then echo \"--- findmnt result ---\"; findmnt -T \"\$m\"; find_rc=\$?; echo \"--- directory listing ---\"; ls -la \"\$m\"; list_rc=\$?; [ \$find_rc -eq 0 ] || { echo \"[FAIL] mounted filesystem is not visible to findmnt\"; failed=1; }; [ \$list_rc -eq 0 ] || { echo \"[FAIL] mounted share cannot be listed\"; failed=1; }; else echo \"[FAIL] none of the candidate NFSv4 exports could be mounted\"; failed=1; fi; exit \$failed' || failed=1; ssh root@10.76.10.1 'route=\$(ip route get 10.76.30.10 2>&1); rc=\$?; printf \"%s\\n\" \"\$route\"; if [ \$rc -eq 0 ] && grep -q wg0 <<<\"\$route\"; then echo \"[OK] sh-edge-a6 route uses wg0\"; else echo \"[FAIL] sh-edge-a6 route to 10.76.30.10 does not use wg0\"; exit 1; fi' || failed=1; [ \$failed -eq 0 ] && echo A6_OK" ;;
    D1.05) echo "failed=0; ssh root@10.76.30.10 'o=\$(testparm -s 2>&1); rc=\$?; printf \"%s\\n\" \"\$o\"; echo \"command exit=\$rc\"; [ \$rc -eq 0 ] || { echo \"[FAIL] testparm rejected the Samba configuration\"; exit 1; }; failed=0; section=\$(awk \"BEGIN{IGNORECASE=1;inside=0} /^\\[team\\]/{inside=1} /^\\[/{if (inside && tolower(\\\$0)!=\\\"[team]\\\") exit} inside{print}\" <<<\"\$o\"); check(){ label=\$1; pattern=\$2; data=\$3; if grep -qiE \"\$pattern\" <<<\"\$data\"; then echo \"[OK] \$label\"; else echo \"[FAIL] \$label; expected: \$pattern\"; failed=1; fi; }; check \"share [team] exists\" \"^\\[team\\]\$\" \"\$section\"; check \"[team] path is /srv/files/team\" \"^[[:space:]]*path[[:space:]]*=[[:space:]]*/srv/files/team[[:space:]]*\$\" \"\$section\"; check \"[team] valid users are restricted to linuxusers\" \"^[[:space:]]*valid users[[:space:]]*=.*@linuxusers([[:space:]]|\$)\" \"\$section\"; check \"[team] write access is granted to filewriters\" \"^[[:space:]]*write list[[:space:]]*=.*@filewriters([[:space:]]|\$)\" \"\$section\"; if grep -qiE \"^[[:space:]]*guest ok[[:space:]]*=[[:space:]]*Yes\" <<<\"\$section\"; then echo \"[FAIL] [team] explicitly permits guest access\"; failed=1; else echo \"[OK] [team] does not explicitly permit guest access\"; fi; exit \$failed' || failed=1; ssh root@10.76.10.100 'command -v smbclient >/dev/null || { echo \"[FAIL] smbclient is not installed on sh-user-a6\"; exit 127; }; if smbclient //files.nova.a6.test/team -N -c ls; then echo \"[FAIL] anonymous access to [team] succeeded\"; exit 1; else echo \"[OK] anonymous access to [team] is denied\"; fi' || failed=1; [ \$failed -eq 0 ] && echo A6_OK" ;;
    D1.06) echo "failed=0; ssh root@10.76.10.100 'command -v smbclient >/dev/null || { echo \"[FAIL] smbclient is not installed on sh-user-a6\"; exit 127; }; failed=0; for u in maya timur; do echo \"--- authenticated SMB listing as \$u ---\"; if smbclient //files.nova.a6.test/team -U \"\$u%Skill39@A6\" -c ls; then echo \"[OK] \$u authenticated and listed [team]\"; else rc=\$?; echo \"[FAIL] \$u could not authenticate/list [team] (exit \$rc)\"; failed=1; fi; done; exit \$failed' || failed=1; ssh root@10.76.30.10 'failed=0; for x in \"maya 8601\" \"timur 8602\"; do set -- \$x; u=\$1; uid=\$2; echo \"--- getent passwd \$u ---\"; entry=\$(getent passwd \"\$u\" 2>&1); rc=\$?; printf \"%s\\n\" \"\$entry\"; if [ \$rc -eq 0 ] && grep -qE \"^[^:]+:[^:]*:\$uid:7600:\" <<<\"\$entry\"; then echo \"[OK] \$u resolves with LDAP UID \$uid/GID 7600\"; else echo \"[FAIL] \$u identity resolution is incorrect (exit \$rc)\"; failed=1; fi; if getent -s files passwd \"\$u\" | grep -q .; then echo \"[FAIL] \$u has a prohibited local passwd entry\"; failed=1; else echo \"[OK] \$u has no local passwd entry\"; fi; done; exit \$failed' || failed=1; [ \$failed -eq 0 ] && echo A6_OK" ;;
    D1.07) echo "tag=a6-cross-\$\$; m=/tmp/\$tag-mnt; n=\$tag-nfs.txt; s=\$tag-smb.txt; l=/tmp/\$tag-local.txt; cleanup(){ timeout 10 /usr/bin/ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@10.76.10.100 \"smbclient //files.nova.a6.test/team -U 'maya%Skill39@A6' -c 'del \$n; del \$s' >/dev/null 2>&1 || true; umount '\$m' >/dev/null 2>&1 || true; rm -rf '\$m' '\$l'\" >/dev/null 2>&1 || true; }; trap cleanup EXIT INT TERM; failed=0; ssh root@10.76.10.100 \"mkdir -p '\$m' && timeout 8 mount -v -t nfs4 files.nova.a6.test:/team '\$m'\" || failed=1; ssh root@10.76.10.100 \"runuser -u maya -- sh -c \\\"printf nfs-visible > '\$m/\$n'\\\"\" || failed=1; nfs_to_smb=\$(ssh root@10.76.10.100 \"smbclient //files.nova.a6.test/team -U 'maya%Skill39@A6' -c 'get \$n \$l' && cat '\$l'\") || failed=1; [ \"\$(tail -n1 <<<\"\$nfs_to_smb\")\" = nfs-visible ] || failed=1; ssh root@10.76.10.100 \"printf smb-visible > '\$l'\" || failed=1; ssh root@10.76.10.100 \"smbclient //files.nova.a6.test/team -U 'maya%Skill39@A6' -c 'put \$l \$s'\" || failed=1; smb_to_nfs=\$(ssh root@10.76.10.100 \"cat '\$m/\$s'\") || failed=1; [ \"\$(tail -n1 <<<\"\$smb_to_nfs\")\" = smb-visible ] || failed=1; cleanup; trap - EXIT INT TERM; [ \$failed -eq 0 ] && echo A6_OK" ;;
    D1.08) echo "ssh root@10.76.10.100 'set -e; m=\$(mktemp -d); n=a6-perm-\$\$.txt; l=\$(mktemp); cleanup(){ smbclient //files.nova.a6.test/team -U \"maya%Skill39@A6\" -c \"del \$n; del maya-\$n; del timur-\$n; del renamed-\$n\" >/dev/null 2>&1 || true; umount \"\$m\" >/dev/null 2>&1 || true; rm -rf \"\$m\" \"\$l\"; }; trap cleanup EXIT INT TERM; export_used=; for e in /team / /srv/files/team; do mount -t nfs4 \"files.nova.a6.test:\$e\" \"\$m\" 2>/dev/null && { export_used=\$e; break; }; done; test -n \"\$export_used\"; team=\$m; if [ \"\$export_used\" = / ]; then found=\$(find \"\$m\" -maxdepth 3 -type d -name team | head -n1); [ -z \"\$found\" ] || team=\$found; fi; runuser -u maya -- sh -c \"printf readable > '\"\$team\"/\$n' && printf changed >> '\"\$team\"/\$n' && mv '\"\$team\"/\$n' '\"\$team\"/renamed-\$n' && mv '\"\$team\"/renamed-\$n' '\"\$team\"/\$n' && touch '\"\$team\"/maya-\$n' && rm '\"\$team\"/maya-\$n'\"; runuser -u timur -- grep -q readable \"\$team/\$n\"; ! runuser -u timur -- sh -c \"echo bad >> '\"\$team\"/\$n'\"; ! runuser -u timur -- sh -c \"touch '\"\$team\"/timur-\$n'\"; ! runuser -u timur -- mv \"\$team/\$n\" \"\$team/renamed-\$n\"; ! runuser -u timur -- rm \"\$team/\$n\"; smbclient //files.nova.a6.test/team -U \"timur%Skill39@A6\" -c \"get \$n \$l\" >/dev/null; ! smbclient //files.nova.a6.test/team -U \"timur%Skill39@A6\" -c \"put \$l timur-\$n\" >/dev/null 2>&1; ! smbclient //files.nova.a6.test/team -U \"timur%Skill39@A6\" -c \"rename \$n renamed-\$n\" >/dev/null 2>&1; ! smbclient //files.nova.a6.test/team -U \"timur%Skill39@A6\" -c \"del \$n\" >/dev/null 2>&1; smbclient //files.nova.a6.test/team -U \"maya%Skill39@A6\" -c \"put \$l maya-\$n; del \$n; rename maya-\$n \$n; del \$n\" >/dev/null' && echo A6_OK" ;;
    E1.01) echo "curl --fail --silent --show-error https://portal.nova.a6.test/ | grep -q 'NOVA A6 SERVICES' && echo A6_OK" ;;
    E1.02) echo "openssl s_client -connect portal.nova.a6.test:443 -servername portal.nova.a6.test -verify_hostname portal.nova.a6.test -verify_return_error </dev/null 2>&1 | grep -q 'Verify return code: 0' && openssl s_client -connect portal.nova.a6.test:443 -servername portal.nova.a6.test </dev/null 2>/dev/null | openssl x509 -noout -ext subjectAltName | grep -q portal-public.nova.a6.test && echo A6_OK" ;;
    E1.03) echo "curl -sSI http://portal.nova.a6.test/ | grep -qiE '^location: https://portal.nova.a6.test' && echo A6_OK" ;;
    E1.04) echo "o=\$(ssh root@10.76.30.10 'apachectl -t >/dev/null && { apachectl -t -D DUMP_RUN_CFG 2>&1; grep -RhiE \"AuthLDAPURL|LDAPTrustedGlobalCert|LDAPVerifyServerCert|LDAPTrustedMode\" /etc/apache2; }') || exit 1; grep -qi AuthLDAPURL <<<\"\$o\" && grep -qiE 'LDAPTrustedMode[[:space:]]+TLS|AuthLDAPURL.*ldap://.*TLS' <<<\"\$o\" && ! grep -qi 'VerifyServerCert.*off' <<<\"\$o\" && echo A6_OK" ;;
    E1.05) echo "a=\$(curl -sk -o /dev/null -w '%{http_code}' https://portal.nova.a6.test/staff/); m=\$(curl -sk -u maya:Skill39@A6 -o /dev/null -w '%{http_code}' https://portal.nova.a6.test/staff/); t=\$(curl -sk -u timur:Skill39@A6 -o /dev/null -w '%{http_code}' https://portal.nova.a6.test/staff/); [ \"\$m\" = 200 ] && [[ \"\$a\" =~ ^(401|403)$ ]] && [[ \"\$t\" =~ ^(401|403)$ ]] && echo A6_OK" ;;
    E1.06) echo "ssh root@10.76.30.10 'systemctl is-active --quiet postfix dovecot && postconf -h mydestination | grep -q nova.a6.test && { doveconf -h mail_driver 2>/dev/null | grep -qi maildir || doveconf -n | grep -qi maildir; } && for p in 25 587 993; do ss -ltn | grep -qE \":\$p[[:space:]]\" || exit 1; done' && echo A6_OK" ;;
    E1.07) echo "printf 'EHLO test\r\nMAIL FROM:<maya@nova.a6.test>\r\nRCPT TO:<timur@nova.a6.test>\r\nQUIT\r\n' | nc -w4 mail.nova.a6.test 25 | tee /dev/stderr | grep -qE '^250 .*Recipient|^250 2\\.1\\.5' && echo A6_OK" ;;
    E1.08) echo "py=\$(mktemp); trap 'rm -f \"\$py\"' EXIT INT TERM; printf '%s\\n' 'import smtplib, ssl, sys' 'host, user, password = sys.argv[1:4]' 'sender = \"maya@nova.a6.test\"' 'recipient = \"timur@nova.a6.test\"' 'message = \"From: %s\\r\\nTo: %s\\r\\nSubject: A6-SUBMISSION-TEST\\r\\n\\r\\nA6 submission test\\r\\n\" % (sender, recipient)' 'context = ssl.create_default_context()' 'def connect():' '    smtp = smtplib.SMTP(host, 587, timeout=8)' '    smtp.set_debuglevel(1)' '    code, capabilities = smtp.ehlo()' '    print(\"EHLO:\", code)' '    if not smtp.has_extn(\"starttls\"): raise RuntimeError(\"STARTTLS is not advertised\")' '    smtp.starttls(context=context)' '    print(\"STARTTLS: certificate verified\")' '    smtp.ehlo()' '    return smtp' 'print(\"=== UNAUTHENTICATED SUBMISSION MUST FAIL ===\")' 'smtp = connect()' 'try:' '    smtp.sendmail(sender, [recipient], message)' 'except smtplib.SMTPException as error:' '    print(\"UNAUTHENTICATED SUBMISSION DENIED:\", error)' 'else:' '    raise RuntimeError(\"Unauthenticated submission was accepted\")' 'finally:' '    try: smtp.quit()' '    except Exception: smtp.close()' 'print(\"=== AUTHENTICATED SUBMISSION AS MAYA MUST SUCCEED ===\")' 'smtp = connect()' 'print(\"AUTH METHODS:\", smtp.esmtp_features.get(\"auth\", \"not advertised\"))' 'smtp.login(user, password)' 'print(\"AUTHENTICATION: successful for\", user)' 'smtp.sendmail(sender, [recipient], message)' 'print(\"AUTHENTICATED LOCAL SUBMISSION: accepted\")' 'smtp.quit()' >\"\$py\"; python3 \"\$py\" mail.nova.a6.test maya Skill39@A6; rc=\$?; rm -f \"\$py\"; trap - EXIT INT TERM; [ \$rc -eq 0 ] && echo A6_OK; exit \$rc" ;;
    E1.09) echo "for u in maya timur; do curl --fail --silent --user \"\$u:Skill39@A6\" imaps://mail.nova.a6.test:993/INBOX >/dev/null || exit 1; done; echo A6_OK" ;;
    E1.10) echo "openssl s_client -connect mail.nova.a6.test:993 -servername mail.nova.a6.test -verify_hostname mail.nova.a6.test -verify_return_error </dev/null 2>&1 | grep -q 'Verify return code: 0' && openssl s_client -connect mail.nova.a6.test:993 -servername mail.nova.a6.test </dev/null 2>/dev/null | openssl x509 -noout -ext subjectAltName | grep -q mail-public.nova.a6.test && echo A6_OK" ;;
    E1.11) echo "py=\$(mktemp); trap 'rm -f \"\$py\"' EXIT INT TERM; cat >\"\$py\" <<'PY'
import email.message, imaplib, smtplib, ssl, sys, time

host, maya_password, timur_password = sys.argv[1:4]
context = ssl.create_default_context()

def fail(message):
    print('[FAIL]', message)
    raise SystemExit(1)

try:
    print('TEST 1: external relay on TCP/25 without authentication')
    with smtplib.SMTP(host, 25, timeout=8) as smtp:
        smtp.ehlo()
        smtp.mail('probe@nova.a6.test')
        code, reply = smtp.rcpt('user@example.invalid')
        print('RCPT result:', code, reply.decode(errors='replace'))
        if code < 400:
            fail('external recipient was accepted on TCP/25')
    print('[OK] external relay denied on TCP/25')

    print('TEST 2: STARTTLS and maya authentication on TCP/587')
    smtp = smtplib.SMTP(host, 587, timeout=8)
    smtp.ehlo()
    if not smtp.has_extn('starttls'):
        fail('STARTTLS is not advertised on TCP/587')
    smtp.starttls(context=context)
    print('[OK] STARTTLS certificate verified')
    smtp.ehlo()
    smtp.login('maya', maya_password)
    print('[OK] maya authentication succeeded')

    print('TEST 3: authenticated external relay must be denied')
    smtp.mail('maya@nova.a6.test')
    code, reply = smtp.rcpt('user@example.invalid')
    print('RCPT result:', code, reply.decode(errors='replace'))
    if code < 400:
        fail('authenticated external recipient was accepted on TCP/587')
    print('[OK] authenticated external relay denied')
    smtp.rset()

    subject = 'A6-MAIL-TEST-' + str(int(time.time()))
    message = email.message.EmailMessage()
    message['From'] = 'maya@nova.a6.test'
    message['To'] = 'timur@nova.a6.test'
    message['Subject'] = subject
    message.set_content('A6 evaluator end-to-end test')
    print('TEST 4: submit local message:', subject)
    smtp.send_message(message)
    smtp.quit()
    print('[OK] local message accepted on TCP/587')

    print('TEST 5: retrieve the new message as timur over IMAPS/993')
    found = False
    for attempt in range(1, 7):
        with imaplib.IMAP4_SSL(host, 993, ssl_context=context, timeout=8) as imap:
            imap.login('timur', timur_password)
            imap.select('INBOX')
            status, data = imap.search(None, 'SUBJECT', subject)
            found = status == 'OK' and bool(data and data[0].split())
        print('IMAP search attempt', attempt, ':', 'found' if found else 'not found')
        if found:
            break
        time.sleep(2)
    if not found:
        fail('submitted message was not found in timur INBOX')
    print('[OK] local message retrieved through IMAPS')
except ssl.SSLCertVerificationError as error:
    fail('TLS certificate validation failed: ' + str(error))
except (smtplib.SMTPException, imaplib.IMAP4.error, OSError) as error:
    fail(type(error).__name__ + ': ' + str(error))
PY
python3 \"\$py\" mail.nova.a6.test Skill39@A6 Skill39@A6; rc=\$?; rm -f \"\$py\"; trap - EXIT INT TERM; [ \$rc -eq 0 ] && echo A6_OK; exit \$rc" ;;
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
