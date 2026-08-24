#!/usr/bin/env bash
# Copy this package from idm-a5 to every A5 node using root SSH keys.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST="${A5_REMOTE_PACKAGE_DIR:-/root/A5}"
for ip in 10.55.10.1 10.55.10.100 10.55.20.1 10.55.20.100 10.55.30.10 10.55.40.10 10.55.40.20; do
  echo "== $ip =="
  ssh -o BatchMode=yes root@"$ip" "mkdir -p '$DEST'"
  tar -C "$PACKAGE_DIR" -cf - . | ssh -o BatchMode=yes root@"$ip" "tar -C '$DEST' -xf -"
done
