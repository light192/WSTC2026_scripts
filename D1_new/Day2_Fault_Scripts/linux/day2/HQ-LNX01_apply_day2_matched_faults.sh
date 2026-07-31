#!/usr/bin/env bash
set -euo pipefail
# T05: DC-LNX02 cannot SSH to HQ-LNX01; ping succeeds.
# The rule is saved via netfilter-persistent so it survives a VM reboot
# (iptables-persistent is installed by 00_d1_linux_common_prepare.sh).

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

apt-get update || true
apt-get install -y iptables iptables-persistent openssh-server || true
systemctl enable --now ssh || systemctl enable --now sshd || true

while iptables -C INPUT -s 10.21.10.20/32 -p tcp --dport 22 -j REJECT --reject-with tcp-reset 2>/dev/null; do
  iptables -D INPUT -s 10.21.10.20/32 -p tcp --dport 22 -j REJECT --reject-with tcp-reset
done
iptables -I INPUT 1 -s 10.21.10.20/32 -p tcp --dport 22 -j REJECT --reject-with tcp-reset

netfilter-persistent save || (mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4)
systemctl enable netfilter-persistent || true

echo "T05 fault applied on HQ-LNX01: TCP/22 rejected from DC-LNX02 (10.21.10.20); ICMP remains allowed. Rule persisted across reboot."
