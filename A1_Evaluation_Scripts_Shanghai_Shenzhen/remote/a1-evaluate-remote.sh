#!/usr/bin/env bash
# A1 remote evaluator for Shanghai–Shenzhen revised task.
# Recommended launch host: sz-client-a1 as root.
# It uses SSH to reach every VM. If connectivity is missing, use local/a1-local-check.sh on each VM.

set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/a1-common.sh"

RUN_POST_REBOOT=0
RUN_DISRUPTIVE=1
A1_START_FROM="${A1_START_FROM:-A1.1}"
A1_RESUME_MODE=0
A1_START_MAJOR=1
A1_START_MINOR=1
A1_START_KEY=1001

usage() {
  cat <<'EOF'
Usage: bash remote/a1-evaluate-remote.sh [options]

Options:
  --pause                  Pause after each checked aspect (default).
  --no-pause               Run without pauses between aspects.
  --post-reboot            Run post-reboot persistence checks.
  --no-disruptive          Reserved for disruptive checks.
  --report-dir DIR         Write reports to DIR.
  --start-from A4.6        Resume from criterion/subcriterion index.
  --resume-from A4.6       Alias for --start-from.
  -h, --help               Show this help.

When --start-from/--resume-from is used, existing result/detail files in
--report-dir are preserved and new rows are appended.
EOF
}

normalize_criterion_id() {
  local raw
  raw="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  if [[ "$raw" =~ ^A([1-8])$ ]]; then
    printf 'A%s.1\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$raw" =~ ^A([1-8])\.([0-9]+)$ ]]; then
    printf 'A%s.%s\n' "${BASH_REMATCH[1]}" "$((10#${BASH_REMATCH[2]}))"
    return 0
  fi
  return 1
}

criterion_key() {
  local id
  id="$(normalize_criterion_id "$1")" || return 1
  [[ "$id" =~ ^A([1-8])\.([0-9]+)$ ]] || return 1
  printf '%s\n' "$((BASH_REMATCH[1] * 1000 + BASH_REMATCH[2]))"
}

validate_start_from() {
  local normalized
  normalized="$(normalize_criterion_id "$A1_START_FROM")" || {
    echo "Invalid criterion index for --start-from: $A1_START_FROM" >&2
    echo "Use A1, A1.1, A4.6, etc." >&2
    exit 2
  }
  A1_START_FROM="$normalized"
  [[ "$A1_START_FROM" =~ ^A([1-8])\.([0-9]+)$ ]] || exit 2
  A1_START_MAJOR="${BASH_REMATCH[1]}"
  A1_START_MINOR="${BASH_REMATCH[2]}"
  A1_START_KEY="$(criterion_key "$A1_START_FROM")"
}

should_run_criterion() {
  local key
  key="$(criterion_key "$1")" || return 1
  [ "$key" -ge "$A1_START_KEY" ]
}

should_run_block() {
  local block_major="${1#A}"
  [ "$block_major" -ge "$A1_START_MAJOR" ]
}

run_check_block() {
  local block="$1"
  local fn="$2"
  if should_run_block "$block"; then
    "$fn"
  else
    echo -e "${CYAN}SKIP $block - before --start-from $A1_START_FROM${NC}"
  fi
}

init_remote_report_files() {
  mkdir -p "$A1_REPORT_DIR"
  if [ "$A1_RESUME_MODE" = "1" ]; then
    [ -s "$A1_RESULTS_TSV" ] || printf "CriterionID\tMaxMark\tStatus\tMessage\n" > "$A1_RESULTS_TSV"
    touch "$A1_DETAIL_LOG"
  else
    printf "CriterionID\tMaxMark\tStatus\tMessage\n" > "$A1_RESULTS_TSV"
    : > "$A1_DETAIL_LOG"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pause) A1_PAUSE=1 ;;
    --no-pause) A1_PAUSE=0 ;;
    --post-reboot) RUN_POST_REBOOT=1 ;;
    --no-disruptive) RUN_DISRUPTIVE=0 ;;
    --report-dir)
      shift
      [ $# -gt 0 ] || { echo "Missing value for --report-dir" >&2; exit 2; }
      A1_REPORT_DIR="$1"
      A1_RESULTS_TSV="$A1_REPORT_DIR/a1-results.tsv"
      A1_DETAIL_LOG="$A1_REPORT_DIR/a1-detail.log"
      ;;
    --start-from|--resume-from)
      opt="$1"
      shift
      [ $# -gt 0 ] || { echo "Missing value for $opt" >&2; exit 2; }
      A1_START_FROM="$1"
      A1_RESUME_MODE=1
      ;;
    --start-from=*|--resume-from=*)
      A1_START_FROM="${1#*=}"
      A1_RESUME_MODE=1
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; exit 2 ;;
  esac
  shift
done

# IP addresses are used for SSH so DNS failure does not block assessment.
declare -A HOST_IP=(
  [sh-gw-a1]="10.11.10.1"
  [sh-client-a1]="10.11.10.20"
  [sz-gw-a1]="10.11.20.1"
  [sz-client-a1]="10.11.20.20"
  [files-a1]="10.11.30.10"
  [id-a1]="10.11.40.10"
  [web-a1]="10.11.40.20"
)

HOSTS=(sh-gw-a1 sh-client-a1 sz-gw-a1 sz-client-a1 files-a1 id-a1 web-a1)

ssh_cmd() {
  local host="$1"; shift
  local cmd="$*"
  local ip="${HOST_IP[$host]}"
  ssh -o BatchMode=yes -o ConnectTimeout="$A1_TIMEOUT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "root@$ip" "$cmd" 2>&1
}

ssh_check() {
  local host="$1"; shift
  ssh_cmd "$host" "true" >/dev/null 2>&1
}

remote_out() {
  local host="$1"; shift
  local cmd="$*"
  cmd_show "ssh root@${HOST_IP[$host]} '$cmd'"
  ssh_cmd "$host" "$cmd" | tee -a "$A1_DETAIL_LOG"
}

check_ssh_all() {
  section "PRECHECK - SSH-доступ к VM"
  local ok=1
  for h in "${HOSTS[@]}"; do
    if ssh_check "$h"; then echo -e "${GREEN}OK - SSH $h (${HOST_IP[$h]})${NC}"; else echo -e "${RED}FAILED - SSH $h (${HOST_IP[$h]})${NC}"; ok=0; fi
  done
  if [ "$ok" -eq 1 ]; then
    echo -e "${GREEN}Все VM доступны по SSH. Можно выполнять remote-проверку.${NC}"
  else
    echo -e "${YELLOW}Часть VM недоступна. Remote-проверка продолжится, но для недоступных хостов используйте local/a1-local-check.sh.${NC}"
  fi
  pause_if_needed
}

# --------------- A1: base/routing ---------------
check_A1() {
  section "A1 - Базовая система, адресация и двухсайтовая маршрутизация"

  if should_run_criterion "A1.1"; then
    step "A1.1 Hostname/FQDN всех VM"
    out=""
    for h in "${HOSTS[@]}"; do
      out+=$'\n'"--- $h ---"$'\n'
      out+="$(ssh_cmd "$h" 'hostname; hostname -f 2>/dev/null || true')"$'\n'
    done
    show_output "$out"
    ok=1
    for h in "${HOSTS[@]}"; do
      block="$(printf "%s\n" "$out" | awk -v host="$h" '
        $0 == "--- " host " ---" {capture=1; next}
        /^--- / && capture {capture=0}
        capture {print}
      ')"
      actual_hostname="$(printf "%s\n" "$block" | sed -n '1p')"
      actual_fqdn="$(printf "%s\n" "$block" | sed -n '2p')"
      if [ "$actual_hostname" != "$h" ] || [ "$actual_fqdn" != "${h}.${A1_DOMAIN}" ]; then
        ok=0
        {
          echo "Несовпадение hostname/FQDN для $h:"
          echo "  Ожидалось: hostname=$h, FQDN=${h}.${A1_DOMAIN}"
          echo "  Фактически: hostname=${actual_hostname:-<empty>}, FQDN=${actual_fqdn:-<empty>}"
        } | tee -a "$A1_DETAIL_LOG"
      fi
    done
    [ "$ok" -eq 1 ] && pass "A1.1" "0.25" "hostname/FQDN соответствуют таблице" || fail "A1.1" "0.25" "hostname/FQDN не соответствуют таблице"
  fi

  if should_run_criterion "A1.2"; then
    step "A1.2 Time zone, locale, keyboard"
    out=""
    for h in "${HOSTS[@]}"; do
      out+=$'\n'"--- $h ---"$'\n'
      out+="$(ssh_cmd "$h" 'timedatectl 2>/dev/null | grep "Time zone" || true; localectl status 2>/dev/null || true')"$'\n'
    done
    show_output "$out"
    cnt_tz=$(echo "$out" | grep -c "Europe/Paris" || true)
    cnt_loc=$(echo "$out" | grep -c "en_US.UTF-8" || true)
    if [ "$cnt_tz" -ge 7 ] && [ "$cnt_loc" -ge 7 ]; then pass "A1.2" "0.25" "time zone/locale настроены на всех VM"; else fail "A1.2" "0.25" "time zone/locale настроены не на всех VM"; fi
  fi

  if should_run_criterion "A1.3"; then
    step "A1.3 IP-адресация IPv4/IPv6"
    declare -A EXPECT_IPS=(
      [sh-gw-a1]="10.11.10.1 198.51.100.10 2001:db8:a1:10::1 2001:db8:a1:100::10"
      [sh-client-a1]="10.11.10.20 2001:db8:a1:10::20"
      [sz-gw-a1]="198.51.100.20 10.11.20.1 10.11.30.1 10.11.40.1 2001:db8:a1:100::20 2001:db8:a1:20::1 2001:db8:a1:30::1 2001:db8:a1:40::1"
      [sz-client-a1]="10.11.20.20 2001:db8:a1:20::20"
      [files-a1]="10.11.30.10 2001:db8:a1:30::10"
      [id-a1]="10.11.40.10 2001:db8:a1:40::10"
      [web-a1]="10.11.40.20 2001:db8:a1:40::20"
    )
    ok=1
    for h in "${HOSTS[@]}"; do
      out="$(ssh_cmd "$h" 'ip -br address')"
      echo "--- $h ---" | tee -a "$A1_DETAIL_LOG"; show_output "$out"
      for ip in ${EXPECT_IPS[$h]}; do echo "$out" | grep -q "$ip" || ok=0; done
    done
    [ "$ok" -eq 1 ] && pass "A1.3" "0.50" "все ожидаемые IPv4/IPv6 адреса обнаружены" || fail "A1.3" "0.50" "не все ожидаемые IP-адреса обнаружены"
  fi

  if should_run_criterion "A1.4"; then
    step "A1.4 Default gateway на конечных хостах"
    ok=1
    declare -A GW=([sh-client-a1]="10.11.10.1" [sz-client-a1]="10.11.20.1" [files-a1]="10.11.30.1" [id-a1]="10.11.40.1" [web-a1]="10.11.40.1")
    for h in sh-client-a1 sz-client-a1 files-a1 id-a1 web-a1; do
      out="$(ssh_cmd "$h" 'ip route show default; ip -6 route show default || true')"
      show_output "--- $h ---"$'\n'"$out"
      echo "$out" | grep -q "${GW[$h]}" || ok=0
    done
    [ "$ok" -eq 1 ] && pass "A1.4" "0.25" "default gateways корректны" || fail "A1.4" "0.25" "default gateways некорректны"
  fi

  if should_run_criterion "A1.5"; then
    step "A1.5 Статические маршруты на gateway-серверах"
    out1="$(ssh_cmd sh-gw-a1 'ip route; ip -6 route || true')"
    out2="$(ssh_cmd sz-gw-a1 'ip route; ip -6 route || true')"
    show_output "--- sh-gw-a1 ---"$'\n'"$out1"$'\n'"--- sz-gw-a1 ---"$'\n'"$out2"
    if contains_all "$out1" "10.11.20.0/24" "10.11.30.0/24" "10.11.40.0/24" && echo "$out1" | grep -q "198.51.100.20" && contains_all "$out2" "10.11.10.0/24" && echo "$out2" | grep -q "198.51.100.10"; then
      pass "A1.5" "0.50" "routes between sites присутствуют на gateway"
    else
      fail "A1.5" "0.50" "routes between sites отсутствуют или неполные"
    fi
  fi

  if should_run_criterion "A1.6"; then
    step "A1.6 IPv4/IPv6 forwarding"
    out="$(for h in sh-gw-a1 sz-gw-a1; do echo "--- $h ---"; ssh_cmd "$h" 'sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding'; done)"
    show_output "$out"
    if [ "$(echo "$out" | grep -c '= 1')" -ge 4 ]; then pass "A1.6" "0.25" "IPv4/IPv6 forwarding включён"; else fail "A1.6" "0.25" "IPv4/IPv6 forwarding не включён на обоих gateway"; fi
  fi

  if should_run_criterion "A1.7"; then
    step "A1.7 IPv4-достижимость между площадками без NAT"
    out="$(ssh_cmd sh-client-a1 'ping -c2 -W2 10.11.40.10; ping -c2 -W2 10.11.40.20; ping -c2 -W2 10.11.30.10' ; ssh_cmd sz-client-a1 'ping -c2 -W2 10.11.10.20' ; ssh_cmd sh-gw-a1 'nft list ruleset 2>/dev/null | grep -Ei "masquerade|snat|dnat" || true'; ssh_cmd sz-gw-a1 'nft list ruleset 2>/dev/null | grep -Ei "masquerade|snat|dnat" || true')"
    show_output "$out"
    okp=$(echo "$out" | grep -c "0% packet loss" || true)
    nat=$(echo "$out" | grep -Eci "masquerade|snat|dnat" || true)
    if [ "$okp" -ge 4 ] && [ "$nat" -eq 0 ]; then pass "A1.7" "0.50" "IPv4 end-to-end работает, NAT между internal-сетями не обнаружен"; else fail "A1.7" "0.50" "IPv4 end-to-end/NAT check не пройден"; fi
  fi

  if should_run_criterion "A1.8"; then
    step "A1.8 IPv6-маршрутизация между площадками"
    out="$(ssh_cmd sh-client-a1 'ping -6 -c2 -W2 2001:db8:a1:40::10; ping -6 -c2 -W2 2001:db8:a1:40::20' ; ssh_cmd sz-client-a1 'ping -6 -c2 -W2 2001:db8:a1:10::20')"
    show_output "$out"
    if [ "$(echo "$out" | grep -c "0% packet loss")" -ge 3 ]; then pass "A1.8" "0.25" "IPv6 routing работает"; else fail "A1.8" "0.25" "IPv6 routing не работает полностью"; fi
  fi

  if should_run_criterion "A1.9"; then
    step "A1.9 Persistence адресации/маршрутов/forwarding"
    if [ "$RUN_POST_REBOOT" = "1" ]; then
      out="$(ssh_cmd sh-gw-a1 'ip route; sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding'; ssh_cmd sz-gw-a1 'ip route; sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding')"
      show_output "$out"
      if contains_all "$out" "net.ipv4.ip_forward = 1" "net.ipv6.conf.all.forwarding = 1" "10.11.10.0/24"; then pass "A1.9" "0.25" "routing/forwarding сохраняются после reboot"; else fail "A1.9" "0.25" "routing/forwarding не сохраняются после reboot"; fi
    else
      skip "A1.9" "0.25" "post-reboot check не запущен; используйте --post-reboot после перезагрузки"
    fi
  fi
}

# --------------- A2: DNS ---------------
check_A2() {
  section "A2 - DNS"

  if should_run_criterion "A2.1"; then
    step "A2.1 BIND9 запущен и слушает"
    out="$(ssh_cmd id-a1 'systemctl is-active bind9 named 2>/dev/null || true; ss -lntu | grep -E ":53\\b" || true')"
    show_output "$out"
    if echo "$out" | grep -q "active" && echo "$out" | grep -q ":53"; then pass "A2.1" "0.25" "BIND/named active and listens 53"; else fail "A2.1" "0.25" "DNS service not active/listening"; fi
  fi

  if should_run_criterion "A2.2"; then
    step "A2.2 A-записи"
    ok=1
    declare -A A_REC=([sh-gw-a1]="10.11.10.1" [sh-client-a1]="10.11.10.20" [sz-client-a1]="10.11.20.20" [files-a1]="10.11.30.10" [id-a1]="10.11.40.10" [web-a1]="10.11.40.20")
    for n in "${!A_REC[@]}"; do
      out="$(ssh_cmd sz-client-a1 "dig @${A1_DNS_IP} +short ${n}.${A1_DOMAIN} A")"; show_output "$n A -> $out"; echo "$out" | grep -qx "${A_REC[$n]}" || ok=0
    done
    [ "$ok" -eq 1 ] && pass "A2.2" "0.25" "A-записи основных хостов корректны" || fail "A2.2" "0.25" "A-записи отсутствуют/некорректны"
  fi

  if should_run_criterion "A2.3"; then
    step "A2.3 AAAA-записи"
    ok=1
    declare -A AAAA_REC=([sh-client-a1]="2001:db8:a1:10::20" [sz-client-a1]="2001:db8:a1:20::20" [files-a1]="2001:db8:a1:30::10" [id-a1]="2001:db8:a1:40::10" [web-a1]="2001:db8:a1:40::20")
    for n in "${!AAAA_REC[@]}"; do
      out="$(ssh_cmd sz-client-a1 "dig @${A1_DNS_IP} +short ${n}.${A1_DOMAIN} AAAA")"; show_output "$n AAAA -> $out"; echo "$out" | grep -qx "${AAAA_REC[$n]}" || ok=0
    done
    [ "$ok" -eq 1 ] && pass "A2.3" "0.25" "AAAA-записи корректны" || fail "A2.3" "0.25" "AAAA-записи отсутствуют/некорректны"
  fi

  if should_run_criterion "A2.4"; then
    step "A2.4 DNS for multi-address gateway hostnames"
    declare -A GW_A_REC=(
      [sh-gw-a1]="10.11.10.1 198.51.100.10"
      [sz-gw-a1]="198.51.100.20 10.11.20.1 10.11.30.1 10.11.40.1"
    )
    ok=1
    for n in "${!GW_A_REC[@]}"; do
      out="$(ssh_cmd sz-client-a1 "dig @${A1_DNS_IP} +short ${n}.${A1_DOMAIN} A")"
      show_output "$n A -> $out"
      for ip in ${GW_A_REC[$n]}; do echo "$out" | grep -qx "$ip" || ok=0; done
    done
    [ "$ok" -eq 1 ] && pass "A2.4" "0.25" "gateway hostnames resolve to their task IPv4 addresses" || fail "A2.4" "0.25" "gateway hostname A records are incomplete"
  fi

  if should_run_criterion "A2.5"; then
    step "A2.5 IPv4 PTR"
    ok=1
    for ip in 10.11.10.1 198.51.100.10 198.51.100.20 10.11.20.1 10.11.30.1 10.11.40.1 10.11.10.20 10.11.20.20 10.11.30.10 10.11.40.10 10.11.40.20; do
      out="$(ssh_cmd sz-client-a1 "dig @${A1_DNS_IP} +short -x $ip")"; show_output "$ip PTR -> $out"; echo "$out" | grep -q "${A1_DOMAIN}" || ok=0
    done
    [ "$ok" -eq 1 ] && pass "A2.5" "0.50" "IPv4 PTR-записи корректны" || fail "A2.5" "0.50" "не все IPv4 PTR-записи корректны"
  fi

  if should_run_criterion "A2.6"; then
    step "A2.6 CNAME dns/ldap/ca/files/www"
    ok=1
    for n in dns ldap ca files www; do
      out="$(ssh_cmd sz-client-a1 "dig @${A1_DNS_IP} +short ${n}.${A1_DOMAIN} CNAME")"; show_output "$n CNAME -> $out"; [ -n "$out" ] || ok=0
    done
    [ "$ok" -eq 1 ] && pass "A2.6" "0.50" "CNAME-записи работают" || fail "A2.6" "0.50" "часть CNAME-записей отсутствует"
  fi

  if should_run_criterion "A2.7"; then
    step "A2.7 LDAP SRV"
    out="$(ssh_cmd sz-client-a1 "dig @${A1_DNS_IP} +short _ldap._tcp.${A1_DOMAIN} SRV")"
    show_output "$out"
    if echo "$out" | grep -q "389.*id-a1.${A1_DOMAIN}"; then pass "A2.7" "0.25" "LDAP SRV корректна"; else fail "A2.7" "0.25" "LDAP SRV некорректна"; fi
  fi

  if should_run_criterion "A2.8"; then
    step "A2.8 DNS recursion policy"
    out1="$(ssh_cmd sz-client-a1 "dig @${A1_DNS_IP} debian.org A +short +time=2")"
    out2="$(ssh_cmd sh-gw-a1 "dig @${A1_DNS_IP} debian.org A +short +time=2 -b 198.51.100.10 || true")"
    show_output "internal recursion: $out1"$'\n'"WAN-source recursion: $out2"
    if [ -n "$out1" ] && [ -z "$out2" ]; then pass "A2.8" "0.25" "recursion allowed internal, denied WAN-source"; else fail "A2.8" "0.25" "recursion policy not correct"; fi
  fi

  if should_run_criterion "A2.9"; then
    step "A2.9 Clients use id-a1 as resolver"
    ok=1
    for h in sh-client-a1 sz-client-a1 files-a1 web-a1; do
      out="$(ssh_cmd "$h" "grep -R '${A1_DNS_IP}' /etc/resolv.conf /etc/systemd/resolved.conf /etc/systemd/network 2>/dev/null || true")"; show_output "--- $h ---"$'\n'"$out"; [ -n "$out" ] || ok=0
    done
    [ "$ok" -eq 1 ] && pass "A2.9" "0.25" "clients use id-a1 resolver" || fail "A2.9" "0.25" "not all clients use id-a1 resolver"
  fi

  if should_run_criterion "A2.10"; then
    step "A2.10 DNS persistence"
    if [ "$RUN_POST_REBOOT" = "1" ]; then
      out="$(ssh_cmd id-a1 'systemctl is-active bind9 named 2>/dev/null || true'; ssh_cmd sz-client-a1 "dig @${A1_DNS_IP} www.${A1_DOMAIN} A +short")"
      show_output "$out"
      if echo "$out" | grep -q "active" && echo "$out" | grep -q "10.11.40.20"; then pass "A2.10" "0.25" "DNS persists after reboot"; else fail "A2.10" "0.25" "DNS not persistent"; fi
    else
      skip "A2.10" "0.25" "post-reboot check не запущен"
    fi
  fi
}

# --------------- A3: PKI/TLS ---------------
check_A3() {
  section "A3 - PKI и TLS-доверие"

  if should_run_criterion "A3.1"; then
    step "A3.1 Root CA evidence"
    out="$(ssh_cmd sz-client-a1 'openssl x509 -in /opt/grading/a1/ca.pem -noout -subject -ext basicConstraints,keyUsage 2>&1')"
    show_output "$out"
    if echo "$out" | grep -q "Orion A1 Root CA"; then pass "A3.1" "0.25" "Root CA evidence present"; else fail "A3.1" "0.25" "Root CA evidence missing/wrong"; fi
  fi

  if should_run_criterion "A3.2"; then
    step "A3.2 CA trust installed"
    ok=1
    for h in sz-client-a1 sh-client-a1 files-a1 web-a1; do
      out="$(ssh_cmd "$h" 'find -L /etc/ssl/certs /usr/local/share/ca-certificates -type f \( -name "*.pem" -o -name "*.crt" \) 2>/dev/null | while IFS= read -r cert; do subject="$(openssl x509 -in "$cert" -noout -subject 2>/dev/null || true)"; if echo "$subject" | grep -q "Orion A1 Root CA"; then echo "$cert: $subject"; exit 0; fi; done')"; show_output "--- $h ---"$'\n'"$out"; [ -n "$out" ] || ok=0
    done
    [ "$ok" -eq 1 ] && pass "A3.2" "0.25" "CA appears trusted on required hosts" || fail "A3.2" "0.25" "CA trust missing on some hosts"
  fi

  if should_run_criterion "A3.3"; then
    step "A3.3 LDAP cert SAN"
    out="$(ssh_cmd sz-client-a1 'openssl x509 -in /opt/grading/a1/id-a1.pem -noout -text 2>&1')"
    show_output "$out"
    if contains_all "$out" "DNS:id-a1.orion.a1.test" "DNS:ldap.orion.a1.test" "DNS:ca.orion.a1.test"; then pass "A3.3" "0.50" "LDAP certificate SANs correct"; else fail "A3.3" "0.50" "LDAP certificate SANs incomplete"; fi
  fi

  if should_run_criterion "A3.4"; then
    step "A3.4 Web cert SAN"
    out="$(ssh_cmd sz-client-a1 'openssl x509 -in /opt/grading/a1/web-a1.pem -noout -text 2>&1')"
    show_output "$out"
    if contains_all "$out" "DNS:web-a1.orion.a1.test" "DNS:www.orion.a1.test"; then pass "A3.4" "0.50" "Web certificate SANs correct"; else fail "A3.4" "0.50" "Web certificate SANs incomplete"; fi
  fi

  if should_run_criterion "A3.5"; then
    step "A3.5 LDAP StartTLS"
    out="$(ssh_cmd sz-client-a1 "LDAPTLS_REQCERT=demand ldapwhoami -H ldap://ldap.${A1_DOMAIN} -ZZ -x -D '${A1_BIND_DN}' -w '${A1_PASS}' 2>&1")"
    show_output "$out"
    if echo "$out" | grep -q "dn:${A1_BIND_DN}"; then pass "A3.5" "0.50" "LDAP StartTLS works with certificate validation"; else fail "A3.5" "0.50" "LDAP StartTLS validation failed"; fi
  fi

  if should_run_criterion "A3.6"; then
    step "A3.6 HTTPS trust from both clients"
    out="$(ssh_cmd sz-client-a1 "curl -LsS https://www.${A1_DOMAIN}/ 2>&1"; ssh_cmd sh-client-a1 "curl -LsS https://www.${A1_DOMAIN}/ 2>&1")"
    show_output "$out"
    if [ "$(echo "$out" | grep -c '^A1_WEB_HTTPS_OK$')" -ge 2 ]; then pass "A3.6" "0.25" "HTTPS trust works from both clients"; else fail "A3.6" "0.25" "HTTPS trust failed from one/both clients"; fi
  fi

  if should_run_criterion "A3.7"; then
    step "A3.7 Private key permissions"
    out="$(ssh_cmd id-a1 "find /etc/ssl /etc/ldap /opt -type f \\( -name '*key*' -o -name '*.key' \\) -printf '%m %u %g %p\n' 2>/dev/null | head -50"; ssh_cmd web-a1 "find /etc/ssl /etc/nginx /etc/apache2 /opt -type f \\( -name '*key*' -o -name '*.key' \\) -printf '%m %u %g %p\n' 2>/dev/null | head -50")"
    show_output "$out"
    if echo "$out" | awk '$1 ~ /^[0-9]+$/ && $1 > 640 {bad=1} END{exit bad}'; then pass "A3.7" "0.25" "private keys not world-readable"; else fail "A3.7" "0.25" "private key permissions too open"; fi
  fi
}

# --------------- A4: LDAP/SSSD ---------------
check_A4() {
  section "A4 - LDAP и SSSD-аутентификация"

  if should_run_criterion "A4.1"; then
    step "A4.1 OpenLDAP listens 389"
    out="$(ssh_cmd id-a1 'systemctl is-active slapd 2>/dev/null || true; ss -lntp | grep ":389" || true')"
    show_output "$out"
    if echo "$out" | grep -q "active" && echo "$out" | grep -q ":389"; then pass "A4.1" "0.25" "OpenLDAP active and listens 389"; else fail "A4.1" "0.25" "OpenLDAP not active/listening"; fi
  fi

  if should_run_criterion "A4.2"; then
    step "A4.2 Base DN and OU"
    out="$(ssh_cmd id-a1 "ldapsearch -H ldap://localhost -x -D '${A1_BIND_DN}' -w '${A1_PASS}' -b ${A1_BASE_DN} '(objectClass=organizationalUnit)' dn 2>&1")"
    show_output "$out"
    if contains_all "$out" "ou=People,${A1_BASE_DN}" "ou=Groups,${A1_BASE_DN}" "ou=Services,${A1_BASE_DN}"; then pass "A4.2" "0.25" "Base DN/OU exist"; else fail "A4.2" "0.25" "Base DN/OU missing"; fi
  fi

  if should_run_criterion "A4.3"; then
    step "A4.3 LDAP groups gidNumber"
    out="$(ssh_cmd id-a1 "ldapsearch -H ldap://localhost -x -D '${A1_BIND_DN}' -w '${A1_PASS}' -b ou=Groups,${A1_BASE_DN} '(|(cn=linuxadmins)(cn=developers)(cn=operators))' cn gidNumber 2>&1")"
    show_output "$out"
    if contains_all "$out" "cn: linuxadmins" "gidNumber: 7100" "cn: developers" "gidNumber: 7200" "cn: operators" "gidNumber: 7300"; then pass "A4.3" "0.25" "LDAP groups correct"; else fail "A4.3" "0.25" "LDAP groups missing/wrong gidNumber"; fi
  fi

  if should_run_criterion "A4.4"; then
    step "A4.4 LDAP users attributes"
    out="$(ssh_cmd id-a1 "ldapsearch -H ldap://localhost -x -D '${A1_BIND_DN}' -w '${A1_PASS}' -b ou=People,${A1_BASE_DN} '(|(uid=amina)(uid=daryn)(uid=timur))' uid uidNumber gidNumber loginShell 2>&1")"
    show_output "$out"
    if contains_all "$out" "uid: amina" "uidNumber: 8101" "uid: daryn" "uidNumber: 8102" "uid: timur" "uidNumber: 8103" "loginShell: /bin/bash"; then pass "A4.4" "0.25" "LDAP users correct"; else fail "A4.4" "0.25" "LDAP users attributes missing/wrong"; fi
  fi

  if should_run_criterion "A4.5"; then
    step "A4.5 Anonymous bind restriction"
    out="$(ssh_cmd id-a1 "ldapsearch -H ldap://localhost -x -b ou=People,${A1_BASE_DN} uid 2>&1; ldapsearch -H ldap://localhost -x -b ${A1_BASE_DN} userPassword 2>&1")"
    show_output "$out"
    if ! echo "$out" | grep -q "userPassword:" && ! echo "$out" | grep -q "uid: amina"; then pass "A4.5" "0.25" "anonymous bind does not expose people/userPassword"; else fail "A4.5" "0.25" "anonymous bind exposes People or userPassword"; fi
  fi

  if should_run_criterion "A4.6"; then
    step "A4.6 SSSD sz-client-a1"
    out="$(ssh_cmd sz-client-a1 'systemctl is-active sssd 2>/dev/null || true; getent passwd amina; getent group developers')"
    show_output "$out"
    if contains_all "$out" "active" "amina" "developers"; then pass "A4.6" "0.50" "SSSD works on sz-client-a1"; else fail "A4.6" "0.50" "SSSD not working on sz-client-a1"; fi
  fi

  if should_run_criterion "A4.7"; then
    step "A4.7 SSSD sh-client-a1"
    out="$(ssh_cmd sh-client-a1 'systemctl is-active sssd 2>/dev/null || true; getent passwd daryn; getent group operators')"
    show_output "$out"
    if contains_all "$out" "active" "daryn" "operators"; then pass "A4.7" "0.50" "SSSD works on sh-client-a1"; else fail "A4.7" "0.50" "SSSD not working on sh-client-a1"; fi
  fi

  if should_run_criterion "A4.8"; then
    step "A4.8 SSSD files-a1"
    out="$(ssh_cmd files-a1 'systemctl is-active sssd 2>/dev/null || true; getent passwd amina; getent passwd daryn; getent group developers; getent group operators')"
    show_output "$out"
    if contains_all "$out" "active" "amina" "daryn" "developers" "operators"; then pass "A4.8" "0.50" "SSSD works on files-a1"; else fail "A4.8" "0.50" "SSSD not working on files-a1"; fi
  fi

  if should_run_criterion "A4.9"; then
    step "A4.9 Group membership"
    out="$(for h in sz-client-a1 sh-client-a1 files-a1; do echo --- $h ---; ssh_cmd "$h" 'id amina; id daryn; id timur' ; done)"
    show_output "$out"
    if contains_all "$out" "developers" "operators" "linuxadmins"; then pass "A4.9" "0.25" "group membership is visible on SSSD clients"; else fail "A4.9" "0.25" "group membership incomplete/wrong"; fi
  fi

  if should_run_criterion "A4.10"; then
    step "A4.10 LDAP login and auto home"
    out="$(ssh_cmd sz-client-a1 "su - amina -c 'id; pwd' 2>&1; ls -ld /home/amina 2>&1"; ssh_cmd sh-client-a1 "su - daryn -c 'id; pwd' 2>&1; ls -ld /home/daryn 2>&1")"
    show_output "$out"
    if contains_all "$out" "uid=8101" "/home/amina" "uid=8102" "/home/daryn"; then pass "A4.10" "0.50" "LDAP login and auto homes work"; else fail "A4.10" "0.50" "LDAP login/home auto creation failed"; fi
  fi

  if should_run_criterion "A4.11"; then
    step "A4.11 timur sudo"
    out="$(ssh_cmd sz-client-a1 "su - timur -c \"sudo -n id || printf '%s\\n' '${A1_PASS}' | sudo -S id\" 2>&1")"
    show_output "$out"
    if echo "$out" | grep -q "uid=0(root)"; then pass "A4.11" "0.25" "timur has sudo"; else fail "A4.11" "0.25" "timur sudo missing or password rejected"; fi
  fi

  if should_run_criterion "A4.12"; then
    step "A4.12 LDAP/SSSD persistence"
    if [ "$RUN_POST_REBOOT" = "1" ]; then
      out="$(ssh_cmd id-a1 'systemctl is-active slapd'; ssh_cmd sz-client-a1 'getent passwd amina'; ssh_cmd sh-client-a1 'getent passwd daryn'; ssh_cmd files-a1 'getent passwd timur')"
      show_output "$out"
      if contains_all "$out" "active" "amina" "daryn" "timur"; then pass "A4.12" "0.25" "LDAP/SSSD persists after reboot"; else fail "A4.12" "0.25" "LDAP/SSSD not persistent"; fi
    else
      skip "A4.12" "0.25" "post-reboot check не запущен"
    fi
  fi
}

# --------------- A5 Web ---------------
check_A5() {
  section "A5 - Web service"
  if should_run_criterion "A5.1"; then
    out="$(ssh_cmd sz-client-a1 "curl -LsS http://www.${A1_DOMAIN}/ 2>&1"; ssh_cmd sh-client-a1 "curl -LsS http://www.${A1_DOMAIN}/ 2>&1")"
    show_output "$out"
    [ "$(echo "$out" | grep -c '^A1_WEB_HTTP_OK$')" -ge 2 ] && pass "A5.1" "0.50" "HTTP returns expected string from both clients" || fail "A5.1" "0.50" "HTTP string mismatch"
  fi

  if should_run_criterion "A5.2"; then
    out="$(ssh_cmd sz-client-a1 "curl -LsS https://www.${A1_DOMAIN}/ 2>&1"; ssh_cmd sh-client-a1 "curl -LsS https://www.${A1_DOMAIN}/ 2>&1")"
    show_output "$out"
    [ "$(echo "$out" | grep -c '^A1_WEB_HTTPS_OK$')" -ge 2 ] && pass "A5.2" "0.75" "HTTPS returns expected string with TLS validation from both clients" || fail "A5.2" "0.75" "HTTPS failed or wrong output"
  fi

  if should_run_criterion "A5.3"; then
    out="$(ssh_cmd sz-client-a1 "curl -LsS http://www.${A1_DOMAIN}/healthz; echo; curl -LsS https://www.${A1_DOMAIN}/healthz"; ssh_cmd sh-client-a1 "curl -LsS http://www.${A1_DOMAIN}/healthz; echo; curl -LsS https://www.${A1_DOMAIN}/healthz")"
    show_output "$out"
    [ "$(echo "$out" | grep -c '^OK$')" -ge 4 ] && pass "A5.3" "0.50" "HTTP and HTTPS /healthz return OK from both clients" || fail "A5.3" "0.50" "/healthz not OK on both protocols"
  fi

  if should_run_criterion "A5.4"; then
    out1="$(ssh_cmd sz-client-a1 "curl -LsS http://10.11.40.20/ 2>&1")"
    out2="$(ssh_cmd sz-client-a1 "dig @${A1_DNS_IP} +short www.${A1_DOMAIN} A")"
    show_output "$out1"$'\n'"$out2"
    if [ "$out1" = "A1_WEB_HTTP_OK" ] && echo "$out2" | grep -qx "10.11.40.20"; then pass "A5.4" "0.25" "web works by IP and FQDN"; else fail "A5.4" "0.25" "web IP/FQDN check failed"; fi
  fi

  if should_run_criterion "A5.5"; then
    out="$(ssh_cmd id-a1 "grep -R 'web-a1\\|A1_WEB' /var/log/remote /var/log 2>/dev/null | tail -20")"
    show_output "$out"
    [ -n "$out" ] && pass "A5.5" "0.25" "web logs are visible on central syslog" || fail "A5.5" "0.25" "web logs not visible on central syslog"
  fi

  if should_run_criterion "A5.6"; then
    if [ "$RUN_POST_REBOOT" = "1" ]; then
      out="$(ssh_cmd web-a1 'systemctl is-active nginx apache2 2>/dev/null || true'; ssh_cmd sz-client-a1 "curl -LsS http://www.${A1_DOMAIN}/healthz")"
      show_output "$out"
      if echo "$out" | grep -q "active" && echo "$out" | grep -q "OK"; then pass "A5.6" "0.25" "web persists after reboot"; else fail "A5.6" "0.25" "web not persistent"; fi
    else
      skip "A5.6" "0.25" "post-reboot check не запущен"
    fi
  fi
}

# --------------- A6 Files ---------------
check_A6() {
  section "A6 - NFS/Samba file services"

  if should_run_criterion "A6.1"; then
    out="$(ssh_cmd files-a1 'ls -ld /srv/nfs/projects /srv/samba/projects 2>&1; getfacl -p /srv/nfs/projects /srv/samba/projects 2>/dev/null || true')"
    show_output "$out"
    if contains_all "$out" "developers" "operators"; then pass "A6.1" "0.25" "file paths use LDAP groups/ACLs"; else fail "A6.1" "0.25" "file path permissions do not show required LDAP groups"; fi
  fi

  if should_run_criterion "A6.2"; then
    out="$(ssh_cmd files-a1 'exportfs -v; ss -lntp | grep ":2049" || true')"
    show_output "$out"
    if echo "$out" | grep -q "/srv/nfs/projects" && echo "$out" | grep -q ":2049"; then pass "A6.2" "0.25" "NFSv4 export and TCP/2049 available"; else fail "A6.2" "0.25" "NFSv4 export/TCP2049 missing"; fi
  fi

  if should_run_criterion "A6.3"; then
    out="$(ssh_cmd sz-client-a1 "findmnt /mnt/projects; cat /mnt/projects/a1-nfs-ok.txt 2>&1 || su - amina -c 'cat /mnt/projects/a1-nfs-ok.txt' 2>&1")"
    show_output "$out"
    if contains_all "$out" "/mnt/projects" "A1_NFS_OK"; then pass "A6.3" "0.50" "sz-client persistent NFS mount works"; else fail "A6.3" "0.50" "sz-client NFS mount missing/broken"; fi
  fi

  if should_run_criterion "A6.4"; then
    out="$(ssh_cmd sh-client-a1 "systemctl is-active autofs 2>/dev/null || true; ls /net/projects 2>&1 || su - amina -c 'ls /net/projects' 2>&1; cat /net/projects/a1-nfs-ok.txt 2>&1 || su - amina -c 'cat /net/projects/a1-nfs-ok.txt' 2>&1")"
    show_output "$out"
    if echo "$out" | grep -q "active" && echo "$out" | grep -q "A1_NFS_OK"; then pass "A6.4" "0.50" "sh-client autofs NFS works"; else fail "A6.4" "0.50" "sh-client autofs NFS missing/broken"; fi
  fi

  if should_run_criterion "A6.5"; then
    out="$(ssh_cmd sh-client-a1 'touch /net/projects/root-squash-test.txt 2>/tmp/a1-rs.err || true; ls -ln /net/projects/root-squash-test.txt 2>/dev/null || cat /tmp/a1-rs.err')"
    show_output "$out"
    if echo "$out" | grep -Eq "nobody|65534|Permission denied|denied"; then pass "A6.5" "0.25" "root squash effective"; else fail "A6.5" "0.25" "root squash not effective"; fi
  fi

  if should_run_criterion "A6.6"; then
    out="$(ssh_cmd sz-client-a1 "smbclient -L //files.${A1_DOMAIN} -N 2>&1 || true; smbclient -L //files.${A1_DOMAIN} -U 'amina%${A1_PASS}' 2>&1")"
    show_output "$out"
    if echo "$out" | grep -q "projects" && echo "$out" | grep -Eiq "NT_STATUS_ACCESS_DENIED|session setup failed"; then pass "A6.6" "0.25" "Samba share visible to authenticated users, guest denied"; else fail "A6.6" "0.25" "Samba guest/auth visibility wrong"; fi
  fi

  if should_run_criterion "A6.7"; then
    out="$(ssh_cmd sz-client-a1 "tmp=/tmp/a1-smb-amina.txt; echo A1_SAMBA_AMINA > \$tmp; smbclient //files.${A1_DOMAIN}/projects -U 'amina%${A1_PASS}' -c 'put /tmp/a1-smb-amina.txt amina-write.txt; get amina-write.txt /tmp/amina-read.txt; del amina-write.txt' 2>&1; cat /tmp/amina-read.txt 2>/dev/null")"
    show_output "$out"
    if echo "$out" | grep -q "A1_SAMBA_AMINA"; then pass "A6.7" "0.25" "amina can read/write Samba"; else fail "A6.7" "0.25" "amina Samba read/write failed"; fi
  fi

  if should_run_criterion "A6.8"; then
    out="$(ssh_cmd sz-client-a1 "smbclient //files.${A1_DOMAIN}/projects -U 'daryn%${A1_PASS}' -c 'ls; put /etc/hostname daryn-should-fail.txt' 2>&1")"
    show_output "$out"
    if echo "$out" | grep -q "NT_STATUS_ACCESS_DENIED\|ACCESS_DENIED\|Permission denied" && echo "$out" | grep -qi "blocks\|\\.\\|projects\|Disk"; then pass "A6.8" "0.25" "daryn read-only Samba behaviour"; else fail "A6.8" "0.25" "daryn Samba read-only behaviour failed"; fi
  fi

  if should_run_criterion "A6.9"; then
    if [ "$RUN_POST_REBOOT" = "1" ]; then
      out="$(ssh_cmd files-a1 'systemctl is-active nfs-server nfs-kernel-server smbd 2>/dev/null || true'; ssh_cmd sz-client-a1 "findmnt /mnt/projects; cat /mnt/projects/a1-nfs-ok.txt 2>&1 || su - amina -c 'cat /mnt/projects/a1-nfs-ok.txt' 2>&1"; ssh_cmd sh-client-a1 "ls /net/projects 2>&1 || su - amina -c 'ls /net/projects' 2>&1; cat /net/projects/a1-nfs-ok.txt 2>&1 || su - amina -c 'cat /net/projects/a1-nfs-ok.txt' 2>&1"; ssh_cmd sz-client-a1 "smbclient //files.${A1_DOMAIN}/projects -U 'amina%${A1_PASS}' -c 'ls' 2>&1")"
      show_output "$out"
      if [ "$(echo "$out" | grep -c '^active$')" -ge 2 ] && echo "$out" | grep -q "/mnt/projects" && [ "$(echo "$out" | grep -c '^A1_NFS_OK$')" -ge 2 ] && echo "$out" | grep -Eiq "blocks|Disk|projects"; then pass "A6.9" "0.50" "NFS/Samba persistent after reboot"; else fail "A6.9" "0.50" "NFS/Samba not persistent"; fi
    else
      skip "A6.9" "0.50" "post-reboot check не запущен"
    fi
  fi
}

# --------------- A7 Firewall ---------------
check_A7() {
  section "A7 - Gateway firewall and access control"

  if should_run_criterion "A7.1"; then
    out="$(ssh_cmd sh-gw-a1 'systemctl is-active nftables 2>/dev/null || true; nft list ruleset 2>/dev/null | head -60'; ssh_cmd sz-gw-a1 'systemctl is-active nftables 2>/dev/null || true; nft list ruleset 2>/dev/null | head -60')"
    show_output "$out"
    if [ "$(echo "$out" | grep -c "active")" -ge 2 ]; then pass "A7.1" "0.25" "nftables active on both gateways"; else fail "A7.1" "0.25" "nftables not active on both gateways"; fi
  fi

  if should_run_criterion "A7.2"; then
    out="$(ssh_cmd sh-client-a1 'nc -vz -w2 10.11.10.1 22'; ssh_cmd sz-client-a1 'nc -vz -w2 10.11.10.1 22 || true')"
    show_output "$out"
    if echo "$out" | grep -q "succeeded\|open" && echo "$out" | grep -Eq "timed out|refused|failed"; then pass "A7.2" "0.25" "SSH to sh-gw restricted to SH-LAN"; else fail "A7.2" "0.25" "SSH restriction to sh-gw not proven"; fi
  fi

  if should_run_criterion "A7.3"; then
    out="$(ssh_cmd sz-client-a1 'nc -vz -w2 10.11.20.1 22'; ssh_cmd sh-client-a1 'nc -vz -w2 10.11.20.1 22 || true')"
    show_output "$out"
    if echo "$out" | grep -q "succeeded\|open" && echo "$out" | grep -Eq "timed out|refused|failed"; then pass "A7.3" "0.25" "SSH to sz-gw restricted to SZ-CLIENT"; else fail "A7.3" "0.25" "SSH restriction to sz-gw not proven"; fi
  fi

  if should_run_criterion "A7.4"; then
    out="$(ssh_cmd sh-client-a1 "dig @10.11.40.10 www.${A1_DOMAIN} A +short; nc -vz -w2 10.11.40.10 389; ldapwhoami -H ldap://ldap.${A1_DOMAIN} -ZZ -x -D '${A1_BIND_DN}' -w '${A1_PASS}'")"
    show_output "$out"
    if echo "$out" | grep -qx "10.11.40.20" && echo "$out" | grep -Eiq "389.*(succeeded|open)" && echo "$out" | grep -q "dn:${A1_BIND_DN}"; then pass "A7.4" "0.25" "SH-LAN to id-a1 DNS/LDAP StartTLS allowed"; else fail "A7.4" "0.25" "SH-LAN to id-a1 flows not allowed"; fi
  fi

  if should_run_criterion "A7.5"; then
    out="$(ssh_cmd sh-client-a1 'nc -vz -w2 10.11.40.20 80; nc -vz -w2 10.11.40.20 443')"
    show_output "$out"
    if [ "$(echo "$out" | grep -Ec 'succeeded|open')" -ge 2 ]; then pass "A7.5" "0.25" "SH-LAN to web HTTP/HTTPS allowed"; else fail "A7.5" "0.25" "SH-LAN to web HTTP/HTTPS not allowed"; fi
  fi

  if should_run_criterion "A7.6"; then
    out="$(ssh_cmd sh-client-a1 'nc -vz -w2 10.11.30.10 2049; nc -vz -w2 10.11.30.10 445 || true; nc -vz -w2 10.11.30.10 139 || true')"
    show_output "$out"
    if echo "$out" | grep -q "2049.*succeeded\|2049.*open" && echo "$out" | grep -Eq "445.*(failed|refused|timed out)|139.*(failed|refused|timed out)"; then pass "A7.6" "0.50" "SH-LAN NFS allowed, Samba denied"; else fail "A7.6" "0.50" "SH-LAN files flow matrix incorrect"; fi
  fi

  if should_run_criterion "A7.7"; then
    out="$(ssh_cmd sz-client-a1 'nc -vz -w2 10.11.40.10 53; nc -vz -w2 10.11.40.20 443; nc -vz -w2 10.11.30.10 445; nc -vz -w2 10.11.30.10 2049')"
    show_output "$out"
    if [ "$(echo "$out" | grep -Ec 'succeeded|open')" -ge 4 ]; then pass "A7.7" "0.25" "SZ-CLIENT required flows allowed"; else fail "A7.7" "0.25" "SZ-CLIENT required flows not all allowed"; fi
  fi

  if should_run_criterion "A7.8"; then
    out="$(ssh_cmd sh-gw-a1 'nc -s 198.51.100.10 -vz -w2 10.11.40.10 389 || true; nc -s 198.51.100.10 -vz -w2 10.11.40.20 443 || true')"
    show_output "$out"
    if echo "$out" | grep -Eq "timed out|refused|failed"; then pass "A7.8" "0.25" "WAN-source direct access blocked"; else fail "A7.8" "0.25" "WAN-source direct access not blocked"; fi
  fi

  if should_run_criterion "A7.9"; then
    out="$(ssh_cmd sh-gw-a1 'nc -vz -w2 10.11.40.10 514 || nc -vzu -w2 10.11.40.10 514 || true'; ssh_cmd sz-gw-a1 'nc -vz -w2 10.11.40.10 514 || nc -vzu -w2 10.11.40.10 514 || true')"
    show_output "$out"
    if echo "$out" | grep -Eiq "succeeded|open"; then pass "A7.9" "0.25" "syslog flows to id-a1 allowed"; else fail "A7.9" "0.25" "syslog flows not proven allowed"; fi
  fi

  if should_run_criterion "A7.10"; then
    out="$(ssh_cmd sh-client-a1 'nc -vz -w2 10.11.30.10 445 || true' >/dev/null; ssh_cmd sh-gw-a1 'journalctl -k --no-pager | grep A1-SH-DROP | tail -5 || true'; ssh_cmd sz-gw-a1 'journalctl -k --no-pager | grep A1-SZ-DROP | tail -5 || true')"
    show_output "$out"
    if contains_all "$out" "A1-SH-DROP" "A1-SZ-DROP"; then pass "A7.10" "0.25" "drop logging prefixes present"; else fail "A7.10" "0.25" "drop logging prefixes missing"; fi
  fi

  if should_run_criterion "A7.11"; then
    if [ "$RUN_POST_REBOOT" = "1" ]; then
      out="$(ssh_cmd sh-gw-a1 'systemctl is-active nftables; nft list ruleset | grep A1-SH-DROP'; ssh_cmd sz-gw-a1 'systemctl is-active nftables; nft list ruleset | grep A1-SZ-DROP')"
      show_output "$out"
      if contains_all "$out" "active" "A1-SH-DROP" "A1-SZ-DROP"; then pass "A7.11" "0.25" "firewall persists after reboot"; else fail "A7.11" "0.25" "firewall not persistent"; fi
    else
      skip "A7.11" "0.25" "post-reboot check не запущен"
    fi
  fi
}

# --------------- A8 logs/evidence ---------------
check_A8() {
  section "A8 - Central logs, selfcheck, evidence and persistence"

  if should_run_criterion "A8.1"; then
    out="$(ssh_cmd id-a1 'ss -lntu | grep ":514" || true; systemctl is-active rsyslog 2>/dev/null || true')"
    show_output "$out"
    if echo "$out" | grep -q ":514" && echo "$out" | grep -q "active"; then pass "A8.1" "0.25" "central syslog receiver active"; else fail "A8.1" "0.25" "central syslog receiver not active/listening"; fi
  fi

  if should_run_criterion "A8.2"; then
    out="$(ssh_cmd sz-client-a1 'cat /opt/grading/a1/notes.txt 2>/dev/null')"
    show_output "$out"
    if echo "$out" | grep -Eiq 'udp/514|tcp/514|udp 514|tcp 514'; then pass "A8.2" "0.25" "notes.txt states selected syslog transport"; else fail "A8.2" "0.25" "notes.txt does not state selected syslog transport"; fi
  fi

  if should_run_criterion "A8.3"; then
    out="$(ssh_cmd id-a1 "for h in sh-gw-a1 sz-gw-a1 web-a1 files-a1 sz-client-a1 sh-client-a1; do echo --- \$h ---; grep -R \"\$h\" /var/log/remote /var/log 2>/dev/null | head -2; done")"
    show_output "$out"
    ok=1
    for h in sh-gw-a1 sz-gw-a1 web-a1 files-a1 sz-client-a1 sh-client-a1; do echo "$out" | grep -q "$h" || ok=0; done
    [ "$ok" -eq 1 ] && pass "A8.3" "0.50" "remote logs from required hosts visible" || fail "A8.3" "0.50" "remote logs incomplete"
  fi

  if should_run_criterion "A8.4"; then
    out="$(ssh_cmd id-a1 'grep -R "A1-SH-DROP\\|A1-SZ-DROP" /var/log/remote /var/log 2>/dev/null | tail -10')"
    show_output "$out"
    [ -n "$out" ] && pass "A8.4" "0.25" "drop events visible in central logs" || fail "A8.4" "0.25" "drop events not visible in central logs"
  fi

  if should_run_criterion "A8.5"; then
    out="$(ssh_cmd id-a1 'grep -R "web-a1\\|files-a1\\|sssd\\|slapd\\|samba\\|smbd\\|nfs" /var/log/remote /var/log 2>/dev/null | tail -30')"
    show_output "$out"
    if echo "$out" | grep -Eq "web-a1|files-a1|sssd|slapd|smbd|nfs"; then pass "A8.5" "0.50" "web/file/auth events visible in logs"; else fail "A8.5" "0.50" "web/file/auth events not visible"; fi
  fi

  if should_run_criterion "A8.6"; then
    out="$(ssh_cmd sz-client-a1 'ls -l /opt/grading/a1; test -s /opt/grading/a1/ca.pem; test -s /opt/grading/a1/id-a1.pem; test -s /opt/grading/a1/web-a1.pem; test -s /opt/grading/a1/checks.txt; test -s /opt/grading/a1/notes.txt; echo EVIDENCE_RC:$?')"
    show_output "$out"
    if echo "$out" | grep -q "EVIDENCE_RC:0"; then pass "A8.6" "0.50" "required evidence files exist"; else fail "A8.6" "0.50" "evidence files missing"; fi
  fi

  if should_run_criterion "A8.7"; then
    out="$(ssh_cmd sz-client-a1 'p=/opt/a1-checks/a1-selfcheck.sh; ls -l "$p" 2>&1 || true; if [ ! -e "$p" ]; then echo SELF_STATUS:missing; exit 1; fi; if [ ! -x "$p" ]; then echo SELF_STATUS:not_executable; exit 1; fi; timeout 120 "$p" >/tmp/a1-selfcheck-eval.out 2>&1; rc=$?; cat /tmp/a1-selfcheck-eval.out 2>/dev/null || true; echo SELF_RC:$rc; exit $rc')"
    show_output "$out"
    if echo "$out" | grep -q "SELF_RC:0"; then pass "A8.7" "0.50" "selfcheck executable and non-interactive"; else fail "A8.7" "0.50" "selfcheck missing/not executable/interactive/failing"; fi
  fi

  if should_run_criterion "A8.8"; then
    out="$(ssh_cmd sz-client-a1 'cat /opt/grading/a1/checks.txt 2>/dev/null')"
    show_output "$out"
    if contains_regex_all "$out" "DNS" "LDAP|SSSD" "HTTP|HTTPS|web" "NFS" "Samba" "nftables|firewall" "PASS|FAIL"; then pass "A8.8" "0.50" "checks.txt contains command output and PASS/FAIL blocks"; else fail "A8.8" "0.50" "checks.txt incomplete"; fi
  fi

  if should_run_criterion "A8.9"; then
    out="$(ssh_cmd sz-client-a1 'cat /opt/grading/a1/notes.txt 2>/dev/null')"
    show_output "$out"
    if [ -n "$out" ] && echo "$out" | grep -Eq "none|incomplete="; then pass "A8.9" "0.25" "notes.txt valid"; else fail "A8.9" "0.25" "notes.txt empty/invalid"; fi
  fi

  if should_run_criterion "A8.10"; then
    out="$(for h in "${HOSTS[@]}"; do echo "--- $h ---"; ssh_cmd "$h" 'hostname'; done)"
    show_output "$out"
    if [ "$(echo "$out" | grep -c '^---')" -eq 7 ] && [ "$(echo "$out" | grep -c 'Permission denied')" -eq 0 ]; then pass "A8.10" "0.25" "root SSH key works to all VM"; else fail "A8.10" "0.25" "root SSH key access missing to some VM"; fi
  fi

  if should_run_criterion "A8.11"; then
    if [ "$RUN_POST_REBOOT" = "1" ]; then
      out="$(ssh_cmd sh-client-a1 "dig @${A1_DNS_IP} www.${A1_DOMAIN} A +short; curl -LsS https://www.${A1_DOMAIN}/healthz; getent passwd amina; ls /net/projects 2>/dev/null"; ssh_cmd sz-client-a1 "getent passwd daryn; findmnt /mnt/projects; smbclient -L //files.${A1_DOMAIN} -U 'amina%${A1_PASS}' 2>&1 | grep projects")"
      show_output "$out"
      if contains_all "$out" "10.11.40.20" "OK" "amina" "/mnt/projects" "projects"; then pass "A8.11" "0.25" "critical end-to-end services survive reboot"; else fail "A8.11" "0.25" "critical end-to-end service smoke test failed after reboot"; fi
    else
      skip "A8.11" "0.25" "post-reboot check не запущен"
    fi
  fi
}

main() {
  validate_start_from
  init_remote_report_files

  echo -e "${CYAN}A1 Shanghai–Shenzhen Remote Evaluator${NC}"
  echo "Recommended launch host: sz-client-a1. Report dir: $A1_REPORT_DIR"
  if [ "$A1_RESUME_MODE" = "1" ]; then
    {
      echo ""
      echo "Resumed: $(date -Is)"
      echo "Start criterion: $A1_START_FROM"
    } | tee -a "$A1_DETAIL_LOG"
  else
    echo "Started: $(date -Is)" | tee -a "$A1_DETAIL_LOG"
  fi

  if [ "$A1_START_FROM" = "A1.1" ]; then
    check_ssh_all
  else
    echo -e "${CYAN}PRECHECK skipped - resume starts from $A1_START_FROM${NC}" | tee -a "$A1_DETAIL_LOG"
  fi
  run_check_block A1 check_A1
  run_check_block A2 check_A2
  run_check_block A3 check_A3
  run_check_block A4 check_A4
  run_check_block A5 check_A5
  run_check_block A6 check_A6
  run_check_block A7 check_A7
  run_check_block A8 check_A8
  write_summary
  echo -e "${CYAN}Remote evaluation completed. Reports: $A1_REPORT_DIR${NC}"
}

main "$@"
