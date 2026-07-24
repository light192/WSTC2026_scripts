#!/usr/bin/env bash
# Copy this package from maint-a4 to every A4 node using root SSH keys.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST="${A4_REMOTE_PACKAGE_DIR:-/root/A4}"
for ip in 10.44.10.1 10.44.10.20 10.44.20.1 10.44.20.20 10.44.30.10 10.44.40.10 10.44.40.20; do
  echo "== $ip =="
  ssh -o BatchMode=yes root@"$ip" "mkdir -p '$DEST'"
  tar -C "$PACKAGE_DIR" -cf - . | ssh -o BatchMode=yes root@"$ip" "tar -C '$DEST' -xf -"
done
