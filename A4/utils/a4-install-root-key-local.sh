#!/usr/bin/env bash
# Install the maint-a4 expert public key locally on a target VM.

set -euo pipefail
KEY=""; ALLOW_ROOT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --key) shift; KEY="${1:?missing key}" ;;
    --allow-root-key-login) ALLOW_ROOT=1 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
[ "$(id -u)" -eq 0 ] || { echo "Run as root" >&2; exit 1; }
[[ "$KEY" == ssh-* ]] || { echo "Use --key 'ssh-ed25519 AAAA...'" >&2; exit 2; }
install -d -m 700 -o root -g root /root/.ssh
touch /root/.ssh/authorized_keys
grep -Fqx "$KEY" /root/.ssh/authorized_keys || printf '%s\n' "$KEY" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys; chown root:root /root/.ssh/authorized_keys
if [ "$ALLOW_ROOT" = 1 ]; then
  install -d -m 755 /etc/ssh/sshd_config.d
  printf '%s\n' 'PermitRootLogin prohibit-password' 'PubkeyAuthentication yes' > /etc/ssh/sshd_config.d/99-a4-marking.conf
  sshd -t && systemctl reload ssh
fi
echo "A4 expert key installed on $(hostname -s)"
