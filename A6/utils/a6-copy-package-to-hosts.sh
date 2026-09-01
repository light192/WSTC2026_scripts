#!/usr/bin/env bash
# Copy this package from ops-a6 to every other A6 node using root SSH keys.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST="${A6_REMOTE_PACKAGE_DIR:-/root/A6}"
for ip in 10.76.10.1 10.76.10.100 10.76.20.1 10.76.30.10 10.76.40.10 10.76.40.20; do
  echo "== $ip =="
  ssh -o BatchMode=yes root@"$ip" "mkdir -p '$DEST'"
  tar -C "$PACKAGE_DIR" -cf - . | ssh -o BatchMode=yes root@"$ip" "tar -C '$DEST' -xf -"
done
