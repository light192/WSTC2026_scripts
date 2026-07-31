#!/usr/bin/env bash
set -euo pipefail

# Common D1 clean-baseline prep for Linux nodes.
# Usage: sudo ./00_d1_linux_common_prepare.sh <NODE_NAME>
# Supported node names: DC-LNX01 DC-LNX02 DC-SVC01 DC-CL01 HQ-LNX01
# Addressing matches D1_Day2_Competitor_Task_EN_styled.pdf exactly; single DNS
# suffix skill39.d1 is used for every host (see docs/ADDRESSING_NOTES.md).

HOSTNAME_ARG="${1:-}"
if [[ -z "$HOSTNAME_ARG" ]]; then
  echo "Usage: $0 <NODE_NAME>" >&2
  exit 2
fi

case "$HOSTNAME_ARG" in
  DC-LNX01) IP4="10.21.10.10/24"; GW4="10.21.10.1"; DNS4="10.21.10.20 10.19.20.10" ;;
  DC-LNX02) IP4="10.21.10.20/24"; GW4="10.21.10.1"; DNS4="127.0.0.1 10.19.20.10" ;;
  DC-SVC01) IP4="10.21.10.50/24"; GW4="10.21.10.1"; DNS4="10.21.10.20 10.19.20.10" ;;
  DC-CL01)  IP4="10.21.10.30/24"; GW4="10.21.10.1"; DNS4="10.21.10.20 10.19.20.10" ;;
  HQ-LNX01) IP4="10.19.20.30/24"; GW4="10.19.20.1"; DNS4="10.19.20.10 10.21.10.20" ;;
  *) echo "Unsupported node name: $HOSTNAME_ARG" >&2; exit 3 ;;
esac

IFACE="${D1_IFACE:-}"
if [[ -z "$IFACE" ]]; then
  IFACE=$(ip -o link show | awk -F': ' '$2 !~ /lo/ {print $2; exit}')
fi

echo "$HOSTNAME_ARG" > /etc/hostname
hostnamectl set-hostname "$HOSTNAME_ARG" || hostname "$HOSTNAME_ARG"

cat >/etc/hosts <<EOF
127.0.0.1 localhost
${IP4%/*} ${HOSTNAME_ARG,,}.skill39.d1 $HOSTNAME_ARG
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
search skill39.d1
nameserver $(echo "$DNS4" | awk '{print $1}')
nameserver $(echo "$DNS4" | awk '{print $2}')
EOF

export DEBIAN_FRONTEND=noninteractive
apt-get update || true
apt-get install -y curl wget dnsutils bind9-dnsutils netcat-openbsd openssh-server rsyslog chrony ca-certificates || true
systemctl enable --now ssh rsyslog || true
systemctl enable --now chrony || true

# iptables-persistent so that any host-firewall fault injected later on top of
# this baseline (Day 2 T05) survives a VM reboot instead of being lost.
echo "iptables-persistent iptables-persistent/autosave_v4 boolean false" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" | debconf-set-selections
apt-get install -y iptables-persistent || true
systemctl enable netfilter-persistent || true

mkdir -p /opt/grading/d1 /opt/d1-baseline
cat >/opt/d1-baseline/identity.txt <<EOF
hostname=$HOSTNAME_ARG
interface=$IFACE
ipv4=$IP4
gateway=$GW4
dns=$DNS4
EOF

echo "D1 common Linux baseline prepared on $HOSTNAME_ARG, interface $IFACE."
