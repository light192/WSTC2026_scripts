#!/usr/bin/env bash
# Copy this package from admin-a3 to every A3 node using root SSH keys.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST="${A3_REMOTE_PACKAGE_DIR:-/root/A3}"
for ip in 10.33.10.1 10.33.10.20 10.33.20.1 10.33.20.20 10.33.30.10 10.33.40.10 10.33.40.20; do
  echo "== $ip =="
  ssh -o BatchMode=yes root@"$ip" "mkdir -p '$DEST'"
  tar -C "$PACKAGE_DIR" -cf - . | ssh -o BatchMode=yes root@"$ip" "tar -C '$DEST' -xf -"
done
