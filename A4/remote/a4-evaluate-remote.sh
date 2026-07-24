#!/usr/bin/env bash
# A4 remote evaluator. Recommended launch point: maint-a4 (10.44.20.20).

set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/a4-common.sh"

A4_HOSTS_FILE="${A4_HOSTS_FILE:-$SCRIPT_DIR/a4-hosts.conf}"
A4_START_FROM="${A4_START_FROM:-A4.1.1}"
A4_POST_REBOOT="${A4_POST_REBOOT:-0}"
A4_LAST_RC=0
A4_LAST_OUT=""

usage() {
  cat <<'EOF'
Usage: sudo bash remote/a4-evaluate-remote.sh [options]
  --no-pause              do not pause after each aspect
  --pause                 pause after each aspect (default)
  --start-from A4.4.6     resume from an aspect
  --report-dir DIR        report output directory
  --post-reboot           include restart/persistence checks
  --hosts-file FILE       override host map
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --no-pause) A4_PAUSE=0 ;;
    --pause) A4_PAUSE=1 ;;
    --post-reboot) A4_POST_REBOOT=1 ;;
    --start-from) shift; A4_START_FROM="${1:?missing --start-from value}" ;;
    --report-dir) shift; A4_REPORT_DIR="${1:?missing --report-dir value}" ;;
    --hosts-file) shift; A4_HOSTS_FILE="${1:?missing --hosts-file value}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

A4_RESULTS_TSV="$A4_REPORT_DIR/a4-results.tsv"
A4_DETAIL_LOG="$A4_REPORT_DIR/a4-detail.log"
mkdir -p "$A4_REPORT_DIR"
printf 'CriterionID\tMaxMark\tStatus\tMessage\n' > "$A4_RESULTS_TSV"
: > "$A4_DETAIL_LOG"

PERSISTENCE_IDS=' A4.2.13 A4.3.19 A4.4.14 A4.6.14 A4.7.14 '

manual_commands_for() {
  printf '%s\n' "$2"
}

ssh_precheck() {
  section "Предварительная проверка root SSH с maint-a4"
  local name ip out
  while IFS='=' read -r name ip; do
    [[ "$name" =~ ^[[:space:]]*# ]] && continue
    [ -n "$name" ] || continue
    printf '%-18s %-15s ' "$name" "$ip"
    out="$(timeout "$A4_TIMEOUT" /usr/bin/ssh -o BatchMode=yes \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -o ConnectTimeout="$A4_TIMEOUT" \
      root@"$ip" 'hostname -s' 2>&1)"
    if [ "$out" = "$name" ]; then echo -e "${GREEN}OK${NC}"
    else echo -e "${YELLOW}NO ACCESS${NC}: $out"; fi
  done < "$A4_HOSTS_FILE"
}

run_command() {
  local criterion="$1" command="$2" tmp out_file
  tmp="$(mktemp)"; out_file="$(mktemp)"
  {
    cat <<EOF
#!/usr/bin/env bash
set -o pipefail
ssh() {
  command timeout "${A4_TIMEOUT}s" /usr/bin/ssh \
    -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o ConnectTimeout="${A4_TIMEOUT}" -o ConnectionAttempts=1 \
    -o ServerAliveInterval=2 -o ServerAliveCountMax=2 \
    -o GSSAPIAuthentication=no "\$@"
}
EOF
    printf '%s\n' "$command"
  } > "$tmp"
  chmod 700 "$tmp"
  echo -e "${BLUE}Полный фактический вывод (stdout/stderr):${NC}"
  timeout "$A4_CMD_TIMEOUT" bash "$tmp" </dev/null 2>&1 |
    tee -a "$A4_DETAIL_LOG" "$out_file"
  A4_LAST_RC="${PIPESTATUS[0]}"
  A4_LAST_OUT="$(cat "$out_file")"
  [ -s "$out_file" ] || echo "(пустой вывод)"
  rm -f "$tmp" "$out_file"
}

all() { local text="$1" value; shift; for value in "$@"; do grep -Fqi "$value" <<<"$text" || return 1; done; }
any_re() { grep -Eiq "$2" <<<"$1"; }
none_re() { ! grep -Eiq "$2" <<<"$1"; }
count_re() { grep -Eic "$2" <<<"$1" || true; }
ok_basic() {
  [ "$2" -eq 0 ] && [ -n "$(tr -d '[:space:]' <<<"$1")" ] &&
    none_re "$1" 'Permission denied|command not found|No such file or directory|syntax error|Connection timed out'
}

evaluate_result() {
  local id="$1" o="$2" rc="$3"
  case "$id" in
    A4.1.1) all "$o" sh-router-a4 sh-operator-a4 sz-router-a4 maint-a4 storage-a4 log-a4 svc-a4 ;;
    A4.1.2) all "$o" 10.44.10.1/24 198.51.101.10/24 10.44.10.20/24 198.51.101.20/24 10.44.20.1/24 10.44.30.1/24 10.44.40.1/24 10.44.20.20/24 10.44.30.10/24 10.44.40.10/24 10.44.40.20/24 ;;
    A4.1.3) all "$o" 2001:db8:a4:10::1/64 2001:db8:a4:100::10/64 2001:db8:a4:10::20/64 2001:db8:a4:100::20/64 2001:db8:a4:20::1/64 2001:db8:a4:30::1/64 2001:db8:a4:40::1/64 2001:db8:a4:20::20/64 2001:db8:a4:30::10/64 2001:db8:a4:40::10/64 2001:db8:a4:40::20/64 ;;
    A4.1.4) all "$o" 10.44.10.1 10.44.20.1 10.44.30.1 10.44.40.1 2001:db8:a4:10::1 2001:db8:a4:20::1 2001:db8:a4:30::1 2001:db8:a4:40::1 ;;
    A4.1.5) all "$o" 10.44.20.0/24 10.44.30.0/24 10.44.40.0/24 198.51.101.20 10.44.10.0/24 198.51.101.10 ;;
    A4.1.6) all "$o" 2001:db8:a4:20::/64 2001:db8:a4:30::/64 2001:db8:a4:40::/64 2001:db8:a4:100::20 2001:db8:a4:10::/64 2001:db8:a4:100::10 ;;
    A4.1.7) [ "$(count_re "$o" 'net.ipv4.ip_forward[[:space:]]*=[[:space:]]*1')" -ge 4 ] ;;
    A4.1.8) [ "$(count_re "$o" 'net.ipv6.conf.all.forwarding[[:space:]]*=[[:space:]]*1')" -ge 4 ] ;;
    A4.1.9|A4.1.10|A4.7.12) [ "$rc" -eq 0 ] && [ "$(count_re "$o" '0% packet loss')" -ge 3 ] ;;
    A4.1.11|A4.7.13) none_re "$o" 'masquerade|snat' ;;
    A4.1.12) any_re "$o" 'SOA' && any_re "$o" 'NS' && none_re "$o" 'SERVFAIL|REFUSED' ;;
    A4.1.13) all "$o" 10.44.10.1 10.44.10.20 10.44.20.1 10.44.20.20 10.44.30.10 10.44.40.10 10.44.40.20 ;;
    A4.1.14) all "$o" 2001:db8:a4:10::1 2001:db8:a4:10::20 2001:db8:a4:20::1 2001:db8:a4:20::20 2001:db8:a4:30::10 2001:db8:a4:40::10 2001:db8:a4:40::20 ;;
    A4.1.15) all "$o" 198.51.101.10 198.51.101.20 10.44.20.1 10.44.30.1 10.44.40.1 2001:db8:a4:100::10 2001:db8:a4:100::20 2001:db8:a4:20::1 2001:db8:a4:30::1 2001:db8:a4:40::1 ;;
    A4.1.16) [ "$(count_re "$o" 'log-a4.cedar.a4.local.')" -ge 2 ] && [ "$(count_re "$o" 'storage-a4.cedar.a4.local.')" -ge 3 ] && any_re "$o" 'svc-a4.cedar.a4.local.' ;;
    A4.1.17) [ "$(count_re "$o" 'cedar.a4.local.')" -ge 11 ] ;;
    A4.1.18) any_re "$o" 'REFUSED|timed out|no servers could be reached' ;;
    A4.1.19) [ "$(count_re "$o" '10.44.40.10|127.0.0.1')" -ge 7 ] ;;

    A4.2.1) all "$o" sdb sdc vg_a4_storage && [ "$(count_re "$o" '1[2-9](\.[0-9]+)?G')" -ge 2 ] ;;
    A4.2.2) all "$o" vg_a4_storage && any_re "$o" '(^|[[:space:]])2([[:space:]]|$)' ;;
    A4.2.3) all "$o" lv_projects vg_a4_storage && any_re "$o" '8(\.0+)?g' ;;
    A4.2.4) all "$o" lv_backups vg_a4_storage && any_re "$o" '8(\.0+)?g' ;;
    A4.2.5) all "$o" lv_archive vg_a4_storage && any_re "$o" '2(\.0+)?g' ;;
    A4.2.6) [ "$(count_re "$o" 'TYPE="(ext4|xfs)"')" -ge 3 ] ;;
    A4.2.7) all "$o" /srv/projects /srv/backups /srv/archive lv_projects lv_backups lv_archive ;;
    A4.2.8) [ "$(count_re "$o" '^(UUID|LABEL)=.*[[:space:]]+/srv/(projects|backups|archive)')" -ge 3 ] ;;
    A4.2.9) all "$o" A4_NFS_OK A4_BACKUP_TARGET keep-ok ;;
    A4.2.10) awk 'BEGIN{ok=0} $1+0>=1{ok=1} END{exit !ok}' <<<"$o" ;;
    A4.2.11) all "$o" /dev/sdb /dev/sdc vg_a4_storage && none_re "$o" '/dev/sda.*vg_a4_storage' ;;
    A4.2.12) all "$o" vg_a4_storage lsblk pvs vgs lvs findmnt ;;
    A4.2.13) [ "$rc" -eq 0 ] && all "$o" /srv/projects /srv/backups /srv/archive ;;

    A4.3.1) all "$o" projectops 7440 auditors 7450 ;;
    A4.3.2) all "$o" olga 8441 projectops ;;
    A4.3.3) all "$o" danil 8442 auditors ;;
    A4.3.4) all "$o" backupsvc 8490 ;;
    A4.3.5) all "$o" user::rwx group::rwx group:projectops:rwx group:auditors:r-x other::--- default: ;;
    A4.3.6) [ "$rc" -eq 0 ] && any_re "$o" 'olga|A4_NFS_OK' ;;
    A4.3.7) [ "$rc" -ne 0 ] || any_re "$o" 'Permission denied|FAIL|Read-only' ;;
    A4.3.8) any_re "$o" '/srv/projects.*10.44.10.0/24' && any_re "$o" '/srv/projects.*10.44.20.0/24' && any_re "$o" 'root_squash' ;;
    A4.3.9) any_re "$o" ':2049' && none_re "$o" ':111|mountd' ;;
    A4.3.10|A4.3.11) all "$o" /mnt/a4-projects storage-a4 ;;
    A4.3.12) [ "$rc" -eq 0 ] && all "$o" A4_NFS_OK olga ;;
    A4.3.13) [ "$rc" -ne 0 ] || any_re "$o" 'Permission denied|Read-only' ;;
    A4.3.14) all "$o" projects /srv/projects/team && any_re "$o" 'guest ok[[:space:]]*=[[:space:]]*no' ;;
    A4.3.15) all "$o" olga danil ;;
    A4.3.16) [ "$rc" -eq 0 ] && any_re "$o" 'olga-smb-ok' ;;
    A4.3.17) [ "$rc" -ne 0 ] || any_re "$o" 'NT_STATUS_ACCESS_DENIED|Permission denied' ;;
    A4.3.18) [ "$rc" -eq 0 ] && any_re "$o" 'projects' ;;
    A4.3.19) [ "$rc" -eq 0 ] && all "$o" /mnt/a4-projects A4_NFS_OK ;;

    A4.4.1) all "$o" APP_NAME=cedar-a4 BACKUP_REQUIRED=yes VERSION=1 A4_CRITICAL_DATA ;;
    A4.4.2) all "$o" a4-backup-svc.sh 'backupsvc@' /srv/backups/svc-a4 manifest.sha256 ;;
    A4.4.3) [ "$rc" -eq 0 ] && all "$o" ssh-ok backupsvc ;;
    A4.4.4) [ "$rc" -eq 0 ] && any_re "$o" 'backupsvc' ;;
    A4.4.5) [ "$rc" -eq 0 ] && all "$o" config data etc manifest.sha256 ;;
    A4.4.6) all "$o" srv/a4-service/config srv/a4-service/data etc/fstab etc/rsyslog.conf etc/rsyslog.d ;;
    A4.4.7) [ "$rc" -eq 0 ] && any_re "$o" ': OK' ;;
    A4.4.8) any_re "$o" 'latest.*svc-a4/[0-9]{8}-[0-9]{6}' ;;
    A4.4.9|A4.6.11) any_re "$o" 'backup.log' ;;
    A4.4.10) any_re "$o" 'A4_BACKUP_OK' ;;
    A4.4.11) all "$o" a4-backup.service ExecStart ;;
    A4.4.12) all "$o" a4-backup.timer enabled active ;;
    A4.4.13) any_re "$o" '15min|hourly|OnCalendar|OnUnitActiveSec' ;;
    A4.4.14) [ "$rc" -eq 0 ] && any_re "$o" 'success|inactive \(dead\)|exited' ;;

    A4.5.1) all "$o" a4-restore-svc.sh critical.txt latest ;;
    A4.5.2) any_re "$o" 'A4_CRITICAL_DATA' ;;
    A4.5.3) [ "$rc" -eq 0 ] && any_re "$o" 'OK|match' ;;
    A4.5.4) [ "$rc" -eq 0 ] && any_re "$o" 'deleted|moved|restore' ;;
    A4.5.5) any_re "$o" 'A4_RESTORE_OK' ;;
    A4.5.6) all "$o" restore commands checksum PASS ;;
    A4.5.7) all "$o" A4_BACKUP_OK A4_RESTORE_OK ;;
    A4.5.8) [ "$rc" -eq 0 ] && all "$o" A4_CRITICAL_DATA manifest.sha256 ;;

    A4.6.1) any_re "$o" 'active' && any_re "$o" ':514.*LISTEN|LISTEN.*:514' ;;
    A4.6.2) [ "$(count_re "$o" '@@10.44.40.10|omfwd.*10.44.40.10')" -ge 4 ] ;;
    A4.6.3) [ "$rc" -eq 0 ] && any_re "$o" 'A4_SYSLOG_TEST' ;;
    A4.6.4) all "$o" A4-SH-DROP A4-SZ-DROP ;;
    A4.6.5) any_re "$o" '/var/log/remote|%HOSTNAME%' ;;
    A4.6.6) all "$o" sh-router-a4.log sz-router-a4.log svc-a4.log storage-a4.log ;;
    A4.6.7) any_re "$o" 'A4_BACKUP_OK' ;;
    A4.6.8) any_re "$o" 'A4_RESTORE_OK' ;;
    A4.6.9) any_re "$o" 'A4-SH-DROP' ;;
    A4.6.10) any_re "$o" 'A4-SZ-DROP' ;;
    A4.6.12) all "$o" /var/log/a4-service rotate 4 compress missingok notifempty create ;;
    A4.6.13) all "$o" /var/log/remote rotate 4 compress missingok notifempty ;;
    A4.6.14) [ "$rc" -eq 0 ] && [ "$(count_re "$o" 'A4_SYSLOG_RESTART_TEST')" -ge 4 ] ;;

    A4.7.1) [ "$(count_re "$o" 'enabled')" -ge 2 ] && [ "$(count_re "$o" 'active')" -ge 2 ] && any_re "$o" 'table' ;;
    A4.7.2) [ "$(count_re "$o" 'hook forward')" -ge 2 ] ;;
    A4.7.3) [ "$rc" -eq 0 ] && all "$o" 10.44.30.10 10.44.40.20 ;;
    A4.7.4) [ "$rc" -eq 0 ] && [ "$(count_re "$o" 'succeeded|open')" -ge 2 ] ;;
    A4.7.5) any_re "$o" 'succeeded|open' && any_re "$o" 'failed|refused|timed out' ;;
    A4.7.6) all "$o" A4-SH-DROP && any_re "$o" 'failed|refused|timed out' ;;
    A4.7.7) [ "$rc" -eq 0 ] && all "$o" ssh-ok succeeded ;;
    A4.7.8) [ "$rc" -eq 0 ] && [ "$(count_re "$o" 'sh-router-a4|sh-operator-a4|sz-router-a4|storage-a4|log-a4|svc-a4')" -ge 6 ] ;;
    A4.7.9) [ "$(count_re "$o" 'succeeded|open')" -ge 4 ] ;;
    A4.7.10) none_re "$o" 'succeeded|open|status: NOERROR' ;;
    A4.7.11) any_re "$o" 'A4-SZ-DROP' ;;
    A4.7.14) [ "$rc" -eq 0 ] && all "$o" A4-SH-DROP A4-SZ-DROP 'hook forward' ;;

    A4.8.1) any_re "$o" '/opt/grading/a4' ;;
    A4.8.2) any_re "$o" 'a4-selfcheck.sh' ;;
    A4.8.3) all "$o" Command: Expected: Actual: Result: ;;
    A4.8.4) all "$o" vg_a4_storage lsblk pvs vgs lvs ;;
    A4.8.5) all "$o" NFS ACL Samba olga danil ;;
    A4.8.6) all "$o" manifest sha256 latest restore ;;
    A4.8.7) all "$o" A4_BACKUP_OK A4_RESTORE_OK A4-SH-DROP A4-SZ-DROP ;;
    A4.8.8) [ -n "$(tr -d '[:space:]' <<<"$o")" ;;
    *) ok_basic "$o" "$rc" ;;
  esac
}

validate_start() {
  awk -F'\t' -v id="$A4_START_FROM" 'NR>1 && $1==id{f=1} END{exit !f}' "$A4_CRITERIA_MAP" ||
    { echo "Aspect $A4_START_FROM not found" >&2; exit 2; }
}

main() {
  validate_start
  echo -e "${CYAN}A4 remote evaluator — Storage, Backup, Logs and Recovery${NC}"
  echo "Рекомендуемый хост запуска: maint-a4 (10.44.20.20)"
  echo "Отчёты: $A4_REPORT_DIR"
  ssh_precheck
  local started=0 id sub desc mark runfrom commands expected notes command last_sub=""
  while IFS=$'\t' read -r id sub desc mark runfrom commands expected notes; do
    [ "$id" = CriterionID ] && continue
    [ "$id" = "$A4_START_FROM" ] && started=1
    [ "$started" = 1 ] || continue
    if [ "$sub" != "$last_sub" ]; then section "$sub"; last_sub="$sub"; fi
    step "$id" "$desc"
    if [[ "$PERSISTENCE_IDS" == *" $id "* ]] && [ "$A4_POST_REBOOT" != 1 ]; then
      skip "$id" "$mark" "используйте --post-reboot после согласованного restart/reboot"
      continue
    fi
    command="$(decode_newlines "$commands")"
    cmd_show "$id" "$command"
    run_command "$id" "$command"
    show_output "ExitCode=$A4_LAST_RC (полный вывод показан выше)"
    if evaluate_result "$id" "$A4_LAST_OUT" "$A4_LAST_RC"; then
      pass "$id" "$mark" "фактический вывод соответствует ожидаемому результату"
    else
      fail "$id" "$mark" "ожидаемые свойства не подтверждены: $expected"
    fi
  done < "$A4_CRITERIA_MAP"
  write_summary
}

main "$@"
