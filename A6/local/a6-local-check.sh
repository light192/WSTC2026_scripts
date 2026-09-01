#!/usr/bin/env bash
# Local fallback evidence collector for one A6 VM.
set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/a6-common.sh"
while [ $# -gt 0 ]; do
  case "$1" in
    --no-pause) A6_PAUSE=0 ;; --pause) A6_PAUSE=1 ;;
    --report-dir) shift; A6_REPORT_DIR="${1:?missing report directory}" ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac; shift
done
HN="$(hostname -s 2>/dev/null || hostname)"
A6_RESULTS_TSV="$A6_REPORT_DIR/a6-local-${HN}-results.tsv"
A6_DETAIL_LOG="$A6_REPORT_DIR/a6-local-${HN}-detail.log"
mkdir -p "$A6_REPORT_DIR"; printf 'CriterionID\tMaxMark\tStatus\tMessage\n' > "$A6_RESULTS_TSV"; : > "$A6_DETAIL_LOG"
capture() {
  local id="$1" mark="$2" title="$3"; shift 3
  local command="$*" out rc
  step "$id" "$title"; cmd_show "$id" "$command"
  out="$(bash -o pipefail -c "$command" 2>&1)"; rc=$?; show_output "$out"$'\n'"ExitCode=$rc"
  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then warn "$id" "$mark" "local evidence collected on $HN; expert verdict required"
  else fail "$id" "$mark" "local command failed on $HN"; fi
}
section "A6 local fallback - $HN"
capture A1.01 0.25 hostname "hostname; ip -4 -br addr; ip route"
case "$HN" in
  sh-edge-a6|sz-edge-a6)
    capture A1.04 0.25 forwarding "sysctl net.ipv4.ip_forward; ip route"
    capture A1.05 0.25 wireguard "ip -4 addr show wg0; wg show; systemctl is-enabled wg-quick@wg0"
    capture F1.01 0.50 nftables "systemctl is-active nftables; systemctl is-enabled nftables; nft list ruleset"
    capture A1.09 0.50 dhcp-relay "pgrep -fa dhcrelay; ip route get 10.76.40.20"
    ;;
  directory-a6)
    capture B1.01 0.50 primary-dns "systemctl is-active bind9; dig @127.0.0.1 nova.a6.test SOA +norecurse"
    capture C1.01 0.50 ldap "systemctl is-active slapd; ldapsearch -x -LLL -H ldap://127.0.0.1 -b dc=nova,dc=a6,dc=test '(uid=maya)' uid uidNumber"
    capture G1.05 0.25 node-exporter "systemctl is-active prometheus-node-exporter node_exporter 2>/dev/null; ss -ltn | grep :9100"
    ;;
  network-a6)
    capture B1.02 0.25 secondary-dns "systemctl is-active bind9; dig @127.0.0.1 nova.a6.test SOA +short"
    capture A1.08 0.25 kea "systemctl is-active kea-dhcp4-server; cat /etc/kea/kea-dhcp4.conf"
    capture G1.05 0.25 node-exporter "ss -ltn | grep :9100"
    ;;
  services-a6)
    capture D1.01 0.25 shares "exportfs -v; testparm -s 2>/dev/null; getfacl /srv/files/team"
    capture E1.06 0.25 web-mail "systemctl is-active apache2 postfix dovecot; ss -ltnp"
    capture C1.06 0.50 sssd "getent passwd maya timur; getent group linuxusers filewriters webadmins"
    ;;
  ops-a6)
    capture G1.02 0.25 compose "cd /opt/a6-monitoring && docker compose config --services && docker compose ps"
    capture G1.07 0.25 blackbox "systemctl is-active prometheus-blackbox-exporter blackbox_exporter 2>/dev/null; ss -ltn | grep :9115"
    capture H1.03 0.25 grafana "curl -fsS -u 'admin:Skill39-A6-Monitor!' http://127.0.0.1:3000/api/dashboards/uid/a6-integrated-infra"
    ;;
  sh-user-a6)
    capture A1.03 0.25 dhcp "ip -4 -br addr; resolvectl status 2>/dev/null || cat /etc/resolv.conf"
    capture C1.06 0.50 sssd "getent passwd maya timur; getent group linuxusers filewriters webadmins"
    ;;
  *) warn A1.01 0.25 "unknown hostname $HN" ;;
esac
write_summary
