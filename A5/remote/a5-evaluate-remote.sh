#!/usr/bin/env bash
# A5 remote evaluator. Recommended launch point: idm-a5 (10.55.40.10).

set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/a5-common.sh"

A5_HOSTS_FILE="${A5_HOSTS_FILE:-$SCRIPT_DIR/a5-hosts.conf}"
A5_START_FROM="${A5_START_FROM:-A5.1.01}"
A5_POST_REBOOT="${A5_POST_REBOOT:-0}"
A5_LAST_RC=0
A5_LAST_OUT=""
A5_COMPONENT_PASS=0
A5_COMPONENT_TOTAL=0
A5_COMPONENT_MESSAGE=""
A5_BUILD="2026-08-24.1"

usage() {
  cat <<'EOF'
Usage: sudo bash remote/a5-evaluate-remote.sh [options]
  --no-pause              do not pause after each aspect
  --pause                 pause after each aspect (default)
  --start-from A5.4.06    resume from an aspect
  --report-dir DIR        report output directory
  --post-reboot           include restart/persistence checks
  --hosts-file FILE       override host map
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --no-pause) A5_PAUSE=0 ;;
    --pause) A5_PAUSE=1 ;;
    --post-reboot) A5_POST_REBOOT=1 ;;
    --start-from) shift; A5_START_FROM="${1:?missing --start-from value}" ;;
    --report-dir) shift; A5_REPORT_DIR="${1:?missing --report-dir value}" ;;
    --hosts-file) shift; A5_HOSTS_FILE="${1:?missing --hosts-file value}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

A5_RESULTS_TSV="$A5_REPORT_DIR/a5-results.tsv"
A5_DETAIL_LOG="$A5_REPORT_DIR/a5-detail.log"
mkdir -p "$A5_REPORT_DIR"
printf 'CriterionID\tMaxMark\tStatus\tMessage\n' > "$A5_RESULTS_TSV"
: > "$A5_DETAIL_LOG"

PERSISTENCE_IDS=' A5.1.10 A5.3.12 A5.5.12 A5.6.08 '

manual_commands_for() {
  printf '%s\n' "$2"
}

ssh_precheck() {
  section "Предварительная проверка root SSH с idm-a5"
  local name ip out
  while IFS='=' read -r name ip; do
    [[ "$name" =~ ^[[:space:]]*# ]] && continue
    [ -n "$name" ] || continue
    printf '%-16s %-15s ' "$name" "$ip"
    out="$(timeout "$A5_TIMEOUT" /usr/bin/ssh -o BatchMode=yes \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -o ConnectTimeout="$A5_TIMEOUT" \
      root@"$ip" 'hostname -s' 2>&1)"
    if [ "$out" = "$name" ]; then echo -e "${GREEN}OK${NC}"
    else echo -e "${YELLOW}NO ACCESS${NC}: $out"; fi
  done < "$A5_HOSTS_FILE"
}

run_command() {
  local criterion="$1" command="$2" tmp out_file
  tmp="$(mktemp)"; out_file="$(mktemp)"
  {
    cat <<EOF
#!/usr/bin/env bash
set -o pipefail
ssh() {
  command timeout "${A5_TIMEOUT}s" /usr/bin/ssh \
    -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o ConnectTimeout="${A5_TIMEOUT}" -o ConnectionAttempts=1 \
    -o ServerAliveInterval=2 -o ServerAliveCountMax=2 \
    -o GSSAPIAuthentication=no "\$@"
}
EOF
    printf '%s\n' "$command"
  } > "$tmp"
  chmod 700 "$tmp"
  echo -e "${BLUE}Полный фактический вывод (stdout/stderr):${NC}"
  timeout "$A5_CMD_TIMEOUT" bash "$tmp" </dev/null 2>&1 |
    tee -a "$A5_DETAIL_LOG" "$out_file"
  A5_LAST_RC="${PIPESTATUS[0]}"
  A5_LAST_OUT="$(cat "$out_file")"
  [ -s "$out_file" ] || echo "(пустой вывод)"
  rm -f "$tmp" "$out_file"
}

all() { local text="$1" value; shift; for value in "$@"; do grep -Fqi "$value" <<<"$text" || return 1; done; }
any_re() { grep -Eiq "$2" <<<"$1"; }
none_re() { ! grep -Eiq "$2" <<<"$1"; }
count_re() { grep -Eic "$2" <<<"$1" || true; }
component_reset() {
  A5_COMPONENT_PASS=0
  A5_COMPONENT_TOTAL=0
  A5_COMPONENT_MESSAGE=""
}
component_check() {
  local label="$1"
  shift
  A5_COMPONENT_TOTAL=$((A5_COMPONENT_TOTAL + 1))
  if "$@"; then
    A5_COMPONENT_PASS=$((A5_COMPONENT_PASS + 1))
    echo -e "${GREEN}[PASS]${NC} $label"
  else
    echo -e "${RED}[FAIL]${NC} $label"
  fi
}
text_has_fixed() { grep -Fqi "$2" <<<"$1"; }
text_has_regex() { grep -Eiq "$2" <<<"$1"; }
mac_reservation_matches() {
  local text="$1" expected_ip="$2" mac
  mac="$(sed -n 's/^MAC=//p' <<<"$text" | head -n1)"
  [ -n "$mac" ] && grep -Fqi "$mac" <<<"$text" && grep -Fq "$expected_ip" <<<"$text"
}
soa_serials_match() {
  local text="$1" serials
  serials="$(awk 'NF{print $3}' <<<"$text" | sort -u)"
  [ -n "$serials" ] && [ "$(wc -l <<<"$serials")" -eq 1 ] && none_re "$text" 'SERVFAIL|REFUSED'
}
# Checks that an "anchor" line (e.g. "cn: netops") and a "pattern" line
# (e.g. "gidnumber: 5501") occur within the SAME blank-line-separated LDIF
# record, not merely anywhere in a multi-entry slapcat/ldapsearch dump. This
# is required to correctly detect swapped/misassigned attribute values.
ldif_line_in_record() {
  awk -v RS="" -v anchor="$2" -v pat="$3" '
    { rec = tolower($0) }
    rec ~ ("(^|\n)" tolower(anchor) "(\n|$)") && rec ~ ("(^|\n)" tolower(pat) "(\n|$)") { found = 1 }
    END { exit !found }
  ' <<<"$1"
}
not_ldif_line_in_record() { ! ldif_line_in_record "$@"; }

evaluate_components() {
  local id="$1" o="$2" name expected actual
  component_reset
  case "$id" in
    A5.2.03)
      echo -e "${BLUE}Покомпонентная оценка:${NC}"
      while IFS='|' read -r name expected; do
        component_check "${name}.${A5_DOMAIN} -> ${expected}" \
          text_has_fixed "$o" "$expected"
      done <<'EOF'
sh-gw-a5|10.55.10.1
sh-gw-a5|2001:db8:a5:10::1
sh-client-a5|10.55.10.100
sh-client-a5|2001:db8:a5:10::100
sz-gw-a5|10.55.20.1
sz-gw-a5|2001:db8:a5:20::1
sz-client-a5|10.55.20.100
sz-client-a5|2001:db8:a5:20::100
idm-a5|10.55.40.10
idm-a5|2001:db8:a5:40::10
net-a5|10.55.40.20
net-a5|2001:db8:a5:40::20
portal-a5|10.55.30.10
portal-a5|2001:db8:a5:30::10
EOF
      ;;
    A5.2.04)
      echo -e "${BLUE}Покомпонентная оценка:${NC}"
      component_check "ldap.${A5_DOMAIN} -> idm-a5.${A5_DOMAIN}." \
        text_has_fixed "$o" 'CNAME=ldap;ACTUAL=idm-a5.atlas.a5.test.'
      component_check "dns1.${A5_DOMAIN} -> idm-a5.${A5_DOMAIN}." \
        text_has_fixed "$o" 'CNAME=dns1;ACTUAL=idm-a5.atlas.a5.test.'
      component_check "dns2.${A5_DOMAIN} -> net-a5.${A5_DOMAIN}." \
        text_has_fixed "$o" 'CNAME=dns2;ACTUAL=net-a5.atlas.a5.test.'
      component_check "portal.${A5_DOMAIN} -> portal-a5.${A5_DOMAIN}." \
        text_has_fixed "$o" 'CNAME=portal;ACTUAL=portal-a5.atlas.a5.test.'
      component_check "syslog.${A5_DOMAIN} -> net-a5.${A5_DOMAIN}." \
        text_has_fixed "$o" 'CNAME=syslog;ACTUAL=net-a5.atlas.a5.test.'
      ;;
    A5.4.03)
      echo -e "${BLUE}Покомпонентная оценка (сопоставление внутри одной LDIF-записи):${NC}"
      component_check "netops: gidNumber=5501" \
        ldif_line_in_record "$o" 'cn: netops' 'gidnumber: 5501'
      component_check "webops: gidNumber=5502" \
        ldif_line_in_record "$o" 'cn: webops' 'gidnumber: 5502'
      ;;
    A5.4.04)
      echo -e "${BLUE}Покомпонентная оценка (сопоставление внутри одной LDIF-записи):${NC}"
      component_check "nora: uidNumber=6501" \
        ldif_line_in_record "$o" 'uid: nora' 'uidnumber: 6501'
      component_check "nora: gidNumber=5501" \
        ldif_line_in_record "$o" 'uid: nora' 'gidnumber: 5501'
      component_check "erlan: uidNumber=6502" \
        ldif_line_in_record "$o" 'uid: erlan' 'uidnumber: 6502'
      component_check "erlan: gidNumber=5501" \
        ldif_line_in_record "$o" 'uid: erlan' 'gidnumber: 5501'
      ;;
    A5.4.05)
      echo -e "${BLUE}Покомпонентная оценка (сопоставление внутри записи cn: webops):${NC}"
      component_check "webops содержит nora (member/memberUid)" \
        ldif_line_in_record "$o" 'cn: webops' 'member(uid)?: .*nora'
      component_check "webops НЕ содержит erlan (member/memberUid)" \
        not_ldif_line_in_record "$o" 'cn: webops' 'member(uid)?: .*erlan'
      ;;
    A5.6.06)
      echo -e "${BLUE}Покомпонентная оценка:${NC}"
      for name in sh-gw-a5.log sz-gw-a5.log idm-a5.log portal-a5.log; do
        component_check "central log-файл ${name} присутствует" text_has_fixed "$o" "$name"
      done
      ;;
    A5.6.07)
      echo -e "${BLUE}Покомпонентная оценка:${NC}"
      for name in sh-gw-a5 sz-gw-a5 idm-a5 portal-a5; do
        component_check "${name}: маркер A5_READY получен централизованно" \
          text_has_fixed "$o" "A5_READY $name"
      done
      ;;
    A5.9.01)
      echo -e "${BLUE}Покомпонентная оценка:${NC}"
      for f in network.txt dns.txt dhcp.txt ldap.txt portal.txt ops.txt ansible.txt notes.txt; do
        component_check "$f присутствует и не пуст" text_has_fixed "$o" "$f OK"
      done
      ;;
  esac
  if [ "$A5_COMPONENT_TOTAL" -gt 0 ]; then
    A5_COMPONENT_MESSAGE="${A5_COMPONENT_PASS}/${A5_COMPONENT_TOTAL} компонентов пройдено"
    return 0
  fi
  return 1
}

ok_basic() {
  [ "$2" -eq 0 ] && [ -n "$(tr -d '[:space:]' <<<"$1")" ] &&
    none_re "$1" 'Permission denied|command not found|No such file or directory|syntax error|Connection timed out'
}

evaluate_result() {
  local id="$1" o="$2" rc="$3"
  case "$id" in
    A5.1.01) all "$o" sh-gw-a5 sh-client-a5 sz-gw-a5 sz-client-a5 idm-a5 net-a5 portal-a5 ;;
    A5.1.02) all "$o" 10.55.10.1/24 10.55.10.100/24 198.18.55.10/24 198.18.55.20/24 10.55.20.1/24 10.55.30.1/24 10.55.40.1/24 10.55.20.100/24 10.55.40.10/24 10.55.40.20/24 10.55.30.10/24 ;;
    A5.1.03) all "$o" 2001:db8:a5:10::1/64 2001:db8:a5:100::10/64 2001:db8:a5:10::100/64 2001:db8:a5:100::20/64 2001:db8:a5:20::1/64 2001:db8:a5:30::1/64 2001:db8:a5:40::1/64 2001:db8:a5:20::100/64 2001:db8:a5:40::10/64 2001:db8:a5:40::20/64 2001:db8:a5:30::10/64 ;;
    A5.1.04)
      [ "$(count_re "$o" 'net.ipv4.ip_forward[[:space:]]*=[[:space:]]*1')" -ge 2 ] &&
        [ "$(count_re "$o" 'net.ipv6.conf.all.forwarding[[:space:]]*=[[:space:]]*1')" -ge 2 ]
      ;;
    A5.1.05) all "$o" 10.55.20.0/24 10.55.30.0/24 10.55.40.0/24 198.18.55.20 10.55.10.0/24 198.18.55.10 ;;
    A5.1.06) all "$o" 2001:db8:a5:20::/64 2001:db8:a5:30::/64 2001:db8:a5:40::/64 2001:db8:a5:100::20 2001:db8:a5:10::/64 2001:db8:a5:100::10 ;;
    A5.1.07|A5.1.08) [ "$rc" -eq 0 ] && [ "$(count_re "$o" '0% packet loss')" -ge 6 ] ;;
    A5.1.09) [ "$(count_re "$o" 'ssh-ok')" -ge 6 ] ;;
    A5.1.10) all "$o" sh-gw-a5 sh-client-a5 sz-gw-a5 sz-client-a5 idm-a5 net-a5 portal-a5 && ok_basic "$o" "$rc" ;;

    A5.2.01) any_re "$o" 'SOA' && any_re "$o" 'NS' && none_re "$o" 'SERVFAIL|REFUSED' ;;
    A5.2.02) soa_serials_match "$o" ;;
    A5.2.05) [ "$(count_re "$o" 'atlas.a5.test.')" -ge 9 ] ;;
    A5.2.06) none_re "$o" 'Transfer failed|REFUSED|connection timed out' && any_re "$o" 'SOA' ;;
    A5.2.07) any_re "$o" 'Transfer failed|REFUSED|communications error|timed out|connection refused' ;;
    A5.2.08) [ "$(count_re "$o" 'flags:[^;]*\bra\b')" -ge 2 ] && none_re "$o" 'status: REFUSED' ;;
    A5.2.09) all "$o" 10.55.10.0/24 10.55.20.0/24 10.55.30.0/24 10.55.40.0/24 && none_re "$o" '198\.18\.55\.0/24|allow-recursion[^;]*\bany\b' ;;
    A5.2.10) [ "$(count_re "$o" '10.55.40.10|10.55.40.20|127.0.0.1')" -ge 7 ] ;;
    A5.2.11) any_re "$o" 'type (master|primary)' && any_re "$o" 'type (slave|secondary)' && any_re "$o" '10.55.40.20' && any_re "$o" '10.55.40.10' ;;
    A5.2.12) any_re "$o" 'portal-a5' && any_re "$o" 'active' ;;

    A5.3.01) any_re "$o" 'enabled' && any_re "$o" 'active' && any_re "$o" ':67' ;;
    A5.3.02|A5.3.03) any_re "$o" 'dhcrelay|dhcp.?relay' && any_re "$o" '10\.55\.40\.20|net-a5' ;;
    A5.3.04) all "$o" 10.55.10.100 10.55.10.149 10.55.20.100 10.55.20.149 ;;
    A5.3.05) mac_reservation_matches "$o" 10.55.10.100 ;;
    A5.3.06) mac_reservation_matches "$o" 10.55.20.100 ;;
    A5.3.07) any_re "$o" 'default via 10\.55\.10\.1(\s|$)' ;;
    A5.3.08) any_re "$o" 'default via 10\.55\.20\.1(\s|$)' ;;
    A5.3.09) [ "$(count_re "$o" '10.55.40.10')" -ge 2 ] && [ "$(count_re "$o" '10.55.40.20')" -ge 2 ] && [ "$(count_re "$o" 'atlas.a5.test')" -ge 2 ] ;;
    A5.3.10) any_re "$o" '10.55.10.100' && any_re "$o" '10.55.20.100' ;;
    A5.3.11) any_re "$o" '10.55.40.20/24' && none_re "$o" '10\.55\.10\.|10\.55\.20\.' ;;
    A5.3.12) any_re "$o" 'active' && any_re "$o" '10.55.10.100/24' && any_re "$o" '10.55.20.100/24' ;;

    A5.4.01) any_re "$o" 'active' && any_re "$o" 'dc=atlas,dc=a5,dc=test' ;;
    A5.4.02) all "$o" 'ou=people,dc=atlas,dc=a5,dc=test' 'ou=groups,dc=atlas,dc=a5,dc=test' 'ou=services,dc=atlas,dc=a5,dc=test' ;;
    A5.4.05) any_re "$o" 'uid=nora|memberuid: nora' && none_re "$o" 'uid=erlan|memberuid: erlan' ;;
    A5.4.06) any_re "$o" 'dn:\s*uid=ldap-reader,ou=services,dc=atlas,dc=a5,dc=test' ;;
    A5.4.07) all "$o" 'uid:' uidnumber gidnumber homedirectory ;;
    A5.4.08) any_re "$o" 'insufficient access|no such attribute|result: 50' ;;
    A5.4.09) none_re "$o" 'uid=nora|uid=erlan' ;;
    A5.4.10) none_re "$o" '^userpassword:' ;;
    A5.4.11) all "$o" olctlscertificatefile olctlscertificatekeyfile olctlscacertificatefile ;;
    A5.4.12)
      none_re "$o" 'TLS: hostname does not match|ldap_start_tls:.*Connect error|Peer certificate cannot be verified|self.signed certificate|certificate verify failed' &&
        any_re "$o" 'namingContexts:|^dn:' &&
        none_re "$o" 'tls_reqcert[[:space:]]+(never|allow)'
      ;;
    A5.4.13)
      [ "$(count_re "$o" 'ldap-reader')" -ge 2 ] &&
        [ "$(count_re "$o" 'ldap_id_use_start_tls[[:space:]]*=[[:space:]]*true')" -ge 2 ] &&
        none_re "$o" 'ldap_tls_reqcert[[:space:]]*=[[:space:]]*never'
      ;;
    A5.4.14) all "$o" nora erlan SH_NOT_LOCAL SZ_NOT_LOCAL ;;
    A5.4.15)
      [ "$(count_re "$o" 'uid=6501\(nora\)')" -ge 2 ] &&
        [ "$(count_re "$o" 'uid=6502\(erlan\)')" -ge 2 ]
      ;;
    A5.4.16) [ "$(count_re "$o" '/home/nora')" -ge 2 ] && [ "$(count_re "$o" '/home/erlan')" -ge 2 ] ;;

    A5.5.01) any_re "$o" 'enabled' && any_re "$o" 'active' && any_re "$o" ':443' ;;
    A5.5.02) any_re "$o" 'portal\.atlas\.a5\.test' ;;
    A5.5.03) any_re "$o" 'portal\.atlas\.a5\.test' && any_re "$o" 'issuer' ;;
    A5.5.04) [ "$(count_re "$o" '^200$')" -ge 2 ] ;;
    A5.5.05) all "$o" 'A5 PORTAL READY' portal-a5 ;;
    A5.5.06) any_re "$o" '^HTTP.*30[12]' && any_re "$o" 'https://portal\.atlas\.a5\.test' ;;
    A5.5.07) any_re "$o" '^401$' ;;
    A5.5.08) any_re "$o" '^200$' ;;
    A5.5.09) any_re "$o" '^403$' ;;
    A5.5.10) all "$o" authldapbinddn ldap-reader && none_re "$o" 'authuserfile' ;;
    A5.5.11) any_re "$o" 'authldapurl' && none_re "$o" 'tls_reqcert[[:space:]]+never' ;;
    A5.5.12) any_re "$o" 'active' && any_re "$o" '^200$' ;;

    A5.6.01) any_re "$o" 'reference id|stratum' && any_re "$o" 'allow' ;;
    A5.6.02) [ "$(count_re "$o" '\^\*')" -ge 6 ] ;;
    A5.6.03) any_re "$o" 'active' && any_re "$o" ':514' ;;
    A5.6.04) [ "$(count_re "$o" '@@10\.55\.40\.20|10\.55\.40\.20.*514')" -ge 4 ] ;;
    A5.6.05) [ "$rc" -eq 0 ] ;;
    A5.6.08) [ "$(count_re "$o" 'active')" -ge 5 ] && [ "$(count_re "$o" 'A5_RESTART_TEST')" -ge 4 ] ;;

    A5.7.01|A5.7.02) all "$o" enabled active && any_re "$o" 'table' ;;
    A5.7.03) any_re "$o" 'hook forward' && any_re "$o" 'drop' ;;
    A5.7.04) any_re "$o" 'established' ;;
    A5.7.05) [ "$(count_re "$o" 'atlas\.a5\.test\.')" -ge 4 ] && none_re "$o" 'timed out|connection refused|no servers could be reached' ;;
    A5.7.06|A5.7.07) [ "$(count_re "$o" 'succeeded|open')" -ge 2 ] ;;
    A5.7.08) [ "$(count_re "$o" 'succeeded|open')" -ge 4 ] && [ "$(count_re "$o" 'ssh-ok')" -ge 6 ] ;;
    A5.7.09) none_re "$o" 'succeeded|open' ;;
    A5.7.10) any_re "$o" 'A5-SH-DROP' ;;
    A5.7.11) any_re "$o" 'A5-SZ-DROP' ;;
    A5.7.12) none_re "$o" 'masquerade|snat' && any_re "$o" '10\.55\.10\.100' ;;

    A5.8.01) any_re "$o" 'STRUCT_OK' ;;
    A5.8.02) all "$o" '@gateways' '@clients' '@servers' '@all_linux' ;;
    A5.8.03) [ "$(count_re "$o" '\| SUCCESS =>')" -ge 7 ] && none_re "$o" '\| UNREACHABLE|\| FAILED' ;;
    A5.8.08) any_re "$o" '\.j2' && any_re "$o" 'template:' ;;
    A5.8.09) any_re "$o" 'notify:' && any_re "$o" 'handlers:' ;;
    A5.8.10)
      local second_run
      second_run="$(awk '/===SECOND-RUN===/{f=1;next} f' <<<"$o")"
      [ -n "$second_run" ] &&
        [ "$(count_re "$second_run" 'unreachable=0')" -ge 7 ] &&
        [ "$(count_re "$second_run" 'failed=0')" -ge 7 ]
      ;;

    A5.9.01) [ "$(count_re "$o" '\.txt OK$')" -eq 8 ] && none_re "$o" 'MISSING' ;;
    A5.9.03) any_re "$o" 'NO_SECRETS_FOUND' && none_re "$o" 'BEGIN (RSA |EC |)PRIVATE KEY' ;;
    A5.9.04) [ "$rc" -eq 0 ] && [ -n "$(tr -d '[:space:]' <<<"$o")" ] ;;

    *) ok_basic "$o" "$rc" ;;
  esac
}

show_diagnostics() {
  local id="$1" o="$2" name expected actual
  case "$id" in
    A5.2.03)
      echo -e "${BLUE}Подробная проверка свойств:${NC}"
      while IFS='|' read -r name expected; do
        if grep -Fqi "$expected" <<<"$o"; then
          echo -e "${GREEN}[OK]${NC} ${name}.${A5_DOMAIN} -> ${expected}"
        else
          echo -e "${RED}[FAIL]${NC} ${name}.${A5_DOMAIN}: ожидается ${expected}"
        fi
      done <<'EOF'
sh-gw-a5|10.55.10.1
sh-gw-a5|2001:db8:a5:10::1
sh-client-a5|10.55.10.100
sh-client-a5|2001:db8:a5:10::100
sz-gw-a5|10.55.20.1
sz-gw-a5|2001:db8:a5:20::1
sz-client-a5|10.55.20.100
sz-client-a5|2001:db8:a5:20::100
idm-a5|10.55.40.10
idm-a5|2001:db8:a5:40::10
net-a5|10.55.40.20
net-a5|2001:db8:a5:40::20
portal-a5|10.55.30.10
portal-a5|2001:db8:a5:30::10
EOF
      ;;
    A5.2.04)
      echo -e "${BLUE}Подробная проверка свойств:${NC}"
      while IFS='|' read -r name expected; do
        actual="$(sed -n "s/^CNAME=${name};ACTUAL=//p" <<<"$o" | head -n1)"
        [ -n "$actual" ] || actual="<EMPTY>"
        if [ "${actual,,}" = "${expected,,}" ]; then
          echo -e "${GREEN}[OK]${NC} ${name}.${A5_DOMAIN} -> ${actual}"
        else
          echo -e "${RED}[FAIL]${NC} ${name}.${A5_DOMAIN}: ожидается ${expected}; получено ${actual}"
        fi
      done <<'EOF'
ldap|idm-a5.atlas.a5.test.
dns1|idm-a5.atlas.a5.test.
dns2|net-a5.atlas.a5.test.
portal|portal-a5.atlas.a5.test.
syslog|net-a5.atlas.a5.test.
EOF
      ;;
  esac
}

validate_start() {
  awk -F'\t' -v id="$A5_START_FROM" 'NR>1 && $1==id{f=1} END{exit !f}' "$A5_CRITERIA_MAP" ||
    { echo "Aspect $A5_START_FROM not found" >&2; exit 2; }
}

main() {
  validate_start
  echo -e "${CYAN}A5 remote evaluator — Integrated Enterprise Linux Services (build $A5_BUILD)${NC}"
  echo "Рекомендуемый хост запуска: idm-a5 (10.55.40.10)"
  echo "Отчёты: $A5_REPORT_DIR"
  ssh_precheck
  local started=0 id sub desc mark runfrom commands expected notes command awarded last_sub=""
  while IFS=$'\t' read -r id sub desc mark runfrom commands expected notes; do
    [ "$id" = CriterionID ] && continue
    [ "$id" = "$A5_START_FROM" ] && started=1
    [ "$started" = 1 ] || continue
    if [ "$sub" != "$last_sub" ]; then section "$sub"; last_sub="$sub"; fi
    step "$id" "$desc"
    if [[ "$PERSISTENCE_IDS" == *" $id "* ]] && [ "$A5_POST_REBOOT" != 1 ]; then
      skip "$id" "$mark" "используйте --post-reboot после согласованного restart/reboot"
      continue
    fi
    command="$(decode_newlines "$commands")"
    cmd_show "$id" "$command"
    run_command "$id" "$command"
    show_output "ExitCode=$A5_LAST_RC (полный вывод показан выше)"
    if evaluate_components "$id" "$A5_LAST_OUT"; then
      if [ "$A5_COMPONENT_PASS" -eq "$A5_COMPONENT_TOTAL" ]; then
        pass "$id" "$mark" "$A5_COMPONENT_MESSAGE"
      elif [ "$A5_COMPONENT_PASS" -gt 0 ]; then
        awarded="$(awk -v m="$mark" -v p="$A5_COMPONENT_PASS" -v t="$A5_COMPONENT_TOTAL" \
          'BEGIN { printf "%.3f", m*p/t }')"
        part "$id" "$mark" "$awarded" "$A5_COMPONENT_MESSAGE"
      else
        fail "$id" "$mark" "$A5_COMPONENT_MESSAGE"
      fi
    elif evaluate_result "$id" "$A5_LAST_OUT" "$A5_LAST_RC"; then
      show_diagnostics "$id" "$A5_LAST_OUT"
      pass "$id" "$mark" "фактический вывод соответствует ожидаемому результату"
    else
      show_diagnostics "$id" "$A5_LAST_OUT"
      fail "$id" "$mark" "ожидаемые свойства не подтверждены: $expected"
    fi
  done < "$A5_CRITERIA_MAP"
  write_summary
}

main "$@"
