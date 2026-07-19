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

# Human-readable commands are deliberately separated from the automatic
# assertion wrappers.  These lines can be copied to a shell one by one.
manual_commands_for() {
  local id="$1" automatic="$2"
  case "$id" in
    A3.1.7)
      printf '%s\n' \
        "ssh root@10.33.10.1 'sysctl net.ipv4.ip_forward'" \
        "ssh root@10.33.10.1 '/usr/lib/systemd/systemd-sysctl --cat-config | grep -nE \"(^# /.*\\.conf|^[[:space:]]*net\\.ipv4\\.ip_forward[[:space:]]*=)\"'" \
        "ssh root@10.33.20.1 'sysctl net.ipv4.ip_forward'" \
        "ssh root@10.33.20.1 '/usr/lib/systemd/systemd-sysctl --cat-config | grep -nE \"(^# /.*\\.conf|^[[:space:]]*net\\.ipv4\\.ip_forward[[:space:]]*=)\"'"
      ;;
    A3.1.8)
      printf '%s\n' \
        "ssh root@10.33.10.1 'sysctl net.ipv6.conf.all.forwarding'" \
        "ssh root@10.33.10.1 '/usr/lib/systemd/systemd-sysctl --cat-config | grep -nE \"(^# /.*\\.conf|^[[:space:]]*net\\.ipv6\\.conf\\.all\\.forwarding[[:space:]]*=)\"'" \
        "ssh root@10.33.20.1 'sysctl net.ipv6.conf.all.forwarding'" \
        "ssh root@10.33.20.1 '/usr/lib/systemd/systemd-sysctl --cat-config | grep -nE \"(^# /.*\\.conf|^[[:space:]]*net\\.ipv6\\.conf\\.all\\.forwarding[[:space:]]*=)\"'"
      ;;
    A3.1.1)
      printf '%s\n' \
        "ssh root@10.33.10.1 'hostnamectl --static'" \
        "ssh root@10.33.10.20 'hostnamectl --static'" \
        "ssh root@10.33.20.1 'hostnamectl --static'" \
        "ssh root@10.33.20.20 'hostnamectl --static'" \
        "ssh root@10.33.40.10 'hostnamectl --static'" \
        "ssh root@10.33.40.20 'hostnamectl --static'" \
        "ssh root@10.33.30.10 'hostnamectl --static'"
      ;;
    A3.2.3)
      printf '%s\n' \
        "ssh root@10.33.20.20 'dig @10.33.40.10 +short branch-fw-a3.nova.a3.test A'" \
        "ssh root@10.33.20.20 'dig @10.33.40.10 +short branch-user-a3.nova.a3.test A'" \
        "ssh root@10.33.20.20 'dig @10.33.40.10 +short hq-fw-a3.nova.a3.test A'" \
        "ssh root@10.33.20.20 'dig @10.33.40.10 +short admin-a3.nova.a3.test A'" \
        "ssh root@10.33.20.20 'dig @10.33.40.10 +short proxy-a3.nova.a3.test A'" \
        "ssh root@10.33.20.20 'dig @10.33.40.10 +short app-a3.nova.a3.test A'" \
        "ssh root@10.33.20.20 'dig @10.33.40.10 +short log-a3.nova.a3.test A'"
      ;;
    A3.5.8)
      printf '%s\n' "ssh root@10.33.10.20 'ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 root@10.233.3.1 hostname'"
      ;;
    A3.5.10)
      printf '%s\n' \
        "ssh root@10.33.10.20 'ssh -J root@10.233.3.1 -o BatchMode=yes -o ConnectTimeout=8 root@app-a3.nova.a3.test hostname'" \
        "ssh root@10.33.10.20 'ssh -J root@10.233.3.1 -o BatchMode=yes -o ConnectTimeout=8 root@log-a3.nova.a3.test hostname'"
      ;;
    A3.6.9)
      printf '%s\n' \
        "ssh root@10.33.20.20 'ssh -o BatchMode=yes -o ConnectTimeout=5 root@10.33.10.1 hostname'" \
        "ssh root@10.33.20.20 'ssh -o BatchMode=yes -o ConnectTimeout=5 root@10.33.10.20 hostname'" \
        "ssh root@10.33.20.20 'ssh -o BatchMode=yes -o ConnectTimeout=5 root@10.33.20.1 hostname'" \
        "ssh root@10.33.20.20 'ssh -o BatchMode=yes -o ConnectTimeout=5 root@10.33.40.10 hostname'" \
        "ssh root@10.33.20.20 'ssh -o BatchMode=yes -o ConnectTimeout=5 root@10.33.40.20 hostname'" \
        "ssh root@10.33.20.20 'ssh -o BatchMode=yes -o ConnectTimeout=5 root@10.33.30.10 hostname'"
      ;;
    A3.8.1)
      printf '%s\n' \
        "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 root@10.33.10.1 hostname" \
        "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 root@10.33.10.20 hostname" \
        "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 root@10.33.20.1 hostname" \
        "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 root@10.33.40.10 hostname" \
        "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 root@10.33.40.20 hostname" \
        "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 root@10.33.30.10 hostname"
      ;;
    A3.8.3)
      printf '%s\n' \
        "test -f /opt/a3-checks/a3-selfcheck.sh && echo FILE_EXISTS || echo FILE_NOT_FOUND" \
        "test -x /opt/a3-checks/a3-selfcheck.sh && echo EXECUTABLE || echo NOT_EXECUTABLE" \
        "ls -l /opt/a3-checks/a3-selfcheck.sh" \
        "head -40 /opt/a3-checks/a3-selfcheck.sh"
      ;;
    A3.8.11)
      printf '%s\n' \
        "dig +short portal.nova.a3.test A" \
        "curl -fsS --max-time 8 https://portal.nova.a3.test/" \
        "ssh root@10.33.10.1 'nft list ruleset | grep table'" \
        "ssh root@10.33.20.1 'nft list ruleset | grep table'" \
        "ssh root@10.33.10.20 'ping -c2 -W2 10.233.3.1; wg show wg0'" \
        "ssh root@10.33.30.10 'test -s /var/log/remote/proxy-a3.log && echo LOG_PRESENT || echo LOG_MISSING'"
      ;;
    *) printf '%s\n' "$automatic" ;;
  esac
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
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      -o ConnectTimeout="$A3_TIMEOUT" root@"$ip" 'hostname -s' 2>&1)"
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
check_component() { name="$1"; shift; out=$("$@" 2>&1); code=$?; printf '%s\n' "$out"; if [ "$code" -eq 0 ]; then echo "PERSISTENCE_OK $name"; printf '\033[32mDEVICE %-18s: PASS\033[0m\n' "$name"; else echo "PERSISTENCE_FAIL $name exit=$code"; printf '\033[31mDEVICE %-18s: FAIL\033[0m\n' "$name"; return 1; fi; }
rc=0
check_component dns bash -c 'got=$(dig +short portal.nova.a3.test A); echo "DNS actual=$got expected=10.33.40.10"; [ "$got" = 10.33.40.10 ]' || rc=1
check_component portal bash -c 'got=$(curl -fsS --max-time 8 https://portal.nova.a3.test/ | tr -d "\r\n"); echo "Portal body actual=$got expected=A3_PORTAL_OK"; [ "$got" = A3_PORTAL_OK ]' || rc=1
check_component branch-firewall command ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8 root@10.33.10.1 'nft list ruleset | grep table | head -20' || rc=1
check_component hq-firewall command ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8 root@10.33.20.1 'nft list ruleset | grep table | head -20' || rc=1
check_component wireguard command ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8 root@10.33.10.20 'ping -c2 -W2 10.233.3.1 && wg show wg0' || rc=1
check_component central-log command ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8 root@10.33.30.10 'ls -lh /var/log/remote/proxy-a3.log && test -s /var/log/remote/proxy-a3.log' || rc=1
exit "$rc"
EOF
      ;;
  esac
}

run_command() {
  local command="$1" criterion_id="$2" tmp out_file pipe_status
  tmp="$(mktemp)"
  out_file="$(mktemp)"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -o pipefail'
    printf 'A3_CURRENT_ID=%q\n' "$criterion_id"
    case "$criterion_id" in
      A3.7.*) echo 'A3_SSH_TIMEOUT=15' ;;
      *) printf 'A3_SSH_TIMEOUT=%q\n' "$A3_TIMEOUT" ;;
    esac
    # Every local SSH launched by a How-to-Mark command is non-interactive and
    # bounded. This prevents one unavailable host from freezing a criterion.
    cat <<EOF
ssh() {
  local arg target=unknown device rc semantic_rc expected item ssh_out count
  # The last user@host argument is the actual SSH destination (not ProxyJump).
  for arg in "\$@"; do
    case "\$arg" in
      *@*)
        # A quoted remote command may itself contain user@host plus spaces.
        # Only a standalone SSH destination argument is accepted here.
        case "\$arg" in *[[:space:]]*) ;; *) target="\${arg##*@}" ;; esac
        ;;
    esac
  done
  target="\${target#[}"
  target="\${target%]}"
  case "\$target" in
    10.33.10.1|branch-fw-a3|branch-fw-a3.nova.a3.test) device=branch-fw-a3 ;;
    10.33.10.20|branch-user-a3|branch-user-a3.nova.a3.test) device=branch-user-a3 ;;
    10.33.20.1|hq-fw-a3|hq-fw-a3.nova.a3.test) device=hq-fw-a3 ;;
    10.33.20.20|admin-a3|admin-a3.nova.a3.test) device=admin-a3 ;;
    10.33.40.10|proxy-a3|proxy-a3.nova.a3.test) device=proxy-a3 ;;
    10.33.40.20|app-a3|app-a3.nova.a3.test) device=app-a3 ;;
    10.33.30.10|log-a3|log-a3.nova.a3.test) device=log-a3 ;;
    *) device="\$target" ;;
  esac
  ssh_out="\$(mktemp)"
  command timeout "\${A3_SSH_TIMEOUT}s" /usr/bin/ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=${A3_TIMEOUT} -o ConnectionAttempts=1 -o ServerAliveInterval=2 -o ServerAliveCountMax=2 -o GSSAPIAuthentication=no "\$@" 2>&1 | tee "\$ssh_out"
  rc=\${PIPESTATUS[0]}
  semantic_rc=\$rc
  expected=''
  case "\$A3_CURRENT_ID:\$device" in
    A3.1.1:*) expected="\$device" ;;
    A3.1.2:branch-fw-a3) expected='10.33.10.1/24 192.0.2.10/24' ;;
    A3.1.2:branch-user-a3) expected='10.33.10.20/24' ;;
    A3.1.2:hq-fw-a3) expected='192.0.2.20/24 10.33.20.1/24 10.33.30.1/24 10.33.40.1/24' ;;
    A3.1.2:admin-a3) expected='10.33.20.20/24' ;;
    A3.1.2:proxy-a3) expected='10.33.40.10/24' ;;
    A3.1.2:app-a3) expected='10.33.40.20/24' ;;
    A3.1.2:log-a3) expected='10.33.30.10/24' ;;
    A3.1.3:branch-fw-a3) expected='2001:db8:a3:10::1/64 2001:db8:a3:100::10/64' ;;
    A3.1.3:branch-user-a3) expected='2001:db8:a3:10::20/64' ;;
    A3.1.3:hq-fw-a3) expected='2001:db8:a3:100::20/64 2001:db8:a3:20::1/64 2001:db8:a3:30::1/64 2001:db8:a3:40::1/64' ;;
    A3.1.3:admin-a3) expected='2001:db8:a3:20::20/64' ;;
    A3.1.3:proxy-a3) expected='2001:db8:a3:40::10/64' ;;
    A3.1.3:app-a3) expected='2001:db8:a3:40::20/64' ;;
    A3.1.3:log-a3) expected='2001:db8:a3:30::10/64' ;;
    A3.1.4:branch-user-a3) expected='10.33.10.1' ;;
    A3.1.4:admin-a3) expected='10.33.20.1' ;;
    A3.1.4:proxy-a3|A3.1.4:app-a3) expected='10.33.40.1' ;;
    A3.1.4:log-a3) expected='10.33.30.1' ;;
    A3.3.9:branch-user-a3|A3.3.9:admin-a3) expected='A3_PORTAL_OK' ;;
  esac
  if [ "\$semantic_rc" -eq 0 ] && [ -n "\$expected" ]; then
    for item in \$expected; do
      grep -Fq "\$item" "\$ssh_out" || semantic_rc=1
    done
  fi
  # Some remote compound checks already print a result for every nested target.
  # Do not add a duplicate result for the outer transport host in that case.
  if grep -Eq 'DEVICE .*: (PASS|FAIL)' "\$ssh_out"; then
    rm -f "\$ssh_out"
    return "\$rc"
  fi
  if [ "\$semantic_rc" -eq 0 ]; then
    printf '\033[32mDEVICE %-18s (%s): PASS\033[0m\n' "\$device" "\$target"
    printf '  Причина: команда на устройстве завершилась успешно (exit=0).\n'
  else
    if [ "\$rc" -ne 0 ]; then
      printf '\033[31mDEVICE %-18s (%s): FAIL [ssh exit=%s]\033[0m\n' "\$device" "\$target" "\$rc"
      case "\$rc" in
        124) printf '  Причина: превышено время ожидания %s секунд; устройство или команда не ответили вовремя.\n' "\$A3_SSH_TIMEOUT" ;;
        255) printf '  Причина: SSH не установил сеанс; проверьте маршрут, host key и аутентификацию.\n' ;;
        127) printf '  Причина: проверочная команда отсутствует на устройстве.\n' ;;
        *) printf '  Причина: команда завершилась с ненулевым кодом %s. Последние строки ошибки показаны выше.\n' "\$rc" ;;
      esac
    else
      printf '\033[31mDEVICE %-18s (%s): FAIL [нет ожидаемого: %s]\033[0m\n' "\$device" "\$target" "\$expected"
      printf '  Причина: SSH работает, но обязательное значение не найдено в выводе.\n'
    fi
  fi
  rm -f "\$ssh_out"
  return "\$rc"
}
EOF
    printf '%s\n' "$command"
  } > "$tmp"
  chmod 700 "$tmp"
  echo -e "${BLUE}Полный фактический вывод (stdout/stderr):${NC}"
  if command -v timeout >/dev/null 2>&1; then
    timeout "$A3_CMD_TIMEOUT" bash "$tmp" </dev/null 2>&1 \
      | tee -a "$A3_DETAIL_LOG" "$out_file"
    pipe_status=("${PIPESTATUS[@]}")
    A3_LAST_RC="${pipe_status[0]}"
  else
    bash "$tmp" </dev/null 2>&1 \
      | tee -a "$A3_DETAIL_LOG" "$out_file"
    pipe_status=("${PIPESTATUS[@]}")
    A3_LAST_RC="${pipe_status[0]}"
  fi
  A3_LAST_OUT="$(cat "$out_file")"
  if [ ! -s "$out_file" ]; then echo "(пустой вывод)"; fi
  rm -f "$tmp" "$out_file"
}

A3_EVIDENCE_RE='active|enabled|listening|LISTEN|UNCONN|10\.33\.|192\.0\.2\.|2001:db8:a3|10\.233\.3|fd00:a3:|IPV4_FORWARD_|IPV6_FORWARD_|DNS_SOA_|DNS_NS_|ALLOWED_IPS_|SSH_WG_|SSH_JUMP_|WG_SSH_PORT_|ADMIN_SSH_|BACKEND_TCP_|BACKEND_HEALTH_|ACCESS_EVENT_|LOG_EVIDENCE_|DNS_ALLOWED_|HTTP_ALLOWED_|HTTPS_ALLOWED_|nova\.a3\.test|branch-|hq-|admin-|proxy-|app-|log-|default|forward|SOA|NS|CNAME|PTR|REFUSED|status:|flags:|DNS_RECURSION|ROOT_CA_|PRIVATE_KEY|PORTAL_CERT_VERIFY|PORTAL_CONTENT_|TLS_VERIFY_|HEALTHZ_|APP_PROXY_|HTTP_STATUS=|CERTIFICATE=|NOERROR|NXDOMAIN|SERVFAIL|subject=|issuer=|CA:TRUE|Certificate Sign|CRL Sign|Server Authentication|DNS:|Verify return code|ssl_verify_result|HTTP/|Location:|A3_|OK|PASS|FAIL|peer:|interface: wg0|latest handshake|allowed ips|transfer:|policy drop|reject|succeeded|refused|timed out|No route|Permission denied|/var/log/remote|root:|syslog:|nginx|8080|514|51820|Command:|Result:|none|packet loss|bytes from|ExitCode'

filter_output() {
  local out="$1" lines filtered
  lines="$(wc -l <<<"$out")"
  filtered="$(grep -Ei 'active|enabled|listening|LISTEN|UNCONN|10\.33\.|192\.0\.2\.|2001:db8:a3|10\.233\.3|fd00:a3:wg|nova\.a3\.test|branch-|hq-|admin-|proxy-|app-|log-|default|forward|SOA|NS|CNAME|PTR|REFUSED|status:|NOERROR|NXDOMAIN|SERVFAIL|subject=|issuer=|CA:TRUE|Certificate Sign|CRL Sign|Server Authentication|DNS:|Verify return code|ssl_verify_result|HTTP/|Location:|A3_|OK|PASS|FAIL|peer:|interface: wg0|latest handshake|allowed ips|transfer:|policy drop|reject|succeeded|refused|timed out|No route|Permission denied|/var/log/remote|root:|syslog:|nginx|8080|514|51820|Command:|Result:|none' <<<"$out" | sed -n '1,220p' || true)"
  if [ -n "$filtered" ]; then printf '%s\n' "$filtered"; [ "$lines" -le 220 ] || echo "... filtered from $lines lines ..."
  else sed -n '1,160p' <<<"$out"; fi
}

device_counts() {
  # Return: "passed failed" for unique DEVICE names. Any FAIL overrides PASS
  # when one device has several checks inside the same criterion.
  awk '
    /DEVICE[[:space:]]/ {
      line=$0
      gsub(/\033\[[0-9;]*m/, "", line)
      sub(/^.*DEVICE[[:space:]]+/, "", line)
      split(line, fields, /[[:space:]]+/)
      dev=fields[1]
      if (line ~ /:[[:space:]]+FAIL([[:space:]]|$)/) state[dev]="FAIL"
      else if (line ~ /:[[:space:]]+PASS([[:space:]]|$)/ && state[dev]!="FAIL") state[dev]="PASS"
    }
    END {
      for (d in state) if (state[d]=="PASS") pass_count++; else if (state[d]=="FAIL") fail_count++
      printf "%d %d\n", pass_count+0, fail_count+0
    }' <<<"$1"
}

failed_device_list() {
  awk '
    /DEVICE[[:space:]]/ {
      line=$0; gsub(/\033\[[0-9;]*m/, "", line)
      sub(/^.*DEVICE[[:space:]]+/, "", line); split(line, fields, /[[:space:]]+/); dev=fields[1]
      if (line ~ /:[[:space:]]+FAIL([[:space:]]|$)/) state[dev]="FAIL"
      else if (line ~ /:[[:space:]]+PASS([[:space:]]|$)/ && state[dev]!="FAIL") state[dev]="PASS"
    }
    END { for (d in state) if (state[d]=="FAIL") { if (out!="") out=out", "; out=out d } print out }' <<<"$1"
}

failure_reason() {
  local out="$1" rc="$2" expected="$3" devices
  devices="$(failed_device_list "$out")"
  if [ -n "$devices" ]; then
    printf 'не прошли устройства: %s. Ожидалось: %s' "$devices" "$expected"
  elif [ "$rc" -eq 124 ]; then
    printf 'превышено время выполнения критерия. Ожидалось: %s' "$expected"
  elif [ "$rc" -ne 0 ]; then
    printf 'проверочная команда завершилась с exit=%s. Ожидалось: %s' "$rc" "$expected"
  else
    printf 'обязательные признаки не найдены в фактическом выводе. Ожидалось: %s' "$expected"
  fi
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
    A3.1.7) contains_all "$o" "IPV4_FORWARD_OK branch-fw-a3" "IPV4_FORWARD_OK hq-fw-a3" && ! grep -Fq IPV4_FORWARD_FAIL <<<"$o" ;;
    A3.1.8) contains_all "$o" "IPV6_FORWARD_OK branch-fw-a3" "IPV6_FORWARD_OK hq-fw-a3" && ! grep -Fq IPV6_FORWARD_FAIL <<<"$o" ;;
    A3.1.9|A3.1.10) [ "$rc" -eq 0 ] && [ "$(count_regex "$o" '0% packet loss')" -ge 2 ] ;;
    A3.1.11) grep -Eq '10\.33\.10\.20\.[0-9]+|10\.33\.10\.20 >' <<<"$o" && ! grep -Eq '192\.0\.2\.20\.[0-9]+|10\.33\.40\.1\.[0-9]+' <<<"$o" ;;
    A3.1.12) [ "$rc" -eq 0 ] && contains_all "$o" 10.33.10.1 10.33.20.1 net.ipv4.ip_forward net.ipv6.conf.all.forwarding ;;
    A3.1.13) ! regex_any "$o" 'https?://(deb\.|archive\.|security\.|ftp\.)|deb\.debian\.org|ubuntu\.com' ;;

    A3.2.1) regex_all "$o" 'active' '(:53|53/)' ;;
    A3.2.2) contains_all "$o" DNS_SOA_OK DNS_NS_OK && ! regex_any "$o" 'DNS_SOA_FAIL|DNS_NS_FAIL|SERVFAIL|NXDOMAIN' ;;
    A3.2.3) contains_all "$o" "DNS_A_OK branch-fw-a3" "DNS_A_OK branch-user-a3" "DNS_A_OK hq-fw-a3" "DNS_A_OK admin-a3" "DNS_A_OK proxy-a3" "DNS_A_OK app-a3" "DNS_A_OK log-a3" && ! grep -Fq 'DNS_A_FAIL' <<<"$o" ;;
    A3.2.4) contains_all "$o" 2001:db8:a3:10::1 2001:db8:a3:10::20 2001:db8:a3:20::1 2001:db8:a3:20::20 2001:db8:a3:30::10 2001:db8:a3:40::10 2001:db8:a3:40::20 ;;
    A3.2.5) contains_all "$o" 192.0.2.10 192.0.2.20 10.33.20.1 10.33.30.1 10.33.40.1 ;;
    A3.2.6) contains_all "$o" 10.233.3.1 10.233.3.10 ;;
    A3.2.7) [ "$(count_regex "$o" 'proxy-a3\.nova\.a3\.test')" -ge 2 ] ;;
    A3.2.8) [ "$(count_regex "$o" 'nova\.a3\.test')" -ge 11 ] ;;
    A3.2.9) contains_all "$o" hq-fw-wg-a3 branch-user-wg-a3 ;;
    A3.2.10) contains_all "$o" "DNS_RECURSION_OK branch-user-a3" "DNS_RECURSION_OK admin-a3" "DNS_RECURSION_OK app-a3" "DNS_RECURSION_OK log-a3" && ! grep -Fq DNS_RECURSION_FAIL <<<"$o" ;;
    A3.2.11) regex_any "$o" 'REFUSED|timed out|no servers could be reached' && ! regex_any "$o" 'status: NOERROR' ;;
    A3.2.12) [ "$(count_regex "$o" '10\.33\.40\.10|127\.0\.0\.1')" -ge 7 ] ;;
    A3.2.13) contains_all "$o" proxy-a3 app-a3 log-a3 ;;
    A3.2.14) [ "$rc" -eq 0 ] && regex_any "$o" 'SOA|proxy-a3' ;;
    A3.2.15) ! regex_any "$o" '8\.8\.8\.8|1\.1\.1\.1|9\.9\.9\.9' ;;

    A3.3.1) grep -Fq ROOT_CA_SUBJECT_OK <<<"$o" && regex_any "$o" 'CN[[:space:]]*=[[:space:]]*Nova A3 Root CA' ;;
    A3.3.2) regex_all "$o" 'CA:TRUE' 'Certificate Sign|keyCertSign' 'CRL Sign|cRLSign' ;;
    A3.3.3) grep -Fq PRIVATE_KEY_SECURITY_OK <<<"$o" && grep -Fq PRIVATE_KEY_WEB_NOT_EXPOSED <<<"$o" && ! grep -Fq PRIVATE_KEY_SECURITY_FAIL <<<"$o" ;;
    A3.3.4) grep -Fq PORTAL_CERT_VERIFY_OK <<<"$o" && ! grep -Fq PORTAL_CERT_VERIFY_FAIL <<<"$o" ;;
    A3.3.5) contains_all "$o" DNS:proxy-a3.nova.a3.test DNS:portal.nova.a3.test DNS:www.nova.a3.test ;;
    A3.3.6) contains_all "$o" PORTAL_CERT_FOUND PORTAL_EKU_OK PORTAL_BASIC_CONSTRAINTS_OK && ! regex_any "$o" 'PORTAL_CERT_NOT_FOUND|PORTAL_EKU_FAIL|PORTAL_BASIC_CONSTRAINTS_FAIL' ;;
    A3.3.7) contains_all "$o" "TLS_VERIFY_OK branch-user-a3" "TLS_VERIFY_OK admin-a3" && ! grep -Fq TLS_VERIFY_FAIL <<<"$o" ;;
    A3.3.8) [ "$rc" -eq 0 ] && [ "$(count_regex "$o" 'Nova A3 Root CA|nova.*\.crt|ca-certificates')" -ge 2 ] ;;
    A3.3.9) [ "$rc" -eq 0 ] && [ "$(count_regex "$o" '^A3_PORTAL_OK$')" -ge 2 ] ;;
    A3.3.10) regex_all "$o" 'HTTP/.*30(1|2|8)' 'Location: https://portal\.nova\.a3\.test' ;;
    A3.3.11) regex_all "$o" 'openssl|curl' 'verify|SAN|subjectAltName|ssl_verify_result' ;;
    A3.3.12) [ "$rc" -eq 0 ] && grep -Fq A3_PORTAL_OK <<<"$o" ;;

    A3.4.1) regex_any "$o" 'LISTEN.*:8080|:8080.*LISTEN' ;;
    A3.4.2) grep -Fxq A3_APP_INTERNAL_OK <<<"$o" ;;
    A3.4.3) grep -Fq HEALTHZ_OK <<<"$o" && grep -Fq HTTP_STATUS=200 <<<"$o" && ! grep -Fq HEALTHZ_FAIL <<<"$o" ;;
    A3.4.4|A3.4.11|A3.6.5) no_successful_connect "$o" ;;
    A3.4.5) regex_all "$o" 'active' ':80' ':443' ;;
    A3.4.6) grep -Fq PORTAL_CONTENT_OK <<<"$o" && grep -Fq HTTP_STATUS=200 <<<"$o" && ! grep -Fq PORTAL_CONTENT_FAIL <<<"$o" ;;
    A3.4.7) grep -Fq APP_PROXY_OK <<<"$o" && grep -Fq HTTP_STATUS=200 <<<"$o" && ! grep -Fq APP_PROXY_FAIL <<<"$o" ;;
    A3.4.8) grep -Fxq OK <<<"$o" ;;
    A3.4.9) regex_all "$o" 'HTTP/.*30(1|2|8)' 'Location: https://' ;;
    A3.4.10) regex_all "$o" 'proxy_pass' 'app-a3|10\.33\.40\.20' '8080' && ! regex_any "$o" 'https?://[^ ;]*(debian|ubuntu|github)' ;;
    A3.4.12) regex_all "$o" 'access\.log' 'error\.log' ;;
    A3.4.13) regex_all "$o" 'syntax is ok|test is successful' '8080' ;;
    A3.4.14) [ "$rc" -eq 0 ] && contains_all "$o" A3_APP_INTERNAL_OK OK ;;
    A3.4.15) regex_all "$o" 'issuer=.*Nova A3 Root CA' 'subject=' ;;

    A3.5.1) [ "$(count_regex "$o" 'interface: wg0|active|enabled')" -ge 2 ] && [ "$(count_regex "$o" 'peer:')" -ge 2 ] ;;
    A3.5.2) contains_all "$o" 10.233.3.1 fd00:a3:a3::1 ;;
    A3.5.3) contains_all "$o" 10.233.3.10 fd00:a3:a3::10 ;;
    A3.5.4) regex_any "$o" '51820' && ! regex_any "$o" 'Connection refused|No route' ;;
    A3.5.5) regex_all "$o" 'peer:' 'latest handshake:' 'transfer:' && ! regex_any "$o" 'latest handshake: *(never|$)' ;;
    A3.5.6) grep -Fq ALLOWED_IPS_OK <<<"$o" && ! grep -Fq ALLOWED_IPS_FAIL <<<"$o" ;;
    A3.5.7) ! grep -E '10\.33\.(30|40)\..*dev wg0' <<<"$o" ;;
    A3.5.8) grep -Fq SSH_WG_OK <<<"$o" && grep -Fq hq-fw-a3 <<<"$o" && ! grep -Fq SSH_WG_FAIL <<<"$o" ;;
    A3.5.9) grep -Fq proxy-a3 <<<"$o" ;;
    A3.5.10) contains_all "$o" "SSH_JUMP_OK app-a3" "SSH_JUMP_OK log-a3" && ! grep -Fq SSH_JUMP_FAIL <<<"$o" ;;
    A3.5.11|A3.6.6|A3.6.12|A3.6.13) no_successful_connect "$o" ;;
    A3.5.12) [ "$rc" -eq 0 ] && grep -Fq '0% packet loss' <<<"$o" ;;
    A3.5.13) [ "$rc" -eq 0 ] && regex_all "$o" '0% packet loss' 'peer:' ;;
    A3.5.14) ! grep -Ei 'masquerade|snat' <<<"$o" | grep -Eiq 'wg0|10\.233\.3|fd00:a3:wg' ;;

    A3.6.1|A3.6.2) regex_all "$o" 'active' 'table|chain|hook' ;;
    A3.6.3) regex_any "$o" 'policy drop|reject|drop' ;;
    A3.6.4) [ "$rc" -eq 0 ] && contains_all "$o" "DNS_ALLOWED_OK proxy-a3:53" "HTTP_ALLOWED_OK proxy-a3:80" "HTTPS_ALLOWED_OK proxy-a3:443" && ! regex_any "$o" 'DNS_ALLOWED_FAIL|HTTP_ALLOWED_FAIL|HTTPS_ALLOWED_FAIL' ;;
    A3.6.7) grep -Fq 'WG_SSH_PORT_OK 10.233.3.1:22' <<<"$o" && ! grep -Fq WG_SSH_PORT_FAIL <<<"$o" ;;
    A3.6.8) contains_all "$o" proxy-a3 app-a3 log-a3 ;;
    A3.6.9) [ "$rc" -eq 0 ] && contains_all "$o" "ADMIN_SSH_OK branch-fw-a3" "ADMIN_SSH_OK branch-user-a3" "ADMIN_SSH_OK hq-fw-a3" "ADMIN_SSH_OK proxy-a3" "ADMIN_SSH_OK app-a3" "ADMIN_SSH_OK log-a3" && ! grep -Fq ADMIN_SSH_FAIL <<<"$o" ;;
    A3.6.10) [ "$rc" -eq 0 ] && contains_all "$o" "BACKEND_TCP_OK app-a3:8080" BACKEND_HEALTH_OK && ! regex_any "$o" 'BACKEND_TCP_FAIL|BACKEND_HEALTH_FAIL' ;;
    A3.6.11) [ "$(count_regex "$o" 'succeeded|open')" -ge 4 ] ;;
    A3.6.14) ! regex_any "$o" 'refused|No route|timed out' ;;
    A3.6.15) [ "$(count_regex "$o" '0% packet loss')" -ge 4 ] ;;
    A3.6.16) contains_all "$o" A3-BR-DROP A3-HQ-DROP && [ "$(count_regex "$o" 'enabled')" -ge 2 ] ;;

    A3.7.1) regex_all "$o" 'active' ':514' ;;
    A3.7.2) contains_all "$o" branch-fw-a3.log hq-fw-a3.log ;;
    A3.7.3) contains_all "$o" proxy-a3.log app-a3.log ;;
    A3.7.4) regex_any "$o" 'A3-BR-DROP|A3-HQ-DROP' ;;
    A3.7.5) contains_all "$o" ACCESS_EVENT_GENERATED ACCESS_EVENT_LOG_OK && ! grep -Fq ACCESS_EVENT_LOG_FAIL <<<"$o" ;;
    A3.7.6) regex_all "$o" 'nginx|error' '/var/log/remote|proxy-a3.log' ;;
    A3.7.7) grep -Fq A3_APP_LOG_TEST <<<"$o" ;;
    A3.7.8) regex_any "$o" 'root|syslog' && ! regex_any "$o" '(^|[[:space:]])(666|667|677|777)[[:space:]]' ;;
    A3.7.9) grep -Fq A3_LOG_RESTART_TEST <<<"$o" ;;
    A3.7.10) contains_all "$o" LOG_EVIDENCE_CONTENT_OK LOG_EVIDENCE_RESULT_OK LOG_EVIDENCE_OK && ! regex_any "$o" 'LOG_EVIDENCE_CONTENT_FAIL|LOG_EVIDENCE_RESULT_FAIL|LOG_EVIDENCE_FAIL:' ;;

    A3.8.1) contains_all "$o" "ADMIN_KEY_OK branch-fw-a3" "ADMIN_KEY_OK branch-user-a3" "ADMIN_KEY_OK hq-fw-a3" "ADMIN_KEY_OK proxy-a3" "ADMIN_KEY_OK app-a3" "ADMIN_KEY_OK log-a3" && ! grep -Fq ADMIN_KEY_FAIL <<<"$o" ;;
    A3.8.2) regex_any "$o" '/opt/grading/a3' ;;
    A3.8.3) [ "$rc" -eq 0 ] && contains_all "$o" SELFCHECK_FOUND SELFCHECK_EXECUTABLE_OK && ! regex_any "$o" 'SELFCHECK_NOT_FOUND|SELFCHECK_NOT_EXECUTABLE|DEVICE .*FAIL' ;;
    A3.8.4) regex_all "$o" 'route|routing' 'dig|dns' 'openssl|certificate' 'portal|curl' 'wg|WireGuard' 'nft|firewall' 'rsyslog|log-a3' ;;
    A3.8.5) regex_all "$o" 'Command:|команд' 'PASS|FAIL|Result' ;;
    A3.8.6) regex_all "$o" 'allow|positive' 'deny|negative' 'PASS|FAIL' ;;
    A3.8.7) regex_all "$o" 'interface:|hq-fw-a3' 'peer:|branch-user-a3' ;;
    A3.8.8) regex_all "$o" 'openssl|ssl_verify_result|verify return' 'SAN|subjectAltName|portal' ;;
    A3.8.9) [ -n "$(tr -d '[:space:]' <<<"$o")" ;;
    A3.8.11) [ "$rc" -eq 0 ] && contains_all "$o" "PERSISTENCE_OK dns" "PERSISTENCE_OK portal" "PERSISTENCE_OK branch-firewall" "PERSISTENCE_OK hq-firewall" "PERSISTENCE_OK wireguard" "PERSISTENCE_OK central-log" && ! grep -Fq PERSISTENCE_FAIL <<<"$o" ;;
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

  local id sub desc mark runfrom commands expected notes command display last_sub="" passed failed total awarded failed_names reason
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
    step "$id" "$desc"; cmd_show "$id" "$command"
    run_command "$command" "$id"
    # Raw output is already streamed to screen and detail.log by run_command.
    show_output "ExitCode=$A3_LAST_RC (вывод показан выше по мере выполнения)"
    read -r passed failed <<<"$(device_counts "$A3_LAST_OUT")"
    total=$((passed + failed))
    # A mixed per-device result always has priority over the aggregate parser:
    # one successful device must not turn failures on other devices into full PASS.
    if [ "$total" -gt 1 ] && [ "$passed" -gt 0 ] && [ "$failed" -gt 0 ]; then
      awarded="$(awk -v m="$mark" -v p="$passed" -v t="$total" 'BEGIN { printf "%.3f", m*p/t }')"
      failed_names="$(failed_device_list "$A3_LAST_OUT")"
      show_output "По устройствам: PASS=$passed, FAIL=$failed; не прошли: ${failed_names:-не определено}; начислено $awarded из $mark"
      part "$id" "$mark" "$awarded" "$passed/$total устройств прошли; не прошли: ${failed_names:-не определено}. Ожидалось: $expected"
    elif [ "$failed" -gt 0 ]; then
      failed_names="$(failed_device_list "$A3_LAST_OUT")"
      fail "$id" "$mark" "явный DEVICE FAIL на: ${failed_names:-не определено}. Ожидалось: $expected"
    elif evaluate_result "$id" "$A3_LAST_OUT" "$A3_LAST_RC"; then
      pass "$id" "$mark" "фактический вывод соответствует ожидаемому результату"
    else
      reason="$(failure_reason "$A3_LAST_OUT" "$A3_LAST_RC" "$expected")"
      fail "$id" "$mark" "$reason"
    fi
  done < "$A3_CRITERIA_MAP"
  write_summary
}

main "$@"
