#!/usr/bin/env bash
set -euo pipefail

# Общая подготовка чистой базовой конфигурации D1 для Linux.
# Использование: sudo ./00_d1_linux_common_prepare.sh <ИМЯ_УЗЛА>
# Поддерживаемые имена узлов: DC-LNX01 DC-LNX02 DC-SVC01 DC-CL01 HQ-LNX01

HOSTNAME_ARG="${1:-}"
if [[ -z "$HOSTNAME_ARG" ]]; then
  echo "Использование: $0 <ИМЯ_УЗЛА>" >&2
  exit 2
fi

case "$HOSTNAME_ARG" in
  DC-LNX01) IP4="10.19.110.11/24"; GW4="10.19.110.1"; DNS4="10.19.20.10 10.19.110.12" ;;
  DC-LNX02) IP4="10.19.110.12/24"; GW4="10.19.110.1"; DNS4="10.19.20.10 127.0.0.1" ;;
  DC-SVC01) IP4="10.19.110.31/24"; GW4="10.19.110.1"; DNS4="10.19.20.10 10.19.110.12" ;;
  DC-CL01) IP4="10.19.120.11/24"; GW4="10.19.120.1"; DNS4="10.19.20.10 10.19.110.12" ;;
  HQ-LNX01) IP4="10.19.20.30/24"; GW4="10.19.20.1"; DNS4="10.19.20.10 10.19.110.12" ;;
  *) echo "Неподдерживаемое имя узла: $HOSTNAME_ARG" >&2; exit 3 ;;
esac

IFACE="${D1_IFACE:-}"
if [[ -z "$IFACE" ]]; then
  IFACE=$(ip -o link show | awk -F': ' '$2 !~ /lo/ {print $2; exit}')
fi

echo "$HOSTNAME_ARG" > /etc/hostname
hostnamectl set-hostname "$HOSTNAME_ARG" || hostname "$HOSTNAME_ARG"

cat >/etc/hosts <<EOF
127.0.0.1 localhost
$([[ "$HOSTNAME_ARG" == HQ-* ]] && echo "${IP4%/*} ${HOSTNAME_ARG,,}.corp.d1.skills $HOSTNAME_ARG" || true)
$([[ "$HOSTNAME_ARG" == DC-* ]] && echo "${IP4%/*} ${HOSTNAME_ARG,,}.dc.d1.skills $HOSTNAME_ARG" || true)
EOF

if command -v nmcli >/dev/null 2>&1 && nmcli -t -f NAME,DEVICE con show --active | grep -q ":$IFACE"; then
  CONN=$(nmcli -t -f NAME,DEVICE con show --active | awk -F: -v i="$IFACE" '$2==i{print $1; exit}')
  nmcli con mod "$CONN" ipv4.addresses "$IP4" ipv4.gateway "$GW4" ipv4.dns "$DNS4" ipv4.method manual
  nmcli con up "$CONN"
else
  mkdir -p /etc/network/interfaces.d
  cat >/etc/network/interfaces.d/d1-baseline.cfg <<EOF
allow-hotplug $IFACE
iface $IFACE inet static
    address ${IP4%/*}
    netmask 255.255.255.0
    gateway $GW4
EOF
  ip addr flush dev "$IFACE" || true
  ip addr add "$IP4" dev "$IFACE"
  ip link set "$IFACE" up
  ip route replace default via "$GW4"
fi

cat >/etc/resolv.conf <<EOF
search corp.d1.skills dc.d1.skills cloud.d1.skills
nameserver $(echo "$DNS4" | awk '{print $1}')
nameserver $(echo "$DNS4" | awk '{print $2}')
EOF

export DEBIAN_FRONTEND=noninteractive
apt-get update || true
apt-get install -y curl wget dnsutils bind9-dnsutils netcat-openbsd openssh-server rsyslog chrony ca-certificates || true
systemctl enable --now ssh rsyslog || true
systemctl enable --now chrony || true

mkdir -p /opt/grading/d1 /opt/d1-baseline
cat >/opt/d1-baseline/identity.txt <<EOF
hostname=$HOSTNAME_ARG
interface=$IFACE
ipv4=$IP4
gateway=$GW4
dns=$DNS4
EOF

echo "Общая базовая конфигурация D1 для Linux подготовлена на $HOSTNAME_ARG, интерфейс $IFACE."
