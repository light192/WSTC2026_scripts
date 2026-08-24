#!/usr/bin/env bash
# Local fallback evidence collector for one A5 VM.
set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/a5-common.sh"
while [ $# -gt 0 ]; do
  case "$1" in
    --no-pause) A5_PAUSE=0 ;; --pause) A5_PAUSE=1 ;;
    --report-dir) shift; A5_REPORT_DIR="${1:?missing report directory}" ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac; shift
done
HN="$(hostname -s 2>/dev/null || hostname)"
A5_RESULTS_TSV="$A5_REPORT_DIR/a5-local-${HN}-results.tsv"
A5_DETAIL_LOG="$A5_REPORT_DIR/a5-local-${HN}-detail.log"
mkdir -p "$A5_REPORT_DIR"; printf 'CriterionID\tMaxMark\tStatus\tMessage\n' > "$A5_RESULTS_TSV"; : > "$A5_DETAIL_LOG"
capture() {
  local id="$1" mark="$2" title="$3"; shift 3
  local command="$*" out rc
  step "$id" "$title"; cmd_show "$id" "$command"
  out="$(bash -o pipefail -c "$command" 2>&1)"; rc=$?
  show_output "$out"$'\n'"ExitCode=$rc"
  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then pass "$id" "$mark" "local evidence collected on $HN"
  else fail "$id" "$mark" "local command failed on $HN"; fi
}
section "A5 local fallback - $HN"
capture A5.1.01 0.25 hostname "hostnamectl --static; getent hosts \$(hostname -s) 2>/dev/null || true"
capture A5.1.02 0.25 addressing "ip -4 -br addr; ip -6 -br addr show scope global"
capture A5.1.05 0.25 routes "ip route; ip -6 route"
case "$HN" in
  sh-gw-a5|sz-gw-a5)
    capture A5.1.04 0.25 forwarding "sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding"
    capture A5.7.01 0.25 nftables "systemctl is-enabled nftables; systemctl is-active nftables; nft list ruleset"
    capture A5.3.02 0.25 dhcp-relay "ps aux | grep -iE '[d]hcrelay|[d]hcp.?relay'; cat /etc/default/isc-dhcp-relay 2>/dev/null"
    ;;
  idm-a5)
    capture A5.2.01 0.25 DNS "systemctl is-active bind9 named 2>/dev/null || true; dig @127.0.0.1 atlas.a5.test SOA +norecurse"
    capture A5.4.01 0.25 LDAP "systemctl is-active slapd; ldapsearch -x -H ldap://127.0.0.1 -b '' -s base namingContexts"
    capture A5.6.01 0.25 chrony "chronyc tracking; grep -E '^[[:space:]]*allow|^[[:space:]]*local[[:space:]]+stratum' /etc/chrony/chrony.conf"
    capture A5.8.01 0.25 ansible "ls -la /opt/a5-ansible; find /opt/grading/a5 -maxdepth 1 -type f -ls 2>/dev/null"
    ;;
  net-a5)
    capture A5.2.02 0.25 secondary-DNS "systemctl is-active bind9 named 2>/dev/null || true; dig @127.0.0.1 atlas.a5.test SOA +short +norecurse"
    capture A5.3.01 0.25 kea "systemctl is-active kea-dhcp4-server; ss -lnup | grep :67"
    capture A5.6.03 0.25 central-rsyslog "systemctl is-active rsyslog; ss -ltnp | grep :514; ls -l /var/log/remote"
    ;;
  portal-a5)
    capture A5.5.01 0.25 apache "systemctl is-active apache2; ss -ltnp | grep :443; apachectl -S 2>&1"
    capture A5.5.05 0.25 portal-page "curl -sSk https://127.0.0.1/ 2>/dev/null || curl -sS http://127.0.0.1/"
    ;;
  sh-client-a5|sz-client-a5)
    capture A5.3.07 0.25 lease "ip -4 -br addr; ip route show default; cat /etc/resolv.conf"
    capture A5.4.14 0.25 sssd "getent passwd nora erlan; systemctl is-active sssd"
    ;;
  *) warn A5.1.01 0.25 "unknown hostname $HN" ;;
esac
write_summary
