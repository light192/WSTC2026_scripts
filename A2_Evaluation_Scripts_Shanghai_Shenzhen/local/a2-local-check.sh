#!/usr/bin/env bash
# A2 local checker for a single VM.
# Run as root on an A2 VM when the remote evaluator cannot reach all hosts.

set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/a2-common.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    --pause) A2_PAUSE=1 ;;
    --no-pause) A2_PAUSE=0 ;;
    --report-dir)
      shift
      [ $# -gt 0 ] || { echo "Не указано значение для --report-dir" >&2; exit 2; }
      A2_REPORT_DIR="$1"
      ;;
    *) echo "Неизвестная опция: $1"; exit 2 ;;
  esac
  shift
done

HN="$(hostname -s 2>/dev/null || hostname)"
A2_RESULTS_TSV="$A2_REPORT_DIR/a2-local-${HN}-results.tsv"
A2_DETAIL_LOG="$A2_REPORT_DIR/a2-local-${HN}-detail.log"
mkdir -p "$A2_REPORT_DIR"
printf "CriterionID\tMaxMark\tStatus\tMessage\n" > "$A2_RESULTS_TSV"
: > "$A2_DETAIL_LOG"
echo "Локальная проверка A2 на $HN начата $(date -Is)" | tee "$A2_DETAIL_LOG"

run_capture() {
  local id="$1"; shift
  local title="$1"; shift
  local command="$*"
  local out rc
  step "$id" "$title"
  cmd_show "$command"
  out="$(bash -o pipefail -c "$command" 2>&1)"
  rc=$?
  show_output "$out"$'\n'"ExitCode=$rc"
  A2_LAST_OUT="$out"
  A2_LAST_RC="$rc"
}

check_common() {
  section "ОБЩИЕ ПРОВЕРКИ - базовое состояние $HN"

  run_capture "A2.1.1" "hostname/FQDN" "hostname; hostname -f 2>/dev/null || true"
  if contains_all "$A2_LAST_OUT" "$HN" "$A2_DOMAIN"; then
    pass "A2.1.1" "0.25" "hostname/FQDN выглядит корректно на $HN"
  else
    warn "A2.1.1" "0.25" "hostname/FQDN требует ручной проверки на $HN"
  fi

  run_capture "A2.1.2" "адреса интерфейсов" "ip -br address show | egrep 'UP|UNKNOWN|10\\.22\\.|203\\.0\\.113\\.|2001:db8:a2' || true"
  if printf "%s\n" "$A2_LAST_OUT" | grep -Eq '10\.22\.|203\.0\.113\.|2001:db8:a2'; then
    pass "A2.1.2" "0.35" "адреса A2 видны на $HN"
  else
    fail "A2.1.2" "0.35" "адреса A2 не найдены на $HN"
  fi

  run_capture "A2.1.3" "маршрут по умолчанию" "ip route show default; ip -6 route show default 2>/dev/null || true"
  if [ -n "$A2_LAST_OUT" ] && printf "%s\n" "$A2_LAST_OUT" | grep -Eq 'default'; then
    pass "A2.1.3" "0.25" "маршрут по умолчанию присутствует на $HN"
  else
    warn "A2.1.3" "0.25" "маршрут по умолчанию не найден или требует ручной проверки на $HN"
  fi

  run_capture "A2.1.11" "часовой пояс/локаль/раскладка" "timedatectl 2>/dev/null | grep 'Time zone' || true; localectl status 2>/dev/null || true"
  if contains_all "$A2_LAST_OUT" "Europe/Paris" "en_US.UTF-8" && contains_regex_any "$A2_LAST_OUT" 'VC Keymap: *us|X11 Layout: *us|Keymap: *us'; then
    pass "A2.1.11" "0.15" "часовой пояс, локаль и раскладка корректны на $HN"
  else
    warn "A2.1.11" "0.15" "часовой пояс/локаль/раскладка требуют ручной проверки на $HN"
  fi
}

check_gateway() {
  section "ШЛЮЗ - маршрутизация, форвардинг и логи firewall на $HN"

  run_capture "A2.1.4" "статические IPv4-маршруты" "ip route | egrep '10\\.22\\.(10|20|30|40)\\.0/24|203\\.0\\.113\\.' || true"
  if printf "%s\n" "$A2_LAST_OUT" | grep -Eq '10\.22\.(10|20|30|40)\.0/24'; then
    pass "A2.1.4" "0.30" "статические IPv4-маршруты видны на $HN"
  else
    warn "A2.1.4" "0.30" "статические IPv4-маршруты не найдены на $HN"
  fi

  run_capture "A2.1.5" "IPv6-маршруты" "ip -6 route | egrep 'default|2001:db8:a2' || true"
  if printf "%s\n" "$A2_LAST_OUT" | grep -q '2001:db8:a2'; then
    pass "A2.1.5" "0.25" "IPv6-маршруты A2 видны на $HN"
  else
    warn "A2.1.5" "0.25" "IPv6-маршруты A2 требуют ручной проверки на $HN"
  fi

  run_capture "A2.1.6" "IPv4-форвардинг" "sysctl net.ipv4.ip_forward; grep -R '^net.ipv4.ip_forward *= *1' /etc/sysctl.conf /etc/sysctl.d 2>/dev/null || true"
  if contains_regex_all "$A2_LAST_OUT" 'net\.ipv4\.ip_forward *= *1'; then
    pass "A2.1.6" "0.20" "IPv4-форвардинг включен и найден persistent sysctl"
  else
    fail "A2.1.6" "0.20" "IPv4-форвардинг не включен или не сохранен"
  fi

  run_capture "A2.1.7" "IPv6-форвардинг" "sysctl net.ipv6.conf.all.forwarding; grep -R '^net.ipv6.conf.all.forwarding *= *1' /etc/sysctl.conf /etc/sysctl.d 2>/dev/null || true"
  if contains_regex_all "$A2_LAST_OUT" 'net\.ipv6\.conf\.all\.forwarding *= *1'; then
    pass "A2.1.7" "0.20" "IPv6-форвардинг включен и найден persistent sysctl"
  else
    fail "A2.1.7" "0.20" "IPv6-форвардинг не включен или не сохранен"
  fi

  run_capture "A2.8.6" "логирование drop в nftables" "systemctl is-active nftables 2>/dev/null || true; nft list ruleset 2>/dev/null | egrep 'A2-|DROP|log prefix' || true; journalctl -k --no-pager 2>/dev/null | grep -E 'A2-.*DROP|DROP' | tail -20 || true"
  if contains_regex_any "$A2_LAST_OUT" 'A2-.*DROP|DROP|log prefix'; then
    pass "A2.8.6" "0.20" "подтверждение логирования drop найдено на шлюзе"
  else
    warn "A2.8.6" "0.20" "подтверждение логирования drop локально не найдено"
  fi
}

check_auth() {
  section "AUTH-A2 - DNS, LDAP, PKI и центральные логи"

  run_capture "A2.2.1" "авторитативный DNS-сервис" "systemctl is-active bind9 named 2>/dev/null || true; ss -lntu | grep -E ':53\\b' || true; dig @127.0.0.1 ${A2_DOMAIN} SOA +norecurse 2>/dev/null | egrep 'SOA|flags:|SERVER' || true"
  if contains_regex_all "$A2_LAST_OUT" 'active|:53' 'SOA|flags:.*aa'; then
    pass "A2.2.1" "0.25" "DNS-сервис активен, слушает порт и отвечает как authoritative"
  else
    fail "A2.2.1" "0.25" "подтверждение DNS-сервиса/authoritative-ответа неполное"
  fi

  run_capture "A2.2.2" "ключевые A/AAAA-записи" "for n in east-edge-a2 east-ws-a2 core-edge-a2 ops-ws-a2 repo-a2 auth-a2 portal-a2; do echo \"== $n\"; dig @127.0.0.1 +short $n.${A2_DOMAIN} A; dig @127.0.0.1 +short $n.${A2_DOMAIN} AAAA; done"
  if contains_all "$A2_LAST_OUT" "10.22.10.1" "10.22.10.20" "10.22.20.1" "10.22.20.20" "10.22.30.10" "10.22.40.10" "10.22.40.20"; then
    pass "A2.2.2" "0.35" "основные DNS A-записи присутствуют"
  else
    fail "A2.2.2" "0.35" "часть основных DNS A-записей отсутствует"
  fi

  run_capture "A2.2.4" "CNAME-алиасы" "for n in dns ldap ca portal repo; do printf '%s -> ' \"$n\"; dig @127.0.0.1 +short $n.${A2_DOMAIN} CNAME; done"
  if contains_all "$A2_LAST_OUT" "auth-a2" "portal-a2" "repo-a2"; then
    pass "A2.2.4" "0.25" "CNAME-алиасы указывают на ожидаемые канонические имена"
  else
    fail "A2.2.4" "0.25" "CNAME-алиасы неполные"
  fi

  run_capture "A2.2.5" "LDAP SRV record" "dig @127.0.0.1 +short _ldap._tcp.${A2_DOMAIN} SRV"
  if contains_all "$A2_LAST_OUT" "389" "auth-a2"; then
    pass "A2.2.5" "0.20" "LDAP SRV опубликован"
  else
    fail "A2.2.5" "0.20" "LDAP SRV отсутствует или неверен"
  fi

  run_capture "A2.4.1" "LDAP base DN" "ldapsearch -ZZ -H ldap://127.0.0.1 -x -D '${A2_BIND_DN}' -w '${A2_PASS}' -b '${A2_BASE_DN}' -s base dn 2>&1 | egrep '^dn:|result:' || true"
  if contains_all "$A2_LAST_OUT" "dn: dc=atlas,dc=a2,dc=lab"; then
    pass "A2.4.1" "0.25" "LDAP base DN доступен"
  else
    fail "A2.4.1" "0.25" "LDAP base DN не подтвержден"
  fi

  run_capture "A2.4.2" "LDAP OU" "ldapsearch -ZZ -H ldap://127.0.0.1 -x -D '${A2_BIND_DN}' -w '${A2_PASS}' -b '${A2_BASE_DN}' '(objectClass=organizationalUnit)' ou 2>&1 | egrep '^dn:|^ou:|result:' || true"
  if contains_all "$A2_LAST_OUT" "ou: People" "ou: Groups" "ou: ServiceAccounts"; then
    pass "A2.4.2" "0.30" "OU People/Groups/ServiceAccounts существуют"
  else
    fail "A2.4.2" "0.30" "OU People/Groups/ServiceAccounts неполные"
  fi

  run_capture "A2.4.3" "LDAP groups gidNumber" "ldapsearch -ZZ -H ldap://127.0.0.1 -x -D '${A2_BIND_DN}' -w '${A2_PASS}' -b 'ou=Groups,${A2_BASE_DN}' '(objectClass=posixGroup)' cn gidNumber memberUid 2>&1 | egrep '^cn:|^gidNumber:|^memberUid:' || true"
  if contains_all "$A2_LAST_OUT" "cn: linuxadmins" "gidNumber: 7200" "cn: operators" "gidNumber: 7210" "cn: auditors" "gidNumber: 7220" "cn: engineers" "gidNumber: 7230" "cn: portalusers" "gidNumber: 7240"; then
    pass "A2.4.3" "0.40" "LDAP groups и gidNumber корректны"
  else
    fail "A2.4.3" "0.40" "LDAP groups/gidNumber неполные"
  fi

  run_capture "A2.4.4" "LDAP users uidNumber/home/shell" "ldapsearch -ZZ -H ldap://127.0.0.1 -x -D '${A2_BIND_DN}' -w '${A2_PASS}' -b 'ou=People,${A2_BASE_DN}' '(objectClass=posixAccount)' uid uidNumber gidNumber homeDirectory loginShell 2>&1 | egrep '^uid:|^uidNumber:|^gidNumber:|^homeDirectory:|^loginShell:' || true"
  if contains_all "$A2_LAST_OUT" "uid: li" "uidNumber: 8301" "uid: bekzat" "uidNumber: 8302" "uid: mei" "uidNumber: 8303" "uid: aliya" "uidNumber: 8304"; then
    pass "A2.4.4" "0.45" "LDAP users имеют ожидаемые uidNumber"
  else
    fail "A2.4.4" "0.45" "LDAP users/uidNumber неполные"
  fi

  run_capture "A2.4.6" "bind ldap-reader через StartTLS" "ldapsearch -ZZ -H ldap://127.0.0.1 -x -D '${A2_READER_DN}' -w '${A2_READER_PASS}' -b '${A2_BASE_DN}' -s base dn 2>&1 | egrep '^dn:|result:' || true"
  if contains_all "$A2_LAST_OUT" "dn: dc=atlas,dc=a2,dc=lab"; then
    pass "A2.4.6" "0.30" "bind ldap-reader через StartTLS работает"
  else
    fail "A2.4.6" "0.30" "bind ldap-reader через StartTLS не подтвержден"
  fi

  run_capture "A2.4.8" "anonymous RootDSE" "ldapsearch -H ldap://127.0.0.1 -x -s base -b '' namingContexts 2>&1 | egrep '^namingContexts:|result:' || true"
  if contains_all "$A2_LAST_OUT" "namingContexts"; then
    pass "A2.4.8" "0.20" "anonymous RootDSE доступен"
  else
    fail "A2.4.8" "0.20" "anonymous RootDSE недоступен"
  fi

  run_capture "A2.4.14" "LDAP-сервис включен" "systemctl is-enabled slapd 2>/dev/null || true; systemctl is-active slapd 2>/dev/null || true; ss -lntp | grep ':389' || true"
  if contains_all "$A2_LAST_OUT" "enabled" "active"; then
    pass "A2.4.14" "0.20" "LDAP-сервис enabled/active"
  else
    fail "A2.4.14" "0.20" "LDAP-сервис не enabled/active"
  fi

  run_capture "A2.8.1" "центральные remote-логи" "find /var/log -maxdepth 4 -type f 2>/dev/null | egrep 'east-edge-a2|core-edge-a2|east-ws-a2|ops-ws-a2|repo-a2|portal-a2|remote' | head -80 || true"
  if contains_regex_any "$A2_LAST_OUT" 'east-edge-a2|core-edge-a2|east-ws-a2|ops-ws-a2|repo-a2|portal-a2'; then
    pass "A2.8.1" "0.30" "remote-логи по хостам видны на auth-a2"
  else
    warn "A2.8.1" "0.30" "remote-логи локально не найдены"
  fi
}

check_sssd_host() {
  section "SSSD/PAM/SSH - $HN"

  run_capture "A2.5.1" "SSSD включен/активен" "systemctl is-enabled sssd 2>/dev/null || true; systemctl is-active sssd 2>/dev/null || true"
  if contains_all "$A2_LAST_OUT" "enabled" "active"; then
    pass "A2.5.1" "0.35" "SSSD enabled/active на $HN"
  else
    fail "A2.5.1" "0.35" "SSSD не enabled/active на $HN"
  fi

  run_capture "A2.5.2" "sssd.conf LDAP/TLS/bind" "grep -E '^(ldap_uri|ldap_id_use_start_tls|ldap_tls_reqcert|ldap_tls_cacert|ldap_default_bind_dn)' /etc/sssd/sssd.conf 2>/dev/null || true"
  if contains_all "$A2_LAST_OUT" "ldap_uri" "ldap_id_use_start_tls" "ldap_tls_reqcert" "ldap_tls_cacert" "ldap_default_bind_dn"; then
    pass "A2.5.2" "0.45" "sssd.conf содержит LDAP StartTLS и ldap-reader bind"
  else
    fail "A2.5.2" "0.45" "sssd.conf неполный для LDAP StartTLS"
  fi

  run_capture "A2.5.3" "права sssd.conf и проверка сертификата" "stat -c '%a %U:%G %n' /etc/sssd/sssd.conf 2>/dev/null || true; grep -Ei 'ldap_tls_reqcert *= *(never|allow)' /etc/sssd/sssd.conf 2>/dev/null || true"
  if contains_regex_any "$A2_LAST_OUT" '^(600|640) root:root' && ! contains_regex_any "$A2_LAST_OUT" 'never|allow'; then
    pass "A2.5.3" "0.25" "права sssd.conf корректны, проверка сертификата не отключена"
  else
    fail "A2.5.3" "0.25" "права sssd.conf или проверка сертификата требуют исправления"
  fi

  run_capture "A2.5.4" "LDAP-пользователи через NSS" "getent passwd li bekzat mei aliya 2>/dev/null || true"
  if contains_all "$A2_LAST_OUT" "li:" "bekzat:" "mei:" "aliya:"; then
    pass "A2.5.4" "0.40" "LDAP-пользователи видны через getent passwd"
  else
    fail "A2.5.4" "0.40" "не все LDAP-пользователи видны через getent passwd"
  fi

  run_capture "A2.5.5" "LDAP-группы через NSS" "getent group linuxadmins operators auditors engineers portalusers 2>/dev/null || true; id li 2>/dev/null || true; id bekzat 2>/dev/null || true; id mei 2>/dev/null || true; id aliya 2>/dev/null || true"
  if contains_all "$A2_LAST_OUT" "linuxadmins" "operators" "auditors" "engineers" "portalusers"; then
    pass "A2.5.5" "0.40" "LDAP-группы и членство видны через NSS"
  else
    fail "A2.5.5" "0.40" "LDAP-группы или членство неполные"
  fi

  run_capture "A2.6.8" "синтаксис sudoers" "visudo -cf /etc/sudoers 2>&1; find /etc/sudoers.d -type f -maxdepth 1 -exec sh -c 'for f; do visudo -cf \"$f\"; done' sh {} + 2>&1"
  if [ "$A2_LAST_RC" -eq 0 ]; then
    pass "A2.6.8" "0.20" "синтаксис sudoers корректен на $HN"
  else
    fail "A2.6.8" "0.20" "синтаксис sudoers некорректен на $HN"
  fi
}

check_portal() {
  section "PORTAL-A2 - HTTPS-портал"
  check_sssd_host

  run_capture "A2.7.1" "локальный HTTPS-портал" "systemctl is-active nginx apache2 2>/dev/null || true; ss -lntp | grep -E ':443\\b' || true; curl -k -LsS https://127.0.0.1/ 2>&1 | egrep 'A2_PORTAL_OK|HTTP|error' || true"
  if contains_all "$A2_LAST_OUT" "active" "A2_PORTAL_OK"; then
    pass "A2.7.1" "0.25" "portal HTTPS возвращает A2_PORTAL_OK локально"
  else
    fail "A2.7.1" "0.25" "содержимое HTTPS-портала или listener не подтверждены"
  fi

  run_capture "A2.7.4" "политика для HTTP/80" "curl -sS -o /dev/null -w 'HTTP_CODE=%{http_code} REDIRECT=%{redirect_url}\\n' http://127.0.0.1/ 2>&1 || true; ss -lntp | grep -E ':80\\b' || true"
  if contains_regex_any "$A2_LAST_OUT" 'HTTP_CODE=30[1278]|HTTP_CODE=000|Connection refused' && ! contains_all "$A2_LAST_OUT" "A2_PORTAL_OK"; then
    pass "A2.7.4" "0.25" "HTTP/80 не обслуживает портал открытым HTTP"
  else
    warn "A2.7.4" "0.25" "политика для HTTP/80 требует ручной проверки"
  fi

  run_capture "A2.8.5" "логи портала" "find /var/log -type f 2>/dev/null | egrep 'nginx|apache|portal' | head -40; grep -R '/admin' /var/log/nginx /var/log/apache2 /var/log/httpd 2>/dev/null | tail -30 || true"
  if contains_all "$A2_LAST_OUT" "/admin"; then
    pass "A2.8.5" "0.25" "логи портала фиксируют обращения к /admin"
  else
    warn "A2.8.5" "0.25" "подтверждение логов /admin локально не найдено"
  fi
}

check_repo() {
  section "REPO-A2 - /srv/repo/audit"
  check_sssd_host

  run_capture "A2.7.5" "ACL каталога audit" "ls -ld /srv/repo /srv/repo/audit 2>&1; getfacl -p /srv/repo/audit 2>/dev/null || true"
  if contains_all "$A2_LAST_OUT" "/srv/repo/audit" && contains_regex_any "$A2_LAST_OUT" 'li|linuxadmins|mei|auditors|acl|user:'; then
    pass "A2.7.5" "0.25" "/srv/repo/audit и подтверждение ACL найдены"
  else
    fail "A2.7.5" "0.25" "ACL для /srv/repo/audit не подтверждены"
  fi

  run_capture "A2.7.6" "доступ li на запись" "su - li -c 'echo LI_RW_OK > /srv/repo/audit/.a2-li-test && cat /srv/repo/audit/.a2-li-test && rm -f /srv/repo/audit/.a2-li-test' 2>&1"
  if contains_all "$A2_LAST_OUT" "LI_RW_OK"; then
    pass "A2.7.6" "0.20" "li имеет доступ на чтение/запись в /srv/repo/audit"
  else
    fail "A2.7.6" "0.20" "доступ li на чтение/запись в /srv/repo/audit не подтвержден"
  fi

  run_capture "A2.7.7" "доступ mei только на чтение" "su - mei -c 'ls /srv/repo/audit >/dev/null && echo MEI_READ_OK; echo x > /srv/repo/audit/.a2-mei-test && echo MEI_WRITE_BAD || echo MEI_WRITE_DENIED_OK' 2>&1; rm -f /srv/repo/audit/.a2-mei-test 2>/dev/null || true"
  if contains_all "$A2_LAST_OUT" "MEI_READ_OK" "MEI_WRITE_DENIED_OK" && ! contains_all "$A2_LAST_OUT" "MEI_WRITE_BAD"; then
    pass "A2.7.7" "0.20" "mei имеет доступ только на чтение"
  else
    fail "A2.7.7" "0.20" "доступ mei только на чтение не подтвержден"
  fi
}

check_client() {
  section "CLIENT - DNS, SSSD и доступ к порталу с $HN"
  check_sssd_host

  run_capture "A2.2.7" "резолвер и разрешение FQDN" "grep -E '^nameserver' /etc/resolv.conf; getent hosts portal.${A2_DOMAIN}; getent hosts ldap.${A2_DOMAIN}; dig @${A2_DNS_IP} +short portal.${A2_DOMAIN} A 2>/dev/null || true"
  if contains_all "$A2_LAST_OUT" "$A2_DNS_IP" "portal" "ldap"; then
    pass "A2.2.7" "0.25" "клиент использует резолвер auth-a2 и разрешает FQDN"
  else
    warn "A2.2.7" "0.25" "подтверждение резолвера/FQDN неполное на $HN"
  fi

  run_capture "A2.3.9" "проверка HTTPS-сертификата портала" "curl -LsS https://portal.${A2_DOMAIN}/ 2>&1 | egrep 'A2_PORTAL_OK|certificate|SSL|error' || true"
  if contains_all "$A2_LAST_OUT" "A2_PORTAL_OK"; then
    pass "A2.3.9" "0.30" "portal HTTPS проверяется и возвращает A2_PORTAL_OK"
  else
    fail "A2.3.9" "0.30" "проверка HTTPS-сертификата или содержимого портала не прошла"
  fi

  run_capture "A2.7.1" "содержимое портала" "curl -LsS https://portal.${A2_DOMAIN}/ 2>&1 | egrep 'A2_PORTAL_OK|HTTP|SSL|error' || true"
  if contains_all "$A2_LAST_OUT" "A2_PORTAL_OK"; then
    pass "A2.7.1" "0.25" "portal возвращает A2_PORTAL_OK с $HN"
  else
    fail "A2.7.1" "0.25" "portal не возвращает A2_PORTAL_OK с $HN"
  fi

  if [ "$HN" = "ops-ws-a2" ]; then
    run_capture "A2.8.7" "данные checks.txt" "grep -E 'Command:|Expected:|Actual:|Result:|PASS|FAIL' /root/checks.txt /home/*/checks.txt 2>/dev/null | head -80 || true"
    if contains_regex_all "$A2_LAST_OUT" 'Command:|Expected:|Actual:|Result:' 'PASS|FAIL'; then
      pass "A2.8.7" "0.25" "checks.txt содержит команды, ожидаемый результат, фактический вывод и итог"
    else
      warn "A2.8.7" "0.25" "данные checks.txt не найдены или неполные"
    fi

    run_capture "A2.8.9" "файлы подтверждения PKI" "while IFS= read -r f; do if openssl x509 -in \"\$f\" -noout >/dev/null 2>&1; then subject=\$(openssl x509 -in \"\$f\" -noout -subject 2>/dev/null); echo \"PEM_OK \$f \$subject\"; else echo \"PEM_BAD \$f\"; fi; done < <(find /opt/grading/a2/pki /root /home -maxdepth 4 -type f -name '*.pem' 2>/dev/null | sort)"
    if contains_all "$A2_LAST_OUT" "Atlas A2 Root CA" "Atlas A2 Services CA" && ! contains_any "$A2_LAST_OUT" "PEM_BAD"; then
      pass "A2.8.9" "0.15" "Root CA и Services CA найдены среди PEM-файлов по Subject CN"
    else
      warn "A2.8.9" "0.15" "Root CA/Services CA не найдены среди PEM-файлов на ops-ws-a2 или есть невалидный PEM"
    fi
  fi
}

case "$HN" in
  east-edge-a2|core-edge-a2)
    check_common
    check_gateway
    ;;
  auth-a2)
    check_common
    check_auth
    ;;
  repo-a2)
    check_common
    check_repo
    ;;
  portal-a2)
    check_common
    check_portal
    ;;
  east-ws-a2|ops-ws-a2)
    check_common
    check_client
    ;;
  *)
    check_common
    warn "LOCAL.UNKNOWN" "0" "неизвестная роль A2-хоста: $HN; выполнены только общие проверки"
    ;;
esac

write_summary
echo -e "${CYAN}Локальная проверка завершена на $HN. Отчеты: $A2_REPORT_DIR${NC}"
