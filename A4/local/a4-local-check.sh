#!/usr/bin/env bash
# Local fallback evidence collector for one A4 VM.
set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/a4-common.sh"
while [ $# -gt 0 ]; do
  case "$1" in
    --no-pause) A4_PAUSE=0 ;; --pause) A4_PAUSE=1 ;;
    --report-dir) shift; A4_REPORT_DIR="${1:?missing report directory}" ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac; shift
done
HN="$(hostname -s 2>/dev/null || hostname)"
A4_RESULTS_TSV="$A4_REPORT_DIR/a4-local-${HN}-results.tsv"
A4_DETAIL_LOG="$A4_REPORT_DIR/a4-local-${HN}-detail.log"
mkdir -p "$A4_REPORT_DIR"; printf 'CriterionID\tMaxMark\tStatus\tMessage\n' > "$A4_RESULTS_TSV"; : > "$A4_DETAIL_LOG"
capture() {
  local id="$1" mark="$2" title="$3"; shift 3
  local command="$*" out rc
  step "$id" "$title"; cmd_show "$id" "$command"
  out="$(bash -o pipefail -c "$command" 2>&1)"; rc=$?
  show_output "$out"$'\n'"ExitCode=$rc"
  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then pass "$id" "$mark" "локальное evidence собрано на $HN"
  else fail "$id" "$mark" "локальная команда завершилась ошибкой на $HN"; fi
}
section "A4 local fallback — $HN"
capture A4.1.1 0.14 hostname "hostnamectl --static; hostname -f 2>/dev/null || true"
capture A4.1.2 0.29 addressing "ip -br address; ip -6 -br addr show scope global"
capture A4.1.4 0.18 routes "ip route; ip -6 route"
case "$HN" in
  sh-router-a4|sz-router-a4)
    capture A4.1.7 0.16 forwarding "sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding; nft list ruleset"
    capture A4.7.1 0.25 nftables "systemctl is-enabled nftables; systemctl is-active nftables; nft list ruleset"
    ;;
  storage-a4)
    capture A4.2.2 0.38 LVM "lsblk; pvs; vgs; lvs; blkid; for t in /srv/projects /srv/backups /srv/archive; do findmnt -rn --target \"\$t\" -o TARGET,SOURCE,FSTYPE,OPTIONS || true; done; cat /etc/fstab"
    capture A4.3.5 0.25 ACL "getfacl -p /srv/projects/team; exportfs -v; testparm -s"
    capture A4.4.5 0.35 backups "find /srv/backups/svc-a4 -maxdepth 3 -type f -o -type l | sort | tail -80"
    ;;
  sh-operator-a4|maint-a4)
    capture A4.3.10 0.20 NFS "findmnt /mnt/a4-projects; ls -la /mnt/a4-projects; getent passwd olga danil"
    [ "$HN" != maint-a4 ] || capture A4.8.1 0.10 evidence "find /opt/grading/a4 /opt/a4-checks -maxdepth 2 -type f -ls"
    ;;
  log-a4)
    capture A4.1.12 0.23 DNS "systemctl is-active bind9 named 2>/dev/null || true; ss -lntup | grep :53; dig @127.0.0.1 cedar.a4.local SOA"
    capture A4.6.1 0.25 syslog "systemctl is-active rsyslog; ss -lntp | grep :514; find /var/log/remote -maxdepth 1 -type f -ls"
    ;;
  svc-a4)
    capture A4.4.2 0.35 backup-script "ls -l /usr/local/sbin/a4-backup-svc.sh; systemctl status a4-backup.service a4-backup.timer --no-pager; tail -40 /var/log/a4-service/backup.log"
    capture A4.5.2 0.35 restored-data "cat /srv/a4-service/data/critical.txt; ls -l /usr/local/sbin/a4-restore-svc.sh"
    ;;
  *) warn A4.1.1 0.14 "неизвестный hostname $HN" ;;
esac
write_summary
