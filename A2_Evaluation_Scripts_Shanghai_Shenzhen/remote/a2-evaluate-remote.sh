#!/usr/bin/env bash
# A2 remote evaluator for Shanghai-Shenzhen task.
# Recommended launch host: ops-ws-a2 as root.

set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/a2-common.sh"

RUN_POST_REBOOT=0
A2_START_FROM="${A2_START_FROM:-A2.1.1}"
A2_RESUME_MODE=0
A2_START_MAJOR=1
A2_START_MINOR=1
A2_START_KEY=1001

usage() {
  cat <<'EOF'
Использование: bash remote/a2-evaluate-remote.sh [опции]

Опции:
  --pause                  Пауза после каждого проверенного аспекта (по умолчанию).
  --no-pause               Запуск без пауз между аспектами.
  --post-reboot            Выполнить проверки persistence после reboot.
  --report-dir DIR         Записать отчеты в DIR.
  --start-from A2.4.6      Продолжить с указанного критерия/подкритерия.
  --resume-from A2.4.6     То же, что --start-from.
  -h, --help               Показать эту справку.

Переменные окружения:
  A2_PASS                  Пароль admin bind, по умолчанию Skill39@A1.
  A2_USER_PASS             Пароль LDAP-пользователей, по умолчанию Skill39@A2.
  A2_READER_PASS           Пароль ldap-reader, по умолчанию Skill39@A2reader.
  A2_TIMEOUT               Таймаут SSH-подключения, по умолчанию 6.
  A2_CMD_TIMEOUT           Таймаут команды на критерий, по умолчанию 180.
EOF
}

normalize_criterion_id() {
  local raw
  raw="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  if [[ "$raw" =~ ^A2\.([1-8])$ ]]; then
    printf 'A2.%s.1\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$raw" =~ ^A2\.([1-8])\.([0-9]+)$ ]]; then
    printf 'A2.%s.%s\n' "${BASH_REMATCH[1]}" "$((10#${BASH_REMATCH[2]}))"
    return 0
  fi
  return 1
}

criterion_key() {
  local id
  id="$(normalize_criterion_id "$1")" || return 1
  [[ "$id" =~ ^A2\.([1-8])\.([0-9]+)$ ]] || return 1
  printf '%s\n' "$((BASH_REMATCH[1] * 1000 + BASH_REMATCH[2]))"
}

validate_start_from() {
  local normalized
  normalized="$(normalize_criterion_id "$A2_START_FROM")" || {
    echo "Некорректный индекс критерия для --start-from: $A2_START_FROM" >&2
    echo "Используйте A2.1, A2.1.1, A2.4.6 и т.п." >&2
    exit 2
  }
  A2_START_FROM="$normalized"
  [[ "$A2_START_FROM" =~ ^A2\.([1-8])\.([0-9]+)$ ]] || exit 2
  A2_START_MAJOR="${BASH_REMATCH[1]}"
  A2_START_MINOR="${BASH_REMATCH[2]}"
  A2_START_KEY="$(criterion_key "$A2_START_FROM")"
}

should_run_criterion() {
  local key
  key="$(criterion_key "$1")" || return 1
  [ "$key" -ge "$A2_START_KEY" ]
}

init_remote_report_files() {
  mkdir -p "$A2_REPORT_DIR"
  if [ "$A2_RESUME_MODE" = "1" ]; then
    [ -s "$A2_RESULTS_TSV" ] || printf "CriterionID\tMaxMark\tStatus\tMessage\n" > "$A2_RESULTS_TSV"
    touch "$A2_DETAIL_LOG"
  else
    printf "CriterionID\tMaxMark\tStatus\tMessage\n" > "$A2_RESULTS_TSV"
    : > "$A2_DETAIL_LOG"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pause) A2_PAUSE=1 ;;
    --no-pause) A2_PAUSE=0 ;;
    --post-reboot) RUN_POST_REBOOT=1 ;;
    --report-dir)
      shift
      [ $# -gt 0 ] || { echo "Не указано значение для --report-dir" >&2; exit 2; }
      A2_REPORT_DIR="$1"
      A2_RESULTS_TSV="$A2_REPORT_DIR/a2-results.tsv"
      A2_DETAIL_LOG="$A2_REPORT_DIR/a2-detail.log"
      ;;
    --start-from|--resume-from)
      opt="$1"
      shift
      [ $# -gt 0 ] || { echo "Не указано значение для $opt" >&2; exit 2; }
      A2_START_FROM="$1"
      A2_RESUME_MODE=1
      ;;
    --start-from=*|--resume-from=*)
      A2_START_FROM="${1#*=}"
      A2_RESUME_MODE=1
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Неизвестная опция: $1"; exit 2 ;;
  esac
  shift
done

declare -A HOST_IP=(
  [east-edge-a2]="10.22.10.1"
  [east-ws-a2]="10.22.10.20"
  [core-edge-a2]="10.22.20.1"
  [ops-ws-a2]="10.22.20.20"
  [repo-a2]="10.22.30.10"
  [auth-a2]="10.22.40.10"
  [portal-a2]="10.22.40.20"
)

HOSTS=(east-edge-a2 east-ws-a2 core-edge-a2 ops-ws-a2 repo-a2 auth-a2 portal-a2)

ssh_root() {
  local host="$1"; shift
  local ip="${HOST_IP[$host]:-$host}"
  command ssh -n \
    -o BatchMode=yes \
    -o ConnectTimeout="$A2_TIMEOUT" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    "root@$ip" "$@" 2>&1
}

check_ssh_all() {
  section "ПРЕДВАРИТЕЛЬНАЯ ПРОВЕРКА - SSH-доступ к VM"
  local ok=1
  local h
  for h in "${HOSTS[@]}"; do
    if ssh_root "$h" "true" >/dev/null 2>&1; then
      echo -e "${GREEN}OK - SSH $h (${HOST_IP[$h]})${NC}"
    else
      echo -e "${RED}НЕ ДОСТУПЕН - SSH $h (${HOST_IP[$h]})${NC}"
      ok=0
    fi
  done
  if [ "$ok" -eq 1 ]; then
    echo -e "${GREEN}Все VM доступны по SSH. Можно выполнять удаленную проверку.${NC}"
  else
    echo -e "${YELLOW}Часть VM недоступна. Удаленная проверка продолжится; для недоступных хостов используйте local/a2-local-check.sh.${NC}"
  fi
  pause_if_needed
}

prepare_command() {
  local command="$1"
  command="${command//-W /-w \"$A2_PASS\" }"
  printf "%s" "$command"
}

run_eval_command() {
  local command="$1"
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<'EOS'
#!/usr/bin/env bash
set -o pipefail
a2_ssh_password_command() {
  local pass="${A2_USER_PASS:-Skill39@A2}"

  if command -v sshpass >/dev/null 2>&1; then
    command sshpass -p "$pass" ssh -n "$@"
    return $?
  fi

  local askpass rc
  askpass="$(mktemp)" || return 127
  cat > "$askpass" <<'ASKPASS_EOF'
#!/usr/bin/env sh
printf '%s\n' "$A2_USER_PASS"
ASKPASS_EOF
  chmod 700 "$askpass"
  if command -v setsid >/dev/null 2>&1; then
    A2_USER_PASS="$pass" SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-:0}" setsid -w ssh -n "$@"
  else
    A2_USER_PASS="$pass" SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-:0}" ssh -n "$@"
  fi
  rc=$?
  rm -f "$askpass"
  return "$rc"
}
ssh() {
  local args=()
  local batch=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -o)
        if [ "${2:-}" = "BatchMode=yes" ]; then batch=1; fi
        args+=("$1" "${2:-}")
        shift 2
        ;;
      -oBatchMode=yes)
        batch=1
        args+=("$1")
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        args+=("$1")
        shift
        ;;
      *)
        break
        ;;
    esac
  done
  local dest="${1:-}"
  [ $# -gt 0 ] && shift
  local user="$dest"
  if [[ "$user" == *@* ]]; then user="${user%@*}"; fi
  local base=(-o ConnectTimeout="${A2_TIMEOUT:-6}" -o ConnectionAttempts=1 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
  if [ "$user" = "root" ] && [ "$batch" -eq 0 ]; then
    base+=(-o BatchMode=yes -o NumberOfPasswordPrompts=0)
  fi
  if [ "$user" != "root" ] && [ "$batch" -eq 0 ]; then
    a2_ssh_password_command "${base[@]}" -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive -o NumberOfPasswordPrompts=1 "${args[@]}" "$dest" "$@"
  else
    command ssh -n "${base[@]}" "${args[@]}" "$dest" "$@"
  fi
}
a2_ssh_password() {
  local user="$1"
  local host="$2"
  shift 2
  local remote_cmd="${*:-true}"

  a2_ssh_password_command \
    -o ConnectTimeout="${A2_TIMEOUT:-6}" \
    -o ConnectionAttempts=1 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o PubkeyAuthentication=no \
    -o PreferredAuthentications=password,keyboard-interactive \
    -o NumberOfPasswordPrompts=1 \
    "${user}@${host}" "$remote_cmd"
}
a2_ssh_expect_allow() {
  local user="$1"
  local host="$2"
  shift 2
  local remote_cmd="${*:-echo SSH_OK:\$USER}"
  local out rc

  echo "SSH_ALLOW_TEST ${user}@${host}"
  out="$(a2_ssh_password "$user" "$host" "$remote_cmd" 2>&1)"
  rc=$?
  printf "%s\n" "$out"
  if [ "$rc" -eq 0 ]; then
    echo "SSH_ALLOW_OK ${user}@${host}"
    return 0
  fi
  echo "SSH_ALLOW_FAIL ${user}@${host} rc=$rc"
  return 1
}
a2_ssh_expect_deny() {
  local user="$1"
  local host="$2"
  shift 2
  local remote_cmd="${*:-echo SHOULD_NOT_LOGIN:\$USER}"
  local out rc

  echo "SSH_DENY_TEST ${user}@${host}"
  out="$(a2_ssh_password "$user" "$host" "$remote_cmd" 2>&1)"
  rc=$?
  printf "%s\n" "$out"
  if [ "$rc" -ne 0 ]; then
    echo "SSH_DENY_OK ${user}@${host} rc=$rc"
    return 0
  fi
  echo "SSH_DENY_FAIL ${user}@${host} login succeeded"
  return 1
}
a2_shell_quote() {
  printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}
a2_ssh_expect_deny_from() {
  local source_host="$1"
  local user="$2"
  local host="$3"
  shift 3
  local remote_cmd="${*:-echo SHOULD_NOT_LOGIN:\$USER}"
  local out rc

  echo "SSH_SOURCE_DENY_TEST ${user}@${host} from ${source_host}"
  out="$(
    {
      printf 'A2_USER_PASS=%s\n' "$(a2_shell_quote "${A2_USER_PASS:-Skill39@A2}")"
      printf 'A2_SSH_USER=%s\n' "$(a2_shell_quote "$user")"
      printf 'A2_SSH_HOST=%s\n' "$(a2_shell_quote "$host")"
      printf 'A2_SSH_COMMAND=%s\n' "$(a2_shell_quote "$remote_cmd")"
      cat <<'REMOTE_SSH_DENY_EOF'
set -o pipefail
base=(-o ConnectTimeout="${A2_TIMEOUT:-6}" -o ConnectionAttempts=1 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive -o NumberOfPasswordPrompts=1)
if command -v sshpass >/dev/null 2>&1; then
  sshpass -p "$A2_USER_PASS" ssh -n "${base[@]}" "${A2_SSH_USER}@${A2_SSH_HOST}" "$A2_SSH_COMMAND"
  exit $?
fi
askpass="$(mktemp)" || exit 127
cat > "$askpass" <<'ASKPASS_EOF'
#!/usr/bin/env sh
printf '%s\n' "$A2_USER_PASS"
ASKPASS_EOF
chmod 700 "$askpass"
if command -v setsid >/dev/null 2>&1; then
  SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-:0}" setsid -w ssh -n "${base[@]}" "${A2_SSH_USER}@${A2_SSH_HOST}" "$A2_SSH_COMMAND"
else
  SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-:0}" ssh -n "${base[@]}" "${A2_SSH_USER}@${A2_SSH_HOST}" "$A2_SSH_COMMAND"
fi
rc=$?
rm -f "$askpass"
exit "$rc"
REMOTE_SSH_DENY_EOF
    } | command ssh \
      -o ConnectTimeout="${A2_TIMEOUT:-6}" \
      -o ConnectionAttempts=1 \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -o BatchMode=yes \
      -o NumberOfPasswordPrompts=0 \
      "root@${source_host}" 'bash -s' 2>&1
  )"
  rc=$?
  printf "%s\n" "$out"
  if [ "$rc" -ne 0 ]; then
    echo "SSH_SOURCE_DENY_OK ${user}@${host} from ${source_host} rc=$rc"
    return 0
  fi
  echo "SSH_SOURCE_DENY_FAIL ${user}@${host} from ${source_host} login succeeded"
  return 1
}
a2_sudo_user_list() {
  local user="$1"
  local host="$2"
  local passq remote_cmd

  passq="$(a2_shell_quote "${A2_USER_PASS:-Skill39@A2}")"
  remote_cmd="A2_USER_PASS=$passq; printf '%s\n' \"\$A2_USER_PASS\" | sudo -S -p '' -l"
  a2_ssh_password "$user" "$host" "$remote_cmd"
}
a2_sudo_expect_full_access() {
  local user="$1"
  local host="$2"
  local out rc

  echo "SUDO_LIST_TEST FULL_SUDO ${user}@${host}"
  out="$(a2_sudo_user_list "$user" "$host" 2>&1)"
  rc=$?
  printf "%s\n" "$out"
  if [ "$rc" -eq 0 ] && printf "%s\n" "$out" | grep -Eq '\(ALL([[:space:]]*:[[:space:]]*ALL)?\)[[:space:]]+(NOPASSWD:[[:space:]]*)?ALL'; then
    echo "FULL_SUDO_OK ${user}@${host}"
    return 0
  fi
  echo "FULL_SUDO_FAIL ${user}@${host} rc=$rc"
  return 1
}
a2_sudo_expect_no_sudo() {
  local user="$1"
  local host="$2"
  local out rc

  echo "SUDO_DENY_TEST NO_SUDO ${user}@${host}"
  out="$(a2_sudo_user_list "$user" "$host" 2>&1)"
  rc=$?
  printf "%s\n" "$out"
  if [ "$rc" -ne 0 ] || printf "%s\n" "$out" | grep -Eiq 'not allowed|may not run|is not in the sudoers file|Permission denied'; then
    echo "SUDO_DENIED_OK ${user}@${host} rc=$rc"
    return 0
  fi
  if printf "%s\n" "$out" | grep -Eq 'may run|^[[:space:]]*\([^)]*\)[[:space:]]+'; then
    echo "SUDO_ALLOWED_BAD ${user}@${host}"
    return 1
  fi
  echo "SUDO_DENIED_OK ${user}@${host} rc=$rc"
  return 0
}
a2_sudo_expect_id_denied() {
  local user="$1"
  local host="$2"
  local out rc passq remote_cmd

  echo "SUDO_DENY_TEST ARBITRARY_SUDO ${user}@${host} sudo id"
  passq="$(a2_shell_quote "${A2_USER_PASS:-Skill39@A2}")"
  remote_cmd="A2_USER_PASS=$passq; idcmd=\$(command -v id); printf '%s\n' \"\$A2_USER_PASS\" | sudo -S -p '' -l \"\$idcmd\""
  out="$(a2_ssh_password "$user" "$host" "$remote_cmd" 2>&1)"
  rc=$?
  printf "%s\n" "$out"
  if [ "$rc" -ne 0 ]; then
    echo "ARBITRARY_SUDO_DENIED_OK ${user}@${host} rc=$rc"
    return 0
  fi
  echo "ARBITRARY_SUDO_ALLOWED_BAD ${user}@${host}"
  return 1
}
a2_sudo_expect_web_unit() {
  local user="$1"
  local host="$2"
  local action="$3"
  local ok_marker="$4"
  local fail_marker="$5"
  local svc out rc passq remote_cmd

  echo "SUDO_ALLOW_TEST ${ok_marker} ${user}@${host} systemctl ${action} nginx/apache2"
  passq="$(a2_shell_quote "${A2_USER_PASS:-Skill39@A2}")"
  for svc in nginx apache2; do
    remote_cmd="A2_USER_PASS=$passq; for systemctl_cmd in \$(command -v systemctl) /usr/bin/systemctl /bin/systemctl; do [ -n \"\$systemctl_cmd\" ] && [ -x \"\$systemctl_cmd\" ] || continue; printf '%s\n' \"\$A2_USER_PASS\" | sudo -S -p '' -l \"\$systemctl_cmd\" $action $svc && exit 0; done; exit 1"
    out="$(a2_ssh_password "$user" "$host" "$remote_cmd" 2>&1)"
    rc=$?
    printf "%s\n" "$out"
    if [ "$rc" -eq 0 ]; then
      echo "${ok_marker} ${user}@${host} systemctl ${action} ${svc}"
      return 0
    fi
  done
  echo "${fail_marker} ${user}@${host} systemctl ${action} nginx/apache2"
  return 1
}
a2_cert_pem_files() {
  find "${1:-/opt/grading/a2/pki}" -maxdepth 2 -type f -name '*.pem' 2>/dev/null | sort
}
a2_find_pem_by_subject_cn() {
  local cn="$1"
  local dir="${2:-/opt/grading/a2/pki}"
  local f subject
  while IFS= read -r f; do
    subject="$(openssl x509 -in "$f" -noout -subject 2>/dev/null)" || continue
    case "$subject" in
      *"CN = $cn"*|*"CN=$cn"*) printf '%s\n' "$f"; return 0 ;;
    esac
  done < <(a2_cert_pem_files "$dir")
  return 1
}
a2_find_pem_by_san_dns() {
  local dns="$1"
  local dir="${2:-/opt/grading/a2/pki}"
  local f san
  while IFS= read -r f; do
    san="$(openssl x509 -in "$f" -noout -ext subjectAltName 2>/dev/null)" || continue
    printf '%s\n' "$san" | grep -Fq "DNS:$dns" || continue
    printf '%s\n' "$f"
    return 0
  done < <(a2_cert_pem_files "$dir")
  return 1
}
export A2_PASS A2_USER_PASS A2_READER_PASS A2_BASE_DN A2_BIND_DN A2_READER_DN A2_TIMEOUT
EOS
  printf "\n%s\n" "$command" >> "$tmp"
  chmod 700 "$tmp"

  local output rc
  if command -v timeout >/dev/null 2>&1; then
    output="$(A2_PASS="$A2_PASS" A2_USER_PASS="$A2_USER_PASS" A2_READER_PASS="$A2_READER_PASS" A2_BASE_DN="$A2_BASE_DN" A2_BIND_DN="$A2_BIND_DN" A2_READER_DN="$A2_READER_DN" A2_TIMEOUT="$A2_TIMEOUT" timeout "$A2_CMD_TIMEOUT" bash "$tmp" </dev/null 2>&1)"
    rc=$?
  else
    output="$(A2_PASS="$A2_PASS" A2_USER_PASS="$A2_USER_PASS" A2_READER_PASS="$A2_READER_PASS" A2_BASE_DN="$A2_BASE_DN" A2_BIND_DN="$A2_BIND_DN" A2_READER_DN="$A2_READER_DN" A2_TIMEOUT="$A2_TIMEOUT" bash "$tmp" </dev/null 2>&1)"
    rc=$?
  fi
  rm -f "$tmp"
  A2_LAST_RC="$rc"
  A2_LAST_RAW_OUTPUT="$output"
}

has_bad_marker() {
  local out="$1"
  printf "%s\n" "$out" | grep -Eiq 'SHOULD_NOT|SHOULD_NOT_WORK|SHOULD_NOT_LOGIN|(^|[[:space:]:])BAD($|[[:space:]])'
}

filter_output_for_display() {
  local out="$1"
  local filtered line_count filtered_count
  local evidence_re
  evidence_re='OK|FAIL|BAD|DENIED|allowed|denied|refused|timed out|No route|Permission denied|error|invalid|not found|No such|packet loss|bytes from|Time zone|Locale|Keymap|default|10\.22\.|203\.0\.113\.|2001:db8:a2|east-|core-|ops-|repo-|auth-|portal-|atlas\.a2\.lab|SOA|CNAME|SRV|PTR|flags:|status:|:53|subject=|issuer=|CA:|DNS:|DNS_RECURSION|Verify return code|keyUsage|ROOT_CA_FILE|ROOT_CA_BASIC_CONSTRAINTS|ROOT_CA_KEY_USAGE|SERVICES_CA_FILE|LDAP_CERT_SOURCE|PORTAL_CERT_SOURCE|PEM_OK|PEM_BAD|A2_3_8|SSSD_|SYSTEM_CA|ROOTDSE_ANON|LDAP_USER_BIND|SSH_|PORTAL_ADMIN_|dn:|ou:|cn:|uid:|uidNumber:|gidNumber|memberUid|USER_GROUPS|namingContexts|userPassword|authzid|result:|slapd|bind9|named|sssd|ldap_|sudo|linuxadmins|operators|auditors|engineers|portalusers|nginx|apache|HTTP_CODE|A2_|/srv/repo/audit|acl|Accepted|Failed|sshd|/admin|DROP|Command:|Expected:|Actual:|Result:|incomplete='

  line_count="$(printf "%s\n" "$out" | wc -l | tr -d ' ')"
  filtered="$(printf "%s\n" "$out" | grep -Ei "$evidence_re" | sed -n '1,160p' || true)"

  if [ -n "$filtered" ]; then
    filtered_count="$(printf "%s\n" "$filtered" | wc -l | tr -d ' ')"
    printf "%s\n" "$filtered"
    if [ "$line_count" -gt "$filtered_count" ]; then
      printf "... вывод отфильтрован: показано %s релевантных строк из %s ...\n" "$filtered_count" "$line_count"
    fi
  else
    printf "%s\n" "$out" | sed -n '1,120p'
    if [ "$line_count" -gt 120 ]; then
      printf "... вывод обрезан: показаны первые 120 строк из %s ...\n" "$line_count"
    fi
  fi
}

evaluate_result() {
  local id="$1"
  local out="$2"
  local rc="$3"

  case "$id" in
    A2.1.1) contains_all "$out" OK-east-edge-a2 OK-east-ws-a2 OK-core-edge-a2 OK-ops-ws-a2 OK-repo-a2 OK-auth-a2 OK-portal-a2 ;;
    A2.1.2) contains_all "$out" 10.22.10.1 203.0.113.10 10.22.10.20 203.0.113.20 10.22.20.1 10.22.20.20 10.22.30.1 10.22.30.10 10.22.40.1 10.22.40.10 10.22.40.20 2001:db8:a2:10::1 2001:db8:a2:10::20 2001:db8:a2:20::1 2001:db8:a2:20::20 2001:db8:a2:30::1 2001:db8:a2:30::10 2001:db8:a2:40::1 2001:db8:a2:40::10 2001:db8:a2:40::20 ;;
    A2.1.3) contains_all "$out" 10.22.10.1 10.22.20.1 10.22.30.1 10.22.40.1 ;;
    A2.1.4) contains_all "$out" 10.22.20.0/24 10.22.30.0/24 10.22.40.0/24 10.22.10.0/24 203.0.113.20 203.0.113.10 ;;
    A2.1.5) contains_all "$out" 2001:db8:a2:10 2001:db8:a2:20 2001:db8:a2:30 2001:db8:a2:40 ;;
    A2.1.6) [ "$(count_regex "$out" 'net\.ipv4\.ip_forward *= *1')" -ge 2 ] ;;
    A2.1.7) [ "$(count_regex "$out" 'net\.ipv6\.conf\.all\.forwarding *= *1')" -ge 2 ] ;;
    A2.1.8) [ "$rc" -eq 0 ] && contains_all "$out" "TCP_OK SH_to_auth_ldap_v4" "TCP_OK SH_to_portal_https_v4" "TCP_OK SH_to_dns_tcp_v4" "TCP_OK SZ_to_east_ssh_v4" ;;
    A2.1.9) [ "$rc" -eq 0 ] && contains_all "$out" "TCP_OK SH_to_auth_ldap_v6" "TCP_OK SH_to_portal_https_v6" "TCP_OK SZ_to_east_ssh_v6" ;;
    A2.1.10) printf "%s\n" "$out" | grep -Fq "10.22.10.20" ;;
    A2.1.11) contains_all "$out" Europe/Paris en_US.UTF-8 && contains_regex_any "$out" 'VC Keymap: *us|X11 Layout: *us|Keymap: *us' ;;
    A2.1.12) [ "$(count_regex "$out" 'ROOT_SSH_OK')" -ge 7 ] ;;
    A2.2.1) contains_all "$out" ":53" "atlas.a2.lab" && contains_regex_any "$out" 'SOA|AUTHORITY|flags:.*aa' ;;
    A2.2.2) contains_all "$out" 10.22.10.1 10.22.10.20 10.22.20.1 10.22.20.20 10.22.30.10 10.22.40.10 10.22.40.20 2001:db8:a2 ;;
    A2.2.3) contains_all "$out" 10.22.10.1 203.0.113.10 203.0.113.20 10.22.20.1 10.22.30.1 10.22.40.1 ;;
    A2.2.4) contains_all "$out" auth-a2 portal-a2 repo-a2 ;;
    A2.2.5) contains_all "$out" 389 auth-a2 ;;
    A2.2.6) [ "$(count_regex "$out" 'atlas\.a2\.lab')" -ge 8 ] ;;
    A2.2.7) contains_all "$out" portal.atlas.a2.lab ldap.atlas.a2.lab && contains_regex_any "$out" '10\.22\.40\.10|auth-a2|dns' ;;
    A2.2.8) contains_all "$out" "DNS_RECURSION_OK SH-LAN" "DNS_RECURSION_OK SZ-CLIENT" && ! contains_any "$out" "DNS_RECURSION_FAIL" ;;
    A2.2.9) ! contains_regex_any "$out" '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' ;;
    A2.2.10) contains_regex_all "$out" 'enabled' 'active' ;;
    A2.2.11) contains_all "$out" 10.22.10.1 203.0.113.10 203.0.113.20 10.22.20.1 10.22.30.1 10.22.40.1 ;;
    A2.3.1) contains_all "$out" "Atlas A2 Root CA" "ROOT_CA_BASIC_CONSTRAINTS_OK" ;;
    A2.3.2) contains_all "$out" "Atlas A2 Services CA" "OK" "CA:TRUE" ;;
    A2.3.3) [ "$rc" -eq 0 ] && contains_regex_all "$out" 'ROOT_CA_FILE=/.*' 'SERVICES_CA_FILE=/.*' 'PEM_OK ' && ! contains_any "$out" "NOT_FOUND" "PEM_BAD" ;;
    A2.3.4) contains_all "$out" "DNS:auth-a2.atlas.a2.lab" "DNS:ldap.atlas.a2.lab" "DNS:ca.atlas.a2.lab" ;;
    A2.3.5) contains_all "$out" "DNS:portal-a2.atlas.a2.lab" "DNS:portal.atlas.a2.lab" ;;
    A2.3.6) contains_all "$out" "dn:" "Verify return code: 0" ;;
    A2.3.7) contains_all "$out" "dn:" ;;
    A2.3.8) [ "$(count_regex "$out" 'SSSD_STARTTLS_OK')" -ge 4 ] && [ "$(count_regex "$out" 'SSSD_REQCERT_OK')" -ge 4 ] && [ "$(count_regex "$out" 'SSSD_CACERT_FILE_OK')" -ge 4 ] && [ "$(count_regex "$out" 'SYSTEM_CA_OK')" -ge 4 ] && ! contains_regex_any "$out" 'SSSD_.*MISSING|SYSTEM_CA_MISSING' ;;
    A2.3.9) [ "$(count_regex "$out" 'HTTPS_OK')" -ge 2 ] ;;
    A2.3.10) [ -n "$out" ] && ! contains_regex_any "$out" '^-...r..r..|^-......r..' ;;
    A2.3.11) [ "$rc" -eq 0 ] && contains_regex_all "$out" 'ROOT_CA_FILE=/.*' 'SERVICES_CA_FILE=/.*' 'LDAP_CERT_SOURCE=' 'PORTAL_CERT_SOURCE=' && [ "$(count_regex "$out" ': OK|OK$')" -ge 2 ] ;;
    A2.3.12) contains_all "$out" "dn:" "A2_PORTAL_OK" ;;
    A2.4.1) contains_all "$out" "dn: dc=atlas,dc=a2,dc=lab" ;;
    A2.4.2) contains_all "$out" "ou: People" "ou: Groups" "ou: ServiceAccounts" ;;
    A2.4.3) contains_all "$out" "cn: linuxadmins" "gidNumber: 7200" "cn: operators" "gidNumber: 7210" "cn: auditors" "gidNumber: 7220" "cn: engineers" "gidNumber: 7230" "cn: portalusers" "gidNumber: 7240" ;;
    A2.4.4) contains_all "$out" "uid: li" "uidNumber: 8301" "uid: bekzat" "uidNumber: 8302" "uid: mei" "uidNumber: 8303" "uid: aliya" "uidNumber: 8304" ;;
    A2.4.5) contains_regex_all "$out" 'USER_GROUPS li: .*linuxadmins' 'USER_GROUPS li: .*portalusers' 'USER_GROUPS bekzat: .*operators' 'USER_GROUPS bekzat: .*portalusers' 'USER_GROUPS mei: .*auditors' 'USER_GROUPS aliya: .*engineers' ;;
    A2.4.6) contains_all "$out" "dn:uid=ldap-reader" ;;
    A2.4.7) contains_regex_any "$out" 'insufficient|denied|not allowed|modification failed|Result: 50' ;;
    A2.4.8) contains_all "$out" "ROOTDSE_ANON_OK" namingContexts ;;
    A2.4.9) ! contains_regex_any "$out" 'uid: (li|bekzat|mei|aliya)' ;;
    A2.4.10) ! contains_all "$out" "userPassword:" ;;
    A2.4.11) contains_all "$out" "dn:" ;;
    A2.4.12) [ "$(count_regex "$out" 'LDAP_USER_BIND_OK')" -ge 4 ] && ! contains_regex_any "$out" 'LDAP_USER_BIND_(INVALID_CREDENTIALS|FAIL)' ;;
    A2.4.13) contains_all "$out" posixAccount posixGroup uidNumber gidNumber ;;
    A2.4.14) contains_all "$out" enabled active ;;
    A2.5.1) [ "$(count_regex "$out" 'enabled')" -ge 6 ] && [ "$(count_regex "$out" 'active')" -ge 6 ] ;;
    A2.5.2) contains_all "$out" ldap_uri ldap_id_use_start_tls ldap_tls_reqcert ldap_tls_cacert ldap_default_bind_dn ;;
    A2.5.3) ! contains_regex_any "$out" 'tls_reqcert *= *(never|allow)' && contains_regex_any "$out" '^600 | 600 root:root|^640 ' ;;
    A2.5.4) [ "$(count_regex "$out" 'li:|bekzat:|mei:|aliya:')" -ge 20 ] ;;
    A2.5.5) contains_all "$out" linuxadmins operators auditors engineers portalusers ;;
    A2.5.6) [ "$(count_regex "$out" 'HOME_OK')" -ge 2 ] && ! contains_regex_any "$out" 'SSH_ALLOW_FAIL|SSH_PASSWORD_HELPER_MISSING' ;;
    A2.5.7) [ "$(count_regex "$out" 'SSH_ALLOW_OK')" -ge 3 ] && ! contains_regex_any "$out" 'SSH_ALLOW_FAIL|SSH_PASSWORD_HELPER_MISSING' ;;
    A2.5.8) [ "$(count_regex "$out" 'SSH_DENY_OK')" -ge 1 ] && ! contains_regex_any "$out" 'SSH_DENY_FAIL|SSH_PASSWORD_HELPER_MISSING' && ! has_bad_marker "$out" ;;
    A2.5.9) [ "$(count_regex "$out" 'SSH_ALLOW_OK')" -ge 2 ] && [ "$(count_regex "$out" 'SSH_DENY_OK')" -ge 2 ] && ! contains_regex_any "$out" 'SSH_(ALLOW|DENY)_FAIL|SSH_PASSWORD_HELPER_MISSING' && ! has_bad_marker "$out" ;;
    A2.5.10) [ "$(count_regex "$out" 'SSH_ALLOW_OK')" -ge 2 ] && [ "$(count_regex "$out" 'SSH_DENY_OK')" -ge 2 ] && ! contains_regex_any "$out" 'SSH_(ALLOW|DENY)_FAIL|SSH_PASSWORD_HELPER_MISSING' && ! has_bad_marker "$out" ;;
    A2.5.11) [ "$(count_regex "$out" 'SSH_ALLOW_OK')" -ge 2 ] && [ "$(count_regex "$out" 'SSH_DENY_OK')" -ge 2 ] && ! contains_regex_any "$out" 'SSH_(ALLOW|DENY)_FAIL|SSH_PASSWORD_HELPER_MISSING' && ! has_bad_marker "$out" ;;
    A2.5.12) [ "$(count_regex "$out" 'GW_OK')" -ge 2 ] && ! contains_regex_any "$out" 'SSH_ALLOW_FAIL|SSH_PASSWORD_HELPER_MISSING' ;;
    A2.5.13) [ "$(count_regex "$out" 'SSH_DENY_OK')" -ge 3 ] && contains_all "$out" SSH_SOURCE_DENY_OK && ! contains_regex_any "$out" 'SSH_DENY_FAIL|SSH_SOURCE_DENY_FAIL|SSH_PASSWORD_HELPER_MISSING' && ! has_bad_marker "$out" ;;
    A2.5.14) [ "$(count_regex "$out" 'ROOT_OK')" -ge 7 ] ;;
    A2.5.15) [ "$(count_regex "$out" 'active')" -ge 10 ] ;;
    A2.5.16) contains_all "$out" li bekzat ;;
    A2.6.1) [ "$(count_regex "$out" 'FULL_SUDO_OK')" -ge 6 ] && ! contains_regex_any "$out" 'FULL_SUDO_FAIL|SSH_PASSWORD_HELPER_MISSING' ;;
    A2.6.2) [ "$(count_regex "$out" 'linuxadmins')" -ge 6 ] ;;
    A2.6.3) contains_all "$out" STATUS_ALLOWED && ! contains_regex_any "$out" 'STATUS_DENIED|SSH_ALLOW_FAIL|SSH_PASSWORD_HELPER_MISSING' ;;
    A2.6.4) contains_all "$out" RESTART_ALLOWED && ! contains_regex_any "$out" 'RESTART_DENIED|SSH_ALLOW_FAIL|SSH_PASSWORD_HELPER_MISSING' ;;
    A2.6.5) contains_all "$out" ARBITRARY_SUDO_DENIED_OK && [ "$(count_regex "$out" 'SUDO_DENIED_OK')" -ge 5 ] && ! contains_regex_any "$out" 'ARBITRARY_SUDO_ALLOWED_BAD|SUDO_ALLOWED_BAD|SSH_PASSWORD_HELPER_MISSING' ;;
    A2.6.6) [ "$(count_regex "$out" 'SUDO_DENIED_OK')" -ge 2 ] && ! contains_regex_any "$out" 'SUDO_ALLOWED_BAD|SSH_PASSWORD_HELPER_MISSING' ;;
    A2.6.7) contains_all "$out" SUDO_DENIED_OK && ! contains_regex_any "$out" 'SUDO_ALLOWED_BAD|SSH_PASSWORD_HELPER_MISSING' ;;
    A2.6.8) [ "$rc" -eq 0 ] && ! contains_regex_any "$out" 'parse error|syntax error' ;;
    A2.6.9) contains_regex_any "$out" 'sudo.*li|sudo.*bekzat' && ! contains_regex_any "$out" 'SSH_ALLOW_FAIL|SSH_PASSWORD_HELPER_MISSING' ;;
    A2.7.1) [ "$(count_regex "$out" '^A2_PORTAL_OK$')" -ge 2 ] ;;
    A2.7.2) contains_all "$out" A2_ADMIN_OK PORTAL_ADMIN_ALLOWED_OK && ! contains_regex_any "$out" 'PORTAL_ADMIN_ALLOWED_FAIL' ;;
    A2.7.3) contains_all "$out" PORTAL_ADMIN_DENIED_OK && ! contains_regex_any "$out" 'A2_ADMIN_OK|PORTAL_ADMIN_DENIED_FAIL' ;;
    A2.7.4) ! contains_all "$out" A2_PORTAL_OK ;;
    A2.7.5) contains_all "$out" /srv/repo/audit && contains_regex_any "$out" 'li|linuxadmins|mei|auditors|acl' ;;
    A2.7.6) contains_all "$out" LI_RW_OK && ! contains_regex_any "$out" 'SSH_ALLOW_FAIL|SSH_PASSWORD_HELPER_MISSING' ;;
    A2.7.7) contains_all "$out" MEI_READ_OK MEI_WRITE_DENIED_OK && ! contains_regex_any "$out" 'SSH_ALLOW_FAIL|SSH_PASSWORD_HELPER_MISSING' ;;
    A2.7.8) [ "$(count_regex "$out" 'SSH_DENY_OK')" -ge 2 ] && ! contains_regex_any "$out" 'SSH_DENY_FAIL|SSH_PASSWORD_HELPER_MISSING' ;;
    A2.8.1) contains_all "$out" east-edge-a2 core-edge-a2 east-ws-a2 ops-ws-a2 repo-a2 portal-a2 ;;
    A2.8.2) contains_regex_any "$out" '/var/log/remote|logs-proof' ;;
    A2.8.3) contains_all "$out" "SSH_LOG_SUCCESS_OK li" "SSH_LOG_DENY_OK aliya" && ! contains_regex_any "$out" 'SSH_(ALLOW|DENY)_FAIL|SSH_LOG_.*MISSING|SSH_PASSWORD_HELPER_MISSING' ;;
    A2.8.4) contains_regex_any "$out" 'sudo.*li|sudo.*bekzat' && ! contains_regex_any "$out" 'SSH_ALLOW_FAIL|SSH_PASSWORD_HELPER_MISSING' ;;
    A2.8.5) contains_all "$out" /admin ;;
    A2.8.6) contains_all "$out" GATEWAY_DENY_OK && ! contains_all "$out" GATEWAY_DENY_FAIL ;;
    A2.8.7) contains_regex_all "$out" 'Command:|Expected:|Actual:|Result:' 'PASS|FAIL' ;;
    A2.8.8) contains_regex_all "$out" 'SSH|PAM|sudo' 'allowed|denied|positive|negative|PASS|FAIL' ;;
    A2.8.9) contains_regex_all "$out" 'ROOT_CA_FILE=/.*' 'SERVICES_CA_FILE=/.*' 'PEM_OK ' && ! contains_any "$out" "NOT_FOUND" "PEM_BAD" ;;
    A2.8.10) contains_all "$out" incomplete= ;;
    A2.8.11) [ "$rc" -eq 0 ] && contains_all "$out" ldap.atlas.a2.lab portal.atlas.a2.lab A2_PORTAL_OK FULL_SUDO_OK ;;
    *)
      [ "$rc" -eq 0 ] && [ -n "$out" ] && ! has_bad_marker "$out"
      ;;
  esac
}

run_criterion() {
  local id="$1" subsection="$2" desc="$3" mark="$4" command_escaped="$5"
  local command output display_output rc
  command="$(decode_field "$command_escaped")"
  command="$(prepare_command "$command")"

  step "$id" "$desc"
  cmd_show "$command"
  run_eval_command "$command"
  output="$A2_LAST_RAW_OUTPUT"
  rc="$A2_LAST_RC"
  display_output="$(filter_output_for_display "$output")"
  show_output "$display_output"$'\n'"ExitCode=$rc"

  if evaluate_result "$id" "$output" "$rc"; then
    pass "$id" "$mark" "вывод команд соответствует ожидаемому результату"
  else
    fail "$id" "$mark" "вывод команд не соответствует ожидаемому результату"
  fi
}

run_all_criteria() {
  local last_subsection=""
  local id subsection desc mark runfrom commands expected notes
  while IFS=$'\t' read -r -u 3 id subsection desc mark runfrom commands expected notes; do
    [ "$id" = "CriterionID" ] && continue
    [ -n "$id" ] || continue
    should_run_criterion "$id" || continue
    if [ "$id" = "A2.8.11" ] && [ "$RUN_POST_REBOOT" != "1" ]; then
      step "$id" "$desc"
      skip "$id" "$mark" "проверка после reboot не запущена; используйте --post-reboot после согласованной перезагрузки"
      continue
    fi
    if [ "$subsection" != "$last_subsection" ]; then
      case "$subsection" in
        A2.1) section "A2.1 - Базовая топология и маршрутизация" ;;
        A2.2) section "A2.2 - DNS" ;;
        A2.3) section "A2.3 - PKI и доверие StartTLS" ;;
        A2.4) section "A2.4 - LDAP-каталог" ;;
        A2.5) section "A2.5 - SSSD, PAM и SSH-политики" ;;
        A2.6) section "A2.6 - sudo-политики" ;;
        A2.7) section "A2.7 - доступ к portal и repo" ;;
        A2.8) section "A2.8 - центральные логи и подтверждения" ;;
        *) section "$subsection" ;;
      esac
      last_subsection="$subsection"
    fi
    run_criterion "$id" "$subsection" "$desc" "$mark" "$commands"
  done 3< "$A2_CRITERIA_MAP"
}

main() {
  validate_start_from
  init_remote_report_files

  echo -e "${CYAN}Удаленный проверочный скрипт A2 Shanghai-Shenzhen${NC}"
  echo "Рекомендуемый хост запуска: ops-ws-a2. Каталог отчетов: $A2_REPORT_DIR"
  echo "Запуск: $(date -Is)" | tee -a "$A2_DETAIL_LOG"
  if [ "$A2_RESUME_MODE" = "1" ]; then
    echo "Начальный критерий: $A2_START_FROM" | tee -a "$A2_DETAIL_LOG"
  fi

  if [ "$A2_START_FROM" = "A2.1.1" ]; then
    check_ssh_all
  else
    echo -e "${CYAN}Предварительная SSH-проверка пропущена - продолжение начинается с $A2_START_FROM${NC}" | tee -a "$A2_DETAIL_LOG"
  fi

  run_all_criteria
  write_summary
  echo -e "${CYAN}Удаленная проверка завершена. Отчеты: $A2_REPORT_DIR${NC}"
}

main "$@"
