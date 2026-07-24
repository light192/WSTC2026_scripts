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
A4_COMPONENT_PASS=0
A4_COMPONENT_TOTAL=0
A4_COMPONENT_MESSAGE=""
A4_BUILD="2026-07-24.5"

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
mount_matches() {
  local text="$1" target="$2" expected_lv="$3" line
  line="$(sed -n "s|^MOUNT=${target};RESULT=||p" <<<"$text" | head -n1)"
  [ -n "$line" ] && [ "$line" != "<NOT-MOUNTED>" ] &&
    grep -Fqi "$expected_lv" <<<"$line"
}
group_matches() {
  local text="$1" host="$2" group="$3" gid="$4"
  grep -Fqi "HOST=${host};GROUP=${group};ACTUAL=${group}:x:${gid}:" <<<"$text"
}
component_reset() {
  A4_COMPONENT_PASS=0
  A4_COMPONENT_TOTAL=0
  A4_COMPONENT_MESSAGE=""
}
component_check() {
  local label="$1"
  shift
  A4_COMPONENT_TOTAL=$((A4_COMPONENT_TOTAL + 1))
  if "$@"; then
    A4_COMPONENT_PASS=$((A4_COMPONENT_PASS + 1))
    echo -e "${GREEN}[PASS]${NC} $label"
  else
    echo -e "${RED}[FAIL]${NC} $label"
  fi
}
text_has_fixed() { grep -Fqi "$2" <<<"$1"; }
text_has_regex() { grep -Eiq "$2" <<<"$1"; }
manifest_hashes_valid() {
  awk 'NF {
    if ($1 !~ /^[[:xdigit:]]{64}$/) bad=1
    count++
  } END { exit !(count>0 && !bad) }' <<<"$1"
}
manifest_paths_relative() {
  awk 'NF {
    path=$2
    if (path=="" || path ~ /^\// || path ~ /(^|\/)\.\.(\/|$)/) bad=1
    count++
  } END { exit !(count>0 && !bad) }' <<<"$1"
}

evaluate_components() {
  local id="$1" o="$2" actual host group gid
  component_reset
  case "$id" in
    A4.1.16)
      echo -e "${BLUE}Покомпонентная оценка:${NC}"
      component_check "dns.${A4_DOMAIN} -> log-a4.${A4_DOMAIN}." \
        text_has_fixed "$o" 'CNAME=dns;ACTUAL=log-a4.cedar.a4.local.'
      component_check "log.${A4_DOMAIN} -> log-a4.${A4_DOMAIN}." \
        text_has_fixed "$o" 'CNAME=log;ACTUAL=log-a4.cedar.a4.local.'
      component_check "files.${A4_DOMAIN} -> storage-a4.${A4_DOMAIN}." \
        text_has_fixed "$o" 'CNAME=files;ACTUAL=storage-a4.cedar.a4.local.'
      component_check "backup.${A4_DOMAIN} -> storage-a4.${A4_DOMAIN}." \
        text_has_fixed "$o" 'CNAME=backup;ACTUAL=storage-a4.cedar.a4.local.'
      component_check "storage.${A4_DOMAIN} -> storage-a4.${A4_DOMAIN}." \
        text_has_fixed "$o" 'CNAME=storage;ACTUAL=storage-a4.cedar.a4.local.'
      component_check "svc.${A4_DOMAIN} -> svc-a4.${A4_DOMAIN}." \
        text_has_fixed "$o" 'CNAME=svc;ACTUAL=svc-a4.cedar.a4.local.'
      ;;
    A4.2.7)
      echo -e "${BLUE}Покомпонентная оценка:${NC}"
      component_check "/srv/projects активен и использует lv_projects" \
        mount_matches "$o" /srv/projects lv_projects
      component_check "/srv/backups активен и использует lv_backups" \
        mount_matches "$o" /srv/backups lv_backups
      component_check "/srv/archive активен и использует lv_archive" \
        mount_matches "$o" /srv/archive lv_archive
      ;;
    A4.3.1)
      echo -e "${BLUE}Покомпонентная оценка:${NC}"
      while IFS='|' read -r host group gid; do
        component_check "${host}: ${group}, GID=${gid}" \
          group_matches "$o" "$host" "$group" "$gid"
      done <<'EOF'
storage-a4|projectops|7440
storage-a4|auditors|7450
maint-a4|projectops|7440
maint-a4|auditors|7450
sh-operator-a4|projectops|7440
sh-operator-a4|auditors|7450
EOF
      ;;
    A4.3.2)
      echo -e "${BLUE}Покомпонентная оценка:${NC}"
      # Each user on each of the three required nodes is one independently scored component.
      for host in 10.44.30.10 10.44.20.20 10.44.10.20; do
        actual="$(awk -v marker="===$host===" '
          $0==marker {inhost=1; next}
          /^===/ {inhost=0}
          inhost {print}
        ' <<<"$o")"
        component_check "${host}: olga UID=8441, group projectops" \
          bash -c 'grep -Eq "uid=8441\\(olga\\).*projectops" <<<"$1"' _ "$actual"
        component_check "${host}: danil UID=8442, group auditors" \
          bash -c 'grep -Eq "uid=8442\\(danil\\).*auditors" <<<"$1"' _ "$actual"
      done
      ;;
    A4.3.3)
      echo -e "${BLUE}Покомпонентная оценка:${NC}"
      component_check "backupsvc существует с UID=8490" \
        text_has_regex "$o" 'uid=8490\(backupsvc\)'
      component_check "backupsvc состоит в backupops" \
        text_has_regex "$o" '^GROUPS=.*backupops([[:space:]]|$)|^backupops:x:[0-9]+:.*backupsvc'
      ;;
    A4.3.13)
      echo -e "${BLUE}Покомпонентная оценка:${NC}"
      component_check "maint-a4: olga может создать файл через NFS" \
        text_has_fixed "$o" 'HOST=maint-a4;OLGA_WRITE=PASS'
      component_check "sh-operator-a4: olga может создать файл через NFS" \
        text_has_fixed "$o" 'HOST=sh-operator-a4;OLGA_WRITE=PASS'
      ;;
    A4.3.14)
      echo -e "${BLUE}Покомпонентная оценка:${NC}"
      component_check "maint-a4: danil читает каталог, запись запрещена" \
        text_has_fixed "$o" 'HOST=maint-a4;DANIL_READ_NO_WRITE=PASS'
      component_check "sh-operator-a4: danil читает каталог, запись запрещена" \
        text_has_fixed "$o" 'HOST=sh-operator-a4;DANIL_READ_NO_WRITE=PASS'
      ;;
    A4.4.3)
      echo -e "${BLUE}Покомпонентная оценка:${NC}"
      component_check "backupsvc может писать в /srv/backups/svc-a4" \
        text_has_fixed "$o" BACKUP_WRITE_OK
      component_check "backupsvc не может писать в /srv/projects" \
        text_has_fixed "$o" PROJECTS_DENIED
      component_check "backupsvc не может писать в /srv/archive" \
        text_has_fixed "$o" ARCHIVE_DENIED
      component_check "backupsvc не может писать в /etc" \
        text_has_fixed "$o" ETC_DENIED
      component_check "backupsvc не может писать в /root" \
        text_has_fixed "$o" ROOT_DENIED
      ;;
    A4.4.7)
      echo -e "${BLUE}Покомпонентная оценка:${NC}"
      component_check "каждая строка содержит 64-символьный SHA-256" \
        manifest_hashes_valid "$o"
      component_check "пути в manifest являются относительными" \
        manifest_paths_relative "$o"
      ;;
  esac
  if [ "$A4_COMPONENT_TOTAL" -gt 0 ]; then
    A4_COMPONENT_MESSAGE="${A4_COMPONENT_PASS}/${A4_COMPONENT_TOTAL} компонентов пройдено"
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
    A4.1.16)
      all "$o" \
        'CNAME=dns;ACTUAL=log-a4.cedar.a4.local.' \
        'CNAME=log;ACTUAL=log-a4.cedar.a4.local.' \
        'CNAME=files;ACTUAL=storage-a4.cedar.a4.local.' \
        'CNAME=backup;ACTUAL=storage-a4.cedar.a4.local.' \
        'CNAME=storage;ACTUAL=storage-a4.cedar.a4.local.' \
        'CNAME=svc;ACTUAL=svc-a4.cedar.a4.local.'
      ;;
    A4.1.17) [ "$(count_re "$o" 'cedar.a4.local.')" -ge 11 ] ;;
    A4.1.18) any_re "$o" 'REFUSED|timed out|no servers could be reached' ;;
    A4.1.19) [ "$(count_re "$o" '10.44.40.10|127.0.0.1')" -ge 7 ] ;;

    A4.2.1) all "$o" sdb sdc vg_a4_storage && [ "$(count_re "$o" '1[2-9](\.[0-9]+)?G')" -ge 2 ] ;;
    A4.2.2) all "$o" vg_a4_storage && any_re "$o" '(^|[[:space:]])2([[:space:]]|$)' ;;
    A4.2.3) all "$o" lv_projects vg_a4_storage && any_re "$o" '8(\.0+)?g' ;;
    A4.2.4) all "$o" lv_backups vg_a4_storage && any_re "$o" '8(\.0+)?g' ;;
    A4.2.5) all "$o" lv_archive vg_a4_storage && any_re "$o" '2(\.0+)?g' ;;
    A4.2.6) [ "$(count_re "$o" 'TYPE="(ext4|xfs)"')" -ge 3 ] ;;
    A4.2.7)
      mount_matches "$o" /srv/projects lv_projects &&
        mount_matches "$o" /srv/backups lv_backups &&
        mount_matches "$o" /srv/archive lv_archive
      ;;
    A4.2.8) [ "$(count_re "$o" '^(UUID|LABEL)=.*[[:space:]]+/srv/(projects|backups|archive)')" -ge 3 ] ;;
    A4.2.9) all "$o" A4_NFS_OK A4_BACKUP_TARGET keep-ok ;;
    A4.2.10) awk 'BEGIN{ok=0} $1+0>=1{ok=1} END{exit !ok}' <<<"$o" ;;
    A4.2.11) all "$o" /dev/sdb /dev/sdc vg_a4_storage && none_re "$o" '/dev/sda.*vg_a4_storage' ;;
    A4.2.12) all "$o" vg_a4_storage lsblk pvs vgs lvs findmnt ;;
    A4.2.13) [ "$rc" -eq 0 ] && all "$o" /srv/projects /srv/backups /srv/archive ;;

    A4.3.1)
      group_matches "$o" storage-a4 projectops 7440 &&
        group_matches "$o" storage-a4 auditors 7450 &&
        group_matches "$o" maint-a4 projectops 7440 &&
        group_matches "$o" maint-a4 auditors 7450 &&
        group_matches "$o" sh-operator-a4 projectops 7440 &&
        group_matches "$o" sh-operator-a4 auditors 7450
      ;;
    A4.3.2)
      [ "$(count_re "$o" 'uid=8441\(olga\)')" -ge 3 ] &&
        [ "$(count_re "$o" 'uid=8442\(danil\)')" -ge 3 ] &&
        [ "$(count_re "$o" 'projectops')" -ge 3 ] &&
        [ "$(count_re "$o" 'auditors')" -ge 3 ]
      ;;
    A4.3.3)
      any_re "$o" 'uid=8490\(backupsvc\)' &&
        any_re "$o" '^GROUPS=.*backupops([[:space:]]|$)|^backupops:x:[0-9]+:.*backupsvc'
      ;;
    A4.3.4) [ "$rc" -eq 0 ] && any_re "$o" '/srv/projects/team' ;;
    A4.3.5)
      all "$o" 'group:projectops:rwx' 'group:auditors:r-x' 'other::---'
      ;;
    A4.3.6)
      all "$o" 'default:group:projectops:rwx' 'default:group:auditors:r-x'
      ;;
    A4.3.7)
      any_re "$o" '/srv/projects.*10.44.10.0/24' &&
        any_re "$o" '/srv/projects.*10.44.20.0/24' &&
        none_re "$o" '0.0.0.0/0|\*\(.*rw'
      ;;
    A4.3.8)
      any_re "$o" ':2049' && any_re "$o" 'vers=4|nfs4'
      ;;
    A4.3.9)
      any_re "$o" '/srv/projects' && none_re "$o" 'no_root_squash'
      ;;
    A4.3.10|A4.3.11)
      [ "$rc" -eq 0 ] && all "$o" /mnt/a4-projects A4_NFS_OK
      ;;
    A4.3.12)
      [ "$rc" -eq 0 ] &&
        [ "$(count_re "$o" '/mnt/a4-projects')" -ge 4 ]
      ;;
    A4.3.13) [ "$rc" -eq 0 ] ;;
    A4.3.14)
      [ "$rc" -eq 0 ] &&
        all "$o" DANIL_WRITE_DENIED DANIL_SH_WRITE_DENIED
      ;;
    A4.3.15)
      all "$o" '[projects]' /srv/projects/team &&
        any_re "$o" ':445'
      ;;
    A4.3.16)
      any_re "$o" 'NT_STATUS_ACCESS_DENIED|NT_STATUS_LOGON_FAILURE|Anonymous login unsuccessful|Permission denied'
      ;;
    A4.3.17)
      [ "$rc" -eq 0 ] && any_re "$o" 'olga-smb-test.txt'
      ;;
    A4.3.18)
      any_re "$o" 'danil-smb-deny.txt|blocks available|blocks of size' &&
        any_re "$o" 'NT_STATUS_ACCESS_DENIED|Permission denied'
      ;;
    A4.3.19)
      [ "$rc" -eq 0 ] && any_re "$o" ':445' &&
        any_re "$o" 'projects|blocks available|blocks of size'
      ;;

    A4.4.1) all "$o" APP_NAME=cedar-a4 BACKUP_REQUIRED=yes VERSION=1 A4_CRITICAL_DATA ;;
    A4.4.2) [ "$rc" -eq 0 ] && any_re "$o" '(^|[[:space:]])backupsvc([[:space:]]|$)' ;;
    A4.4.3) all "$o" BACKUP_WRITE_OK PROJECTS_DENIED ARCHIVE_DENIED ETC_DENIED ROOT_DENIED ;;
    A4.4.4) [ "$rc" -eq 0 ] && any_re "$o" 'a4-backup-svc.sh' && any_re "$o" '^#!|bash|sh' ;;
    A4.4.5) any_re "$o" '/srv/backups/svc-a4/[0-9]{8}-[0-9]{6}' ;;
    A4.4.6)
      all "$o" srv/a4-service/config/app.conf srv/a4-service/data/critical.txt \
        etc/fstab etc/rsyslog.conf etc/rsyslog.d
      ;;
    A4.4.7) manifest_hashes_valid "$o" && manifest_paths_relative "$o" ;;
    A4.4.8) [ "$rc" -eq 0 ] && any_re "$o" ': OK$' && none_re "$o" ': FAILED$' ;;
    A4.4.9)
      any_re "$o" '/srv/backups/svc-a4/[0-9]{8}-[0-9]{6}' &&
        any_re "$o" 'latest[[:space:]]+->'
      ;;
    A4.4.10) [ "$rc" -eq 0 ] && [ -n "$(tr -d '[:space:]' <<<"$o")" ] ;;
    A4.4.11) any_re "$o" 'A4_BACKUP_OK' ;;
    A4.4.12) all "$o" a4-backup.service ExecStart && any_re "$o" 'a4-backup-svc.sh|success|exited' ;;
    A4.4.13)
      all "$o" enabled active a4-backup.timer &&
        any_re "$o" '15min|1h|hourly|OnCalendar|OnUnitActiveSec'
      ;;
    A4.4.14)
      awk 'NF && $1 ~ /^[0-9]+$/ { exit !($1>=2) } END { if (NR==0) exit 1 }' <<<"$o"
      ;;

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

show_diagnostics() {
  local id="$1" o="$2" name expected actual
  case "$id" in
    A4.1.16)
      echo -e "${BLUE}Подробная проверка свойств:${NC}"
      while IFS='|' read -r name expected; do
        actual="$(sed -n "s/^CNAME=${name};ACTUAL=//p" <<<"$o" | head -n1)"
        [ -n "$actual" ] || actual="<EMPTY>"
        if [ "${actual,,}" = "${expected,,}" ]; then
          echo -e "${GREEN}[OK]${NC} ${name}.${A4_DOMAIN} -> ${actual}"
        else
          echo -e "${RED}[FAIL]${NC} ${name}.${A4_DOMAIN}: ожидается ${expected}; получено ${actual}"
        fi
      done <<'EOF'
dns|log-a4.cedar.a4.local.
log|log-a4.cedar.a4.local.
files|storage-a4.cedar.a4.local.
backup|storage-a4.cedar.a4.local.
storage|storage-a4.cedar.a4.local.
svc|svc-a4.cedar.a4.local.
EOF
      ;;
    A4.2.7)
      echo -e "${BLUE}Подробная проверка свойств:${NC}"
      while IFS='|' read -r target expected_lv; do
        actual="$(sed -n "s|^MOUNT=${target};RESULT=||p" <<<"$o" | head -n1)"
        [ -n "$actual" ] || actual="<NOT-MOUNTED>"
        if [ "$actual" != "<NOT-MOUNTED>" ] && grep -Fqi "$expected_lv" <<<"$actual"; then
          echo -e "${GREEN}[OK]${NC} ${target}: ожидаемый LV=${expected_lv}; фактически ${actual}"
        else
          echo -e "${RED}[FAIL]${NC} ${target}: ожидаемый LV=${expected_lv}; фактически ${actual}"
        fi
      done <<'EOF'
/srv/projects|lv_projects
/srv/backups|lv_backups
/srv/archive|lv_archive
EOF
      ;;
    A4.3.3)
      echo -e "${BLUE}Подробная проверка свойств:${NC}"
      if any_re "$o" 'uid=8490\(backupsvc\)'; then
        echo -e "${GREEN}[OK]${NC} backupsvc существует, UID=8490."
      else
        echo -e "${RED}[FAIL]${NC} ожидается backupsvc с UID=8490."
      fi
      if any_re "$o" '^GROUPS=.*backupops([[:space:]]|$)|^backupops:x:[0-9]+:.*backupsvc'; then
        echo -e "${GREEN}[OK]${NC} backupsvc связан с группой backupops."
      else
        echo -e "${RED}[FAIL]${NC} backupsvc не состоит в backupops. Фактические группы: $(sed -n 's/^GROUPS=//p' <<<"$o" | head -n1)"
      fi
      echo -e "${CYAN}[INFO]${NC} Парольный вход для backupsvc этим критерием не требуется и не оценивается."
      ;;
    A4.3.1)
      echo -e "${BLUE}Подробная проверка свойств:${NC}"
      while IFS='|' read -r host group gid; do
        actual="$(sed -n "s|^HOST=${host};GROUP=${group};ACTUAL=||p" <<<"$o" | head -n1)"
        [ -n "$actual" ] || actual="<MISSING>"
        if [[ "${actual,,}" == "${group}:x:${gid}:"* ]]; then
          echo -e "${GREEN}[OK]${NC} ${host}: ${group}, ожидаемый GID=${gid}; фактически ${actual}"
        else
          echo -e "${RED}[FAIL]${NC} ${host}: ${group}, ожидаемый GID=${gid}; фактически ${actual}"
        fi
      done <<'EOF'
storage-a4|projectops|7440
storage-a4|auditors|7450
maint-a4|projectops|7440
maint-a4|auditors|7450
sh-operator-a4|projectops|7440
sh-operator-a4|auditors|7450
EOF
      actual="$(sed -n 's|^HOST=storage-a4;GROUP=backupops;ACTUAL=||p' <<<"$o" | head -n1)"
      if [[ "${actual,,}" == backupops:x:7460:* ]]; then
        echo -e "${CYAN}[INFO]${NC} storage-a4: optional backupops найдена, GID=7460."
      else
        echo -e "${CYAN}[INFO]${NC} storage-a4: backupops не подтверждена; это не влияет на A4.3.1, если группа не используется решением."
      fi
      ;;
  esac
}

validate_start() {
  awk -F'\t' -v id="$A4_START_FROM" 'NR>1 && $1==id{f=1} END{exit !f}' "$A4_CRITERIA_MAP" ||
    { echo "Aspect $A4_START_FROM not found" >&2; exit 2; }
}

main() {
  if grep -Eq 'sudo[[:space:]]+-u' "$A4_CRITERIA_MAP"; then
    echo "ERROR: обнаружен устаревший a4_criteria_map.tsv с командами sudo -u." >&2
    echo "Обновите целиком каталоги A4/remote, A4/common и A4/criteria. Build: $A4_BUILD" >&2
    exit 2
  fi
  validate_start
  echo -e "${CYAN}A4 remote evaluator — Storage, Backup, Logs and Recovery (build $A4_BUILD)${NC}"
  echo "Рекомендуемый хост запуска: maint-a4 (10.44.20.20)"
  echo "Отчёты: $A4_REPORT_DIR"
  ssh_precheck
  local started=0 id sub desc mark runfrom commands expected notes command awarded last_sub=""
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
    if evaluate_components "$id" "$A4_LAST_OUT"; then
      if [ "$A4_COMPONENT_PASS" -eq "$A4_COMPONENT_TOTAL" ]; then
        pass "$id" "$mark" "$A4_COMPONENT_MESSAGE"
      elif [ "$A4_COMPONENT_PASS" -gt 0 ]; then
        awarded="$(awk -v m="$mark" -v p="$A4_COMPONENT_PASS" -v t="$A4_COMPONENT_TOTAL" \
          'BEGIN { printf "%.3f", m*p/t }')"
        part "$id" "$mark" "$awarded" "$A4_COMPONENT_MESSAGE"
      else
        fail "$id" "$mark" "$A4_COMPONENT_MESSAGE"
      fi
    elif evaluate_result "$id" "$A4_LAST_OUT" "$A4_LAST_RC"; then
      show_diagnostics "$id" "$A4_LAST_OUT"
      pass "$id" "$mark" "фактический вывод соответствует ожидаемому результату"
    else
      show_diagnostics "$id" "$A4_LAST_OUT"
      fail "$id" "$mark" "ожидаемые свойства не подтверждены: $expected"
    fi
  done < "$A4_CRITERIA_MAP"
  write_summary
}

main "$@"
