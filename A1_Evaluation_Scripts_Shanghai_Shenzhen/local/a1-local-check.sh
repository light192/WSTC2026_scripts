#!/usr/bin/env bash
# A1 local checker for a single VM.
# Use when the remote evaluator cannot reach all hosts.
# Run as root on each VM. It writes a local TSV and detailed log.

set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/a1-common.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    --pause) A1_PAUSE=1 ;;
    --no-pause) A1_PAUSE=0 ;;
    --report-dir) shift; A1_REPORT_DIR="$1"; A1_RESULTS_TSV="$A1_REPORT_DIR/a1-local-$(hostname)-results.tsv"; A1_DETAIL_LOG="$A1_REPORT_DIR/a1-local-$(hostname)-detail.log"; mkdir -p "$A1_REPORT_DIR"; printf "CriterionID\tMaxMark\tStatus\tMessage\n" > "$A1_RESULTS_TSV" ;;
    *) echo "Unknown option: $1"; exit 2 ;;
  esac
  shift
done

HN="$(hostname -s 2>/dev/null || hostname)"
A1_RESULTS_TSV="${A1_RESULTS_TSV:-$A1_REPORT_DIR/a1-local-${HN}-results.tsv}"
A1_DETAIL_LOG="${A1_DETAIL_LOG:-$A1_REPORT_DIR/a1-local-${HN}-detail.log}"
mkdir -p "$A1_REPORT_DIR"
printf "CriterionID\tMaxMark\tStatus\tMessage\n" > "$A1_RESULTS_TSV"
echo "A1 local check on $HN started $(date -Is)" | tee "$A1_DETAIL_LOG"

check_common() {
  section "COMMON - базовое состояние хоста $HN"

  step "Hostname/FQDN"
  out="$(hostname; hostname -f 2>/dev/null || true)"
  echo "$out" | tee -a "$A1_DETAIL_LOG"
  if echo "$out" | grep -q "$HN" && echo "$out" | grep -q "${A1_DOMAIN}"; then pass "LOCAL.HOSTNAME" "0" "hostname/FQDN looks correct on $HN"; else warn "LOCAL.HOSTNAME" "0" "hostname/FQDN may be incorrect on $HN"; fi

  step "Time zone, locale, keyboard"
  out="$(timedatectl 2>/dev/null | grep 'Time zone' || true; localectl status 2>/dev/null || true)"
  echo "$out" | tee -a "$A1_DETAIL_LOG"
  if echo "$out" | grep -q "Europe/Paris" && echo "$out" | grep -q "en_US.UTF-8"; then pass "LOCAL.LOCALE" "0" "time zone/locale OK"; else warn "LOCAL.LOCALE" "0" "time zone/locale not fully OK"; fi

  step "IP addressing and routes"
  out="$(ip -br address; echo '--- routes ---'; ip route; ip -6 route || true)"
  echo "$out" | tee -a "$A1_DETAIL_LOG"
  pass "LOCAL.IPROUTE" "0" "local IP/routes captured for manual review"
}

check_gateway() {
  section "GATEWAY - forwarding, routes, nftables on $HN"
  out="$(sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding; ip route; ip -6 route || true)"
  echo "$out" | tee -a "$A1_DETAIL_LOG"
  if echo "$out" | grep -q "net.ipv4.ip_forward = 1" && echo "$out" | grep -q "net.ipv6.conf.all.forwarding = 1"; then pass "A1.6" "0.25" "forwarding enabled on $HN"; else fail "A1.6" "0.25" "forwarding not enabled on $HN"; fi

  out="$(systemctl is-active nftables 2>/dev/null || true; nft list ruleset 2>/dev/null | head -200)"
  echo "$out" | tee -a "$A1_DETAIL_LOG"
  if echo "$out" | grep -q "active"; then pass "A7.1" "0.25" "nftables active on $HN"; else fail "A7.1" "0.25" "nftables inactive on $HN"; fi

  if [ "$HN" = "sh-gw-a1" ]; then
    echo "$out" | grep -q "A1-SH-DROP" && pass "A7.10" "0.25" "A1-SH-DROP prefix configured" || fail "A7.10" "0.25" "A1-SH-DROP prefix missing"
  elif [ "$HN" = "sz-gw-a1" ]; then
    echo "$out" | grep -q "A1-SZ-DROP" && pass "A7.10" "0.25" "A1-SZ-DROP prefix configured" || fail "A7.10" "0.25" "A1-SZ-DROP prefix missing"
  fi

  out="$(journalctl -k --no-pager | grep -E 'A1-SH-DROP|A1-SZ-DROP' | tail -20 || true)"
  echo "$out" | tee -a "$A1_DETAIL_LOG"
  [ -n "$out" ] && pass "A8.4" "0.25" "drop events visible locally on gateway" || warn "A8.4" "0.25" "drop events not visible locally yet"
}

check_id() {
  section "ID-A1 - DNS, LDAP, CA, central syslog"

  out="$(systemctl is-active bind9 named 2>/dev/null || true; ss -lntu | grep -E ':53\\b' || true)"
  echo "$out" | tee -a "$A1_DETAIL_LOG"
  if echo "$out" | grep -q "active" && echo "$out" | grep -q ":53"; then pass "A2.1" "0.25" "DNS service active/listening"; else fail "A2.1" "0.25" "DNS service inactive/not listening"; fi

  out="$(dig @127.0.0.1 www.${A1_DOMAIN} A +short; dig @127.0.0.1 _ldap._tcp.${A1_DOMAIN} SRV +short; dig @127.0.0.1 files.${A1_DOMAIN} CNAME +short)"
  echo "$out" | tee -a "$A1_DETAIL_LOG"
  if echo "$out" | grep -q "10.11.40.20" && echo "$out" | grep -q "389" && echo "$out" | grep -q "files-a1"; then pass "A2.LOCAL" "0" "local DNS key records OK"; else fail "A2.LOCAL" "0" "local DNS key records missing"; fi

  out="$(systemctl is-active slapd 2>/dev/null || true; ss -lntp | grep ':389' || true)"
  echo "$out" | tee -a "$A1_DETAIL_LOG"
  if echo "$out" | grep -q "active" && echo "$out" | grep -q ":389"; then pass "A4.1" "0.25" "OpenLDAP active/listening"; else fail "A4.1" "0.25" "OpenLDAP inactive/not listening"; fi

  out="$(ldapsearch -H ldap://localhost -x -b ${A1_BASE_DN} dn 2>&1)"
  echo "$out" | tee -a "$A1_DETAIL_LOG"
  if contains_all "$out" "ou=People,${A1_BASE_DN}" "ou=Groups,${A1_BASE_DN}" "ou=Services,${A1_BASE_DN}"; then pass "A4.2" "0.25" "Base DN/OU exist"; else fail "A4.2" "0.25" "Base DN/OU missing"; fi

  out="$(ldapsearch -H ldap://localhost -x -b ou=Groups,${A1_BASE_DN} cn gidNumber 2>&1)"
  echo "$out" | tee -a "$A1_DETAIL_LOG"
  if contains_all "$out" "gidNumber: 7100" "gidNumber: 7200" "gidNumber: 7300"; then pass "A4.3" "0.25" "LDAP groups OK"; else fail "A4.3" "0.25" "LDAP groups missing/wrong"; fi

  out="$(ldapsearch -H ldap://localhost -x -b ou=People,${A1_BASE_DN} uid uidNumber gidNumber loginShell 2>&1)"
  echo "$out" | tee -a "$A1_DETAIL_LOG"
  if contains_all "$out" "uidNumber: 8101" "uidNumber: 8102" "uidNumber: 8103" "loginShell: /bin/bash"; then pass "A4.4" "0.25" "LDAP users OK"; else fail "A4.4" "0.25" "LDAP users missing/wrong"; fi

  out="$(ldapsearch -H ldap://localhost -x -b ou=People,${A1_BASE_DN} uid 2>&1; ldapsearch -H ldap://localhost -x -b ${A1_BASE_DN} userPassword 2>&1)"
  echo "$out" | tee -a "$A1_DETAIL_LOG"
  if ! echo "$out" | grep -q "userPassword:" && ! echo "$out" | grep -q "uid: amina"; then pass "A4.5" "0.25" "anonymous bind restriction OK"; else fail "A4.5" "0.25" "anonymous bind exposes protected data"; fi

  out="$(ss -lntu | grep ':514' || true; systemctl is-active rsyslog 2>/dev/null || true)"
  echo "$out" | tee -a "$A1_DETAIL_LOG"
  if echo "$out" | grep -q "active" && echo "$out" | grep -q ":514"; then pass "A8.1" "0.25" "central syslog receiver active/listening"; else fail "A8.1" "0.25" "central syslog receiver inactive/not listening"; fi
}

check_sssd_client() {
  section "SSSD client checks on $HN"
  out="$(systemctl is-active sssd 2>/dev/null || true; getent passwd amina; getent passwd daryn; getent passwd timur; getent group developers; getent group operators; getent group linuxadmins)"
  echo "$out" | tee -a "$A1_DETAIL_LOG"
  if contains_all "$out" "active" "amina" "daryn" "timur" "developers" "operators" "linuxadmins"; then pass "LOCAL.SSSD" "0" "SSSD users/groups visible"; else fail "LOCAL.SSSD" "0" "SSSD users/groups incomplete"; fi

  out="$(id amina 2>&1; id daryn 2>&1; id timur 2>&1)"
  echo "$out" | tee -a "$A1_DETAIL_LOG"
  if contains_all "$out" "developers" "operators" "linuxadmins"; then pass "A4.9" "0.25" "group membership visible on $HN"; else fail "A4.9" "0.25" "group membership incomplete on $HN"; fi
}

check_files() {
  section "FILES-A1 - NFS and Samba"
  check_sssd_client
  out="$(ls -ld /srv/nfs/projects /srv/samba/projects 2>&1; getfacl -p /srv/nfs/projects /srv/samba/projects 2>/dev/null || true)"
  echo "$out" | tee -a "$A1_DETAIL_LOG"
  if contains_all "$out" "developers" "operators"; then pass "A6.1" "0.25" "file permissions mention required LDAP groups"; else fail "A6.1" "0.25" "file permissions/ACL do not show required groups"; fi

  out="$(exportfs -v; ss -lntp | grep ':2049' || true)"
  echo "$out" | tee -a "$A1_DETAIL_LOG"
  if echo "$out" | grep -q "/srv/nfs/projects" && echo "$out" | grep -q ":2049"; then pass "A6.2" "0.25" "NFS export/TCP2049 OK"; else fail "A6.2" "0.25" "NFS export/TCP2049 missing"; fi

  out="$(systemctl is-active smbd nmbd 2>/dev/null || true; testparm -s 2>/dev/null | sed -n '/\\[projects\\]/,/\\[/p')"
  echo "$out" | tee -a "$A1_DETAIL_LOG"
  if echo "$out" | grep -q "projects"; then pass "A6.SAMBA.LOCAL" "0" "Samba projects share configured"; else fail "A6.SAMBA.LOCAL" "0" "Samba projects share missing"; fi
}

check_web() {
  section "WEB-A1 - HTTP/HTTPS"
  out="$(systemctl is-active nginx apache2 2>/dev/null || true; ss -lntp | grep -E ':80|:443' || true)"
  echo "$out" | tee -a "$A1_DETAIL_LOG"
  if echo "$out" | grep -q "active" && echo "$out" | grep -q ":80" && echo "$out" | grep -q ":443"; then pass "A5.LOCAL.SERVICE" "0" "web service active/listening"; else fail "A5.LOCAL.SERVICE" "0" "web service/listening incomplete"; fi

  out="$(curl -sS http://127.0.0.1/ 2>&1; echo; curl -k -sS https://127.0.0.1/ 2>&1; echo; curl -sS http://127.0.0.1/healthz 2>&1)"
  echo "$out" | tee -a "$A1_DETAIL_LOG"
  if contains_all "$out" "A1_WEB_HTTP_OK" "A1_WEB_HTTPS_OK" "OK"; then pass "A5.LOCAL.CONTENT" "0" "local web content OK"; else fail "A5.LOCAL.CONTENT" "0" "local web content wrong"; fi
}

check_client_mounts() {
  section "CLIENT - service access from $HN"
  check_sssd_client
  out="$(dig @${A1_DNS_IP} www.${A1_DOMAIN} A +short 2>&1; curl -sS http://www.${A1_DOMAIN}/healthz 2>&1; curl -sS https://www.${A1_DOMAIN}/healthz 2>&1)"
  echo "$out" | tee -a "$A1_DETAIL_LOG"
  if echo "$out" | grep -q "10.11.40.20" && [ "$(echo "$out" | grep -c '^OK$')" -ge 2 ]; then pass "LOCAL.CLIENT.WEB" "0" "DNS and web health OK from $HN"; else warn "LOCAL.CLIENT.WEB" "0" "DNS/web health not fully OK from $HN"; fi

  if [ "$HN" = "sz-client-a1" ]; then
    out="$(findmnt /mnt/projects; cat /mnt/projects/a1-nfs-ok.txt 2>/dev/null; smbclient -L //files.${A1_DOMAIN} -U amina%${A1_PASS} 2>&1 | grep projects || true)"
    echo "$out" | tee -a "$A1_DETAIL_LOG"
    echo "$out" | grep -q "A1_NFS_OK" && pass "A6.3" "0.50" "NFS persistent mount OK on sz-client" || fail "A6.3" "0.50" "NFS persistent mount missing on sz-client"
    echo "$out" | grep -q "projects" && pass "A6.6" "0.25" "Samba authenticated share visible from sz-client" || fail "A6.6" "0.25" "Samba share not visible from sz-client"
  fi

  if [ "$HN" = "sh-client-a1" ]; then
    out="$(ls /net/projects 2>&1; cat /net/projects/a1-nfs-ok.txt 2>/dev/null)"
    echo "$out" | tee -a "$A1_DETAIL_LOG"
    echo "$out" | grep -q "A1_NFS_OK" && pass "A6.4" "0.50" "NFS autofs OK on sh-client" || fail "A6.4" "0.50" "NFS autofs missing on sh-client"
  fi
}

case "$HN" in
  sh-gw-a1|sz-gw-a1)
    check_common
    check_gateway
    ;;
  id-a1)
    check_common
    check_id
    ;;
  files-a1)
    check_common
    check_files
    ;;
  web-a1)
    check_common
    check_web
    ;;
  sh-client-a1|sz-client-a1)
    check_common
    check_client_mounts
    ;;
  *)
    check_common
    warn "LOCAL.UNKNOWN" "0" "unknown host role: $HN; only common checks executed"
    ;;
esac

write_summary
echo -e "${CYAN}Local check completed on $HN. Reports: $A1_REPORT_DIR${NC}"
