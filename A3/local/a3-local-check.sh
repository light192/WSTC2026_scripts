#!/usr/bin/env bash
# Local fallback evidence collector for one A3 VM.

set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/a3-common.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    --no-pause) A3_PAUSE=0 ;;
    --pause) A3_PAUSE=1 ;;
    --report-dir) shift; A3_REPORT_DIR="${1:?missing report directory}" ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

HN="$(hostname -s 2>/dev/null || hostname)"
A3_RESULTS_TSV="$A3_REPORT_DIR/a3-local-${HN}-results.tsv"
A3_DETAIL_LOG="$A3_REPORT_DIR/a3-local-${HN}-detail.log"
mkdir -p "$A3_REPORT_DIR"
printf 'CriterionID\tMaxMark\tStatus\tMessage\n' > "$A3_RESULTS_TSV"
: > "$A3_DETAIL_LOG"

capture() {
  local id="$1" mark="$2" title="$3"; shift 3
  local command="$*" out rc
  step "$id" "$title"; cmd_show "$command"
  out="$(bash -o pipefail -c "$command" 2>&1)"; rc=$?
  show_output "$out"$'\n'"ExitCode=$rc"
  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then pass "$id" "$mark" "локальное evidence собрано на $HN"
  else fail "$id" "$mark" "локальная команда завершилась ошибкой на $HN"; fi
}

section "A3 local fallback — $HN"
capture A3.1.1 0.25 "hostname" "hostnamectl --static; hostname -f 2>/dev/null || true"
capture A3.1.2 0.35 "IPv4/IPv6 addresses" "ip -br address; ip -6 addr show scope global"
capture A3.1.4 0.25 "routes" "ip route; ip -6 route"
capture A3.2.12 0.25 "resolver" "cat /etc/resolv.conf; resolvectl status 2>/dev/null || true"

case "$HN" in
  branch-fw-a3|hq-fw-a3)
    capture A3.1.7 0.20 "forwarding" "sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding; grep -R 'forwarding\|ip_forward' /etc/sysctl.conf /etc/sysctl.d 2>/dev/null"
    capture A3.6.1 0.25 "nftables" "systemctl is-enabled nftables; systemctl is-active nftables; nft list ruleset"
    capture A3.6.16 0.25 "drop prefixes" "nft list ruleset | grep -E 'A3-BR-DROP|A3-HQ-DROP'"
    ;;
  branch-user-a3)
    capture A3.5.1 0.25 "WireGuard client" "systemctl is-enabled wg-quick@wg0; systemctl is-active wg-quick@wg0; ip addr show wg0; wg show"
    capture A3.3.8 0.30 "system CA trust" "grep -R 'Nova A3 Root CA' /etc/ssl/certs 2>/dev/null || true; curl -fsS https://portal.nova.a3.test/"
    ;;
  proxy-a3)
    capture A3.2.1 0.20 "authoritative DNS" "systemctl is-active bind9 named 2>/dev/null || true; ss -lntup | grep :53; dig @127.0.0.1 nova.a3.test SOA"
    capture A3.3.1 0.25 "local CA" "find /opt/a3-ca -maxdepth 2 -type f -ls; for f in /opt/a3-ca/*.crt /opt/a3-ca/*.pem; do openssl x509 -in \"\$f\" -noout -subject -issuer -ext subjectAltName 2>/dev/null; done"
    capture A3.4.5 0.25 "web/reverse proxy" "if systemctl is-active --quiet nginx; then echo WEB_SERVER=nginx; systemctl is-active nginx; nginx -t; elif systemctl is-active --quiet apache2; then echo WEB_SERVER=apache; systemctl is-active apache2; apache2ctl configtest; elif systemctl is-active --quiet httpd; then echo WEB_SERVER=apache; systemctl is-active httpd; httpd -t; else echo WEB_SERVER_NOT_FOUND; exit 1; fi; ss -lntp | grep -E ':80|:443'; curl -fsS https://portal.nova.a3.test/healthz"
    ;;
  app-a3)
    capture A3.4.1 0.25 "application backend" "ss -lntp | grep :8080; curl -fsS http://127.0.0.1:8080/; curl -fsS http://127.0.0.1:8080/healthz"
    ;;
  log-a3)
    capture A3.7.1 0.20 "central syslog" "systemctl is-active rsyslog; ss -lntp | grep :514; find /var/log/remote -maxdepth 1 -type f -ls 2>/dev/null"
    ;;
  admin-a3)
    capture A3.8.2 0.15 "grading evidence" "find /opt/grading/a3 -maxdepth 1 -type f -ls; find /opt/a3-checks -maxdepth 1 -type f -ls"
    ;;
  *) warn A3.1.1 0.25 "неизвестный hostname $HN; выполнены только общие проверки" ;;
esac

write_summary
