#!/usr/bin/env bash
# A3 remote evaluator. Recommended launch point: admin-a3 (10.33.20.20).

set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/a3-common.sh"

A3_HOSTS_FILE="${A3_HOSTS_FILE:-$SCRIPT_DIR/a3-hosts.conf}"
A3_START_FROM="${A3_START_FROM:-A3.1.1}"
A3_POST_REBOOT="${A3_POST_REBOOT:-0}"

usage() {
  cat <<'EOF'
Usage: sudo bash remote/a3-evaluate-remote.sh [options]
  --no-pause              do not pause after each criterion
  --pause                 pause after each criterion (default)
  --start-from A3.4.6     resume from a criterion
  --report-dir DIR        report output directory
  --post-reboot           include persistence/restart checks
  --hosts-file FILE       override host map
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --no-pause) A3_PAUSE=0 ;;
    --pause) A3_PAUSE=1 ;;
    --post-reboot) A3_POST_REBOOT=1 ;;
    --start-from) shift; A3_START_FROM="${1:?missing --start-from value}" ;;
    --report-dir) shift; A3_REPORT_DIR="${1:?missing --report-dir value}" ;;
    --hosts-file) shift; A3_HOSTS_FILE="${1:?missing --hosts-file value}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

A3_RESULTS_TSV="$A3_REPORT_DIR/a3-results.tsv"
A3_DETAIL_LOG="$A3_REPORT_DIR/a3-detail.log"
mkdir -p "$A3_REPORT_DIR"
printf 'CriterionID\tMaxMark\tStatus\tMessage\n' > "$A3_RESULTS_TSV"
: > "$A3_DETAIL_LOG"

declare -A HOST_IP
while IFS='=' read -r name ip; do
  [[ "$name" =~ ^[[:space:]]*# ]] && continue
  [ -n "$name" ] && [ -n "$ip" ] && HOST_IP["$name"]="$ip"
done < "$A3_HOSTS_FILE"

PERSISTENCE_IDS=' A3.1.12 A3.2.14 A3.3.12 A3.4.14 A3.5.13 A3.7.9 A3.8.11 '

ssh_precheck() {
  section "Предварительная проверка root SSH с admin-a3"
  local name ip out
  for name in branch-fw-a3 branch-user-a3 hq-fw-a3 admin-a3 proxy-a3 app-a3 log-a3; do
    ip="${HOST_IP[$name]:-}"
    printf '%-18s %-15s ' "$name" "$ip"
    out="$(timeout "$A3_TIMEOUT" ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o ConnectTimeout="$A3_TIMEOUT" root@"$ip" 'hostname -s' 2>&1)"
    if grep -Fqx "$name" <<<"$out"; then echo -e "${GREEN}OK${NC}"
    else echo -e "${YELLOW}NO KEY ACCESS${NC}: $out"; fi
  done
}

override_persistence_command() {
  case "$1" in
    A3.1.12) cat <<'EOF'
for h in 10.33.10.1 10.33.10.20 10.33.20.1 10.33.20.20 10.33.30.10 10.33.40.10 10.33.40.20; do echo ===$h===; ssh root@$h 'ip -br address; ip route show default; ip -6 route show default'; done
ssh root@10.33.10.1 'sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding'; ssh root@10.33.20.1 'sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding'
EOF
      ;;
    A3.2.14) echo "ssh root@10.33.40.10 'systemctl restart bind9 2>/dev/null || systemctl restart named; dig @127.0.0.1 nova.a3.test SOA +short'" ;;
    A3.3.12) echo "ssh root@10.33.40.10 'systemctl restart nginx'; ssh root@10.33.10.20 'curl -fsS https://portal.nova.a3.test/'" ;;
    A3.4.14) echo "ssh root@10.33.40.20 'systemctl restart a3-app 2>/dev/null || systemctl restart a3-app.service'; ssh root@10.33.40.10 'systemctl restart nginx'; ssh root@10.33.20.20 'curl -fsS https://portal.nova.a3.test/app; curl -fsS https://portal.nova.a3.test/healthz'" ;;
    A3.5.13) echo "ssh root@10.33.20.1 'systemctl restart wg-quick@wg0'; ssh root@10.33.10.20 'systemctl restart wg-quick@wg0; ping -c2 10.233.3.1; wg show'" ;;
    A3.7.9) echo "ssh root@10.33.30.10 'systemctl restart rsyslog'; ssh root@10.33.40.20 'logger -t a3_app A3_LOG_RESTART_TEST'; sleep 2; ssh root@10.33.30.10 'grep -R A3_LOG_RESTART_TEST /var/log/remote 2>/dev/null'" ;;
    A3.8.11) cat <<'EOF'
ssh root@10.33.20.20 'dig +short portal.nova.a3.test; curl -fsS https://portal.nova.a3.test/; nft list ruleset >/dev/null'
ssh root@10.33.10.20 'ping -c2 10.233.3.1; wg show'
ssh root@10.33.30.10 'test -s /var/log/remote/proxy-a3.log'
EOF
      ;;
  esac
}

run_command() {
  local command="$1" tmp
  tmp="$(mktemp)"
  { echo '#!/usr/bin/env bash'; echo 'set -o pipefail'; printf '%s\n' "$command"; } > "$tmp"
  chmod 700 "$tmp"
  if command -v timeout >/dev/null 2>&1; then
    A3_LAST_OUT="$(timeout "$A3_CMD_TIMEOUT" bash "$tmp" </dev/null 2>&1)"; A3_LAST_RC=$?
  else
    A3_LAST_OUT="$(bash "$tmp" </dev/null 2>&1)"; A3_LAST_RC=$?
  fi
  rm -f "$tmp"
}

filter_output() {
  local out="$1" lines filtered
  lines="$(wc -l <<<"$out")"
  filtered="$(grep -Ei 'active|enabled|listening|LISTEN|UNCONN|10\.33\.|192\.0\.2\.|2001:db8:a3|10\.233\.3|fd00:a3:wg|nova\.a3\.test|branch-|hq-|admin-|proxy-|app-|log-|default|forward|SOA|NS|CNAME|PTR|REFUSED|status:|NOERROR|NXDOMAIN|SERVFAIL|subject=|issuer=|CA:TRUE|Certificate Sign|CRL Sign|Server Authentication|DNS:|Verify return code|ssl_verify_result|HTTP/|Location:|A3_|OK|PASS|FAIL|peer:|interface: wg0|latest handshake|allowed ips|transfer:|policy drop|reject|succeeded|refused|timed out|No route|Permission denied|/var/log/remote|root:|syslog:|nginx|8080|514|51820|Command:|Result:|none' <<<"$out" | sed -n '1,220p' || true)"
  if [ -n "$filtered" ]; then printf '%s\n' "$filtered"; [ "$lines" -le 220 ] || echo "... filtered from $lines lines ..."
  else sed -n '1,160p' <<<"$out"; fi
}

no_successful_connect() { ! grep -Eiq 'succeeded|open|A3_(APP|PORTAL)_|bytes from' <<<"$1"; }

evaluate_result() {
  local id="$1" o="$2" rc="$3"
  case "$id" in
    A3.1.1) contains_all "$o" branch-fw-a3 branch-user-a3 hq-fw-a3 admin-a3 proxy-a3 app-a3 log-a3 ;;
    A3.1.2) contains_all "$o" 10.33.10.1 10.33.10.20 192.0.2.10 192.0.2.20 10.33.20.1 10.33.20.20 10.33.30.1 10.33.30.10 10.33.40.1 10.33.40.10 10.33.40.20 ;;
    A3.1.3) contains_all "$o" 2001:db8:a3:10::1 2001:db8:a3:10::20 2001:db8:a3:100::10 2001:db8:a3:100::20 2001:db8:a3:20::1 2001:db8:a3:20::20 2001:db8:a3:30::1 2001:db8:a3:30::10 2001:db8:a3:40::1 2001:db8:a3:40::10 2001:db8:a3:40::20 ;;
    A3.1.4) contains_all "$o" 10.33.10.1 10.33.20.1 10.33.30.1 10.33.40.1 ;;
    A3.1.5) contains_all "$o" 10.33.20.0/24 10.33.30.0/24 10.33.40.0/24 192.0.2.20 10.33.10.0/24 192.0.2.10 ;;
    A3.1.6) contains_all "$o" 2001:db8:a3:20::/64 2001:db8:a3:30::/64 2001:db8:a3:40::/64 2001:db8:a3:100::20 2001:db8:a3:10::/64 2001:db8:a3:100::10 ;;
    A3.1.7) [ "$(count_regex "$o" 'net\.ipv4\.ip_forward *= *1')" -ge 4 ] ;;
    A3.1.8) [ "$(count_regex "$o" 'net\.ipv6\.conf\.all\.forwarding *= *1')" -ge 4 ] ;;
    A3.1.9|A3.1.10) [ "$rc" -eq 0 ] && [ "$(count_regex "$o" '0% packet loss')" -ge 2 ] ;;
    A3.1.11) grep -Eq '10\.33\.10\.20\.[0-9]+|10\.33\.10\.20 >' <<<"$o" && ! grep -Eq '192\.0\.2\.20\.[0-9]+|10\.33\.40\.1\.[0-9]+' <<<"$o" ;;
    A3.1.12) [ "$rc" -eq 0 ] && contains_all "$o" 10.33.10.1 10.33.20.1 net.ipv4.ip_forward net.ipv6.conf.all.forwarding ;;
    A3.1.13) ! regex_any "$o" 'https?://(deb\.|archive\.|security\.|ftp\.)|deb\.debian\.org|ubuntu\.com' ;;

    A3.2.1) regex_all "$o" 'active' '(:53|53/)' ;;
    A3.2.2) regex_all "$o" 'SOA' 'NS' && ! regex_any "$o" 'SERVFAIL|NXDOMAIN' ;;
    A3.2.3) contains_all "$o" 10.33.10.1 10.33.10.20 10.33.20.1 10.33.20.20 10.33.30.10 10.33.40.10 10.33.40.20 ;;
    A3.2.4) contains_all "$o" 2001:db8:a3:10::1 2001:db8:a3:10::20 2001:db8:a3:20::1 2001:db8:a3:20::20 2001:db8:a3:30::10 2001:db8:a3:40::10 2001:db8:a3:40::20 ;;
    A3.2.5) contains_all "$o" 192.0.2.10 192.0.2.20 10.33.20.1 10.33.30.1 10.33.40.1 ;;
    A3.2.6) contains_all "$o" 10.233.3.1 10.233.3.10 ;;
    A3.2.7) [ "$(count_regex "$o" 'proxy-a3\.nova\.a3\.test')" -ge 2 ] ;;
    A3.2.8) [ "$(count_regex "$o" 'nova\.a3\.test')" -ge 11 ] ;;
    A3.2.9) contains_all "$o" hq-fw-wg-a3 branch-user-wg-a3 ;;
    A3.2.10) ! grep -Eiq 'REFUSED' <<<"$o" && [ -n "$o" ] ;;
    A3.2.11) regex_any "$o" 'REFUSED|timed out|no servers could be reached' && ! regex_any "$o" 'status: NOERROR' ;;
    A3.2.12) [ "$(count_regex "$o" '10\.33\.40\.10|127\.0\.0\.1')" -ge 7 ] ;;
    A3.2.13) contains_all "$o" proxy-a3 app-a3 log-a3 ;;
    A3.2.14) [ "$rc" -eq 0 ] && regex_any "$o" 'SOA|proxy-a3' ;;
    A3.2.15) ! regex_any "$o" '8\.8\.8\.8|1\.1\.1\.1|9\.9\.9\.9' ;;

    A3.3.1) regex_any "$o" 'CN ?= ?Nova A3 Root CA|CN=Nova A3 Root CA' ;;
    A3.3.2) regex_all "$o" 'CA:TRUE' 'Certificate Sign|keyCertSign' 'CRL Sign|cRLSign' ;;
    A3.3.3) regex_any "$o" '(^|[[:space:]])(600|640)[[:space:]]+root' && ! regex_any "$o" 'BEGIN (RSA )?PRIVATE KEY' ;;
    A3.3.4) regex_any "$o" ': OK|OK$' ;;
    A3.3.5) contains_all "$o" DNS:proxy-a3.nova.a3.test DNS:portal.nova.a3.test DNS:www.nova.a3.test ;;
    A3.3.6) regex_any "$o" 'TLS Web Server Authentication|serverAuth' && ! grep -Fq 'CA:TRUE' <<<"$o" ;;
    A3.3.7) [ "$(count_regex "$o" 'ssl_verify_result[^0-9]*0|Verify return code: 0')" -ge 2 ] ;;
    A3.3.8) [ "$rc" -eq 0 ] && [ "$(count_regex "$o" 'Nova A3 Root CA|nova.*\.crt|ca-certificates')" -ge 2 ] ;;
    A3.3.9) [ "$rc" -eq 0 ] && [ "$(count_regex "$o" '^A3_PORTAL_OK$')" -ge 2 ] ;;
    A3.3.10) regex_all "$o" 'HTTP/.*30(1|2|8)' 'Location: https://portal\.nova\.a3\.test' ;;
    A3.3.11) regex_all "$o" 'openssl|curl' 'verify|SAN|subjectAltName|ssl_verify_result' ;;
    A3.3.12) [ "$rc" -eq 0 ] && grep -Fq A3_PORTAL_OK <<<"$o" ;;

    A3.4.1) regex_any "$o" 'LISTEN.*:8080|:8080.*LISTEN' ;;
    A3.4.2) grep -Fxq A3_APP_INTERNAL_OK <<<"$o" ;;
    A3.4.3) grep -Fxq OK <<<"$o" ;;
    A3.4.4|A3.4.11|A3.6.5) no_successful_connect "$o" ;;
    A3.4.5) regex_all "$o" 'active' ':80' ':443' ;;
    A3.4.6) grep -Fxq A3_PORTAL_OK <<<"$o" ;;
    A3.4.7) grep -Fxq A3_APP_INTERNAL_OK <<<"$o" ;;
    A3.4.8) grep -Fxq OK <<<"$o" ;;
    A3.4.9) regex_all "$o" 'HTTP/.*30(1|2|8)' 'Location: https://' ;;
    A3.4.10) regex_all "$o" 'proxy_pass' 'app-a3|10\.33\.40\.20' '8080' && ! regex_any "$o" 'https?://[^ ;]*(debian|ubuntu|github)' ;;
    A3.4.12) regex_all "$o" 'access\.log' 'error\.log' ;;
    A3.4.13) regex_all "$o" 'syntax is ok|test is successful' '8080' ;;
    A3.4.14) [ "$rc" -eq 0 ] && contains_all "$o" A3_APP_INTERNAL_OK OK ;;
    A3.4.15) regex_all "$o" 'issuer=.*Nova A3 Root CA' 'subject=' ;;

    A3.5.1) [ "$(count_regex "$o" 'interface: wg0|active|enabled')" -ge 2 ] && [ "$(count_regex "$o" 'peer:')" -ge 2 ] ;;
    A3.5.2) contains_all "$o" 10.233.3.1 fd00:a3:wg::1 ;;
    A3.5.3) contains_all "$o" 10.233.3.10 fd00:a3:wg::10 ;;
    A3.5.4) regex_any "$o" '51820' && ! regex_any "$o" 'Connection refused|No route' ;;
    A3.5.5) regex_all "$o" 'peer:' 'latest handshake:' 'transfer:' && ! regex_any "$o" 'latest handshake: *(never|$)' ;;
    A3.5.6) contains_all "$o" 10.233.3.1/32 fd00:a3:wg::1/128 && ! regex_any "$o" '0\.0\.0\.0/0|::/0|10\.33\.(20|30|40)\.0/24' ;;
    A3.5.7) ! grep -E '10\.33\.(30|40)\..*dev wg0' <<<"$o" ;;
    A3.5.8) grep -Fq hq-fw-a3 <<<"$o" ;;
    A3.5.9) grep -Fq proxy-a3 <<<"$o" ;;
    A3.5.10) contains_all "$o" app-a3 log-a3 ;;
    A3.5.11|A3.6.6|A3.6.12|A3.6.13) no_successful_connect "$o" ;;
    A3.5.12) [ "$rc" -eq 0 ] && grep -Fq '0% packet loss' <<<"$o" ;;
    A3.5.13) [ "$rc" -eq 0 ] && regex_all "$o" '0% packet loss' 'peer:' ;;
    A3.5.14) ! grep -Ei 'masquerade|snat' <<<"$o" | grep -Eiq 'wg0|10\.233\.3|fd00:a3:wg' ;;

    A3.6.1|A3.6.2) regex_all "$o" 'active' 'table|chain|hook' ;;
    A3.6.3) regex_any "$o" 'policy drop|reject|drop' ;;
    A3.6.4) [ "$rc" -eq 0 ] && regex_all "$o" '53.*succeeded|open.*53|status: NOERROR' '80.*succeeded|HTTP/.*30' '443.*succeeded|A3_PORTAL_OK' ;;
    A3.6.7) grep -Fq hq-fw-a3 <<<"$o" ;;
    A3.6.8) contains_all "$o" proxy-a3 app-a3 log-a3 ;;
    A3.6.9) contains_all "$o" branch-fw-a3 branch-user-a3 hq-fw-a3 proxy-a3 app-a3 log-a3 ;;
    A3.6.10) regex_any "$o" 'succeeded|open' && grep -Fxq OK <<<"$o" ;;
    A3.6.11) [ "$(count_regex "$o" 'succeeded|open')" -ge 4 ] ;;
    A3.6.14) ! regex_any "$o" 'refused|No route|timed out' ;;
    A3.6.15) [ "$(count_regex "$o" '0% packet loss')" -ge 4 ] ;;
    A3.6.16) contains_all "$o" A3-BR-DROP A3-HQ-DROP && [ "$(count_regex "$o" 'enabled')" -ge 2 ] ;;

    A3.7.1) regex_all "$o" 'active' ':514' ;;
    A3.7.2) contains_all "$o" branch-fw-a3.log hq-fw-a3.log ;;
    A3.7.3) contains_all "$o" proxy-a3.log app-a3.log ;;
    A3.7.4) regex_any "$o" 'A3-BR-DROP|A3-HQ-DROP' ;;
    A3.7.5) regex_all "$o" 'nginx|portal' '/app' ;;
    A3.7.6) regex_all "$o" 'nginx|error' '/var/log/remote|proxy-a3.log' ;;
    A3.7.7) grep -Fq A3_APP_LOG_TEST <<<"$o" ;;
    A3.7.8) regex_any "$o" 'root|syslog' && ! regex_any "$o" '(^|[[:space:]])(666|667|677|777)[[:space:]]' ;;
    A3.7.9) grep -Fq A3_LOG_RESTART_TEST <<<"$o" ;;
    A3.7.10) regex_all "$o" 'log-a3|/var/log/remote|A3-.*-DROP|nginx' 'PASS|FAIL|Result:' ;;

    A3.8.1) contains_all "$o" branch-fw-a3 branch-user-a3 hq-fw-a3 proxy-a3 app-a3 log-a3 ;;
    A3.8.2) regex_any "$o" '/opt/grading/a3' ;;
    A3.8.3) regex_any "$o" 'a3-selfcheck|#!/' ;;
    A3.8.4) regex_all "$o" 'route|routing' 'dig|dns' 'openssl|certificate' 'portal|curl' 'wg|WireGuard' 'nft|firewall' 'rsyslog|log-a3' ;;
    A3.8.5) regex_all "$o" 'Command:|команд' 'PASS|FAIL|Result' ;;
    A3.8.6) regex_all "$o" 'allow|positive' 'deny|negative' 'PASS|FAIL' ;;
    A3.8.7) regex_all "$o" 'interface:|hq-fw-a3' 'peer:|branch-user-a3' ;;
    A3.8.8) regex_all "$o" 'openssl|ssl_verify_result|verify return' 'SAN|subjectAltName|portal' ;;
    A3.8.9) [ -n "$(tr -d '[:space:]' <<<"$o")" ;;
    A3.8.11) [ "$rc" -eq 0 ] && contains_all "$o" A3_PORTAL_OK '0% packet loss' ;;
    *) [ "$rc" -eq 0 ] && [ -n "$o" ] && ! regex_any "$o" 'Permission denied|command not found|No such file|syntax error' ;;
  esac
}

should_run() {
  [ "$1" = "$A3_START_FROM" ] && A3_STARTED=1
  [ "${A3_STARTED:-0}" = 1 ]
}

validate_start_from() {
  awk -F'\t' -v id="$A3_START_FROM" 'NR>1 && $1==id {found=1} END {exit !found}' "$A3_CRITERIA_MAP" || {
    echo "Критерий --start-from '$A3_START_FROM' отсутствует в карте." >&2
    exit 2
  }
}

main() {
  validate_start_from
  echo -e "${CYAN}A3 remote evaluator — Secure Services Publishing and Remote Access${NC}"
  echo "Рекомендуемый хост запуска: admin-a3 (10.33.20.20)"
  echo "Отчеты: $A3_REPORT_DIR"
  ssh_precheck

  local id sub desc mark runfrom commands expected notes command display last_sub=""
  while IFS=$'\t' read -r id sub desc mark runfrom commands expected notes; do
    [ "$id" = CriterionID ] && continue
    [ -n "$id" ] || continue
    should_run "$id" || continue
    if [ "$sub" != "$last_sub" ]; then section "$sub"; last_sub="$sub"; fi
    if [ "$id" = A3.8.10 ]; then
      step "$id" "$desc"; skip "$id" "$mark" "справочная fallback-процедура, вес 0.00"; continue
    fi
    if [[ "$PERSISTENCE_IDS" == *" $id "* ]]; then
      if [ "$A3_POST_REBOOT" != 1 ]; then
        step "$id" "$desc"; skip "$id" "$mark" "используйте --post-reboot после согласованного restart/reboot"; continue
      fi
      command="$(override_persistence_command "$id")"
    else
      command="$(decode_newlines "$commands")"
    fi
    step "$id" "$desc"; cmd_show "$command"
    run_command "$command"
    display="$(filter_output "$A3_LAST_OUT")"
    show_output "$display"$'\n'"ExitCode=$A3_LAST_RC"
    if evaluate_result "$id" "$A3_LAST_OUT" "$A3_LAST_RC"; then
      pass "$id" "$mark" "фактический вывод соответствует ожидаемому результату"
    else
      fail "$id" "$mark" "фактический вывод не соответствует ожидаемому результату"
    fi
  done < "$A3_CRITERIA_MAP"
  write_summary
}

main "$@"
