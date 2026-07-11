#!/usr/bin/env bash
# Скопировать пакет A2 на все A2-хосты, если SSH-доступ работает.
# Run from the package root.
set -euo pipefail

HOSTS=(
  root@10.22.10.1
  root@10.22.10.20
  root@10.22.20.1
  root@10.22.20.20
  root@10.22.30.10
  root@10.22.40.10
  root@10.22.40.20
)

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
PKG="$(basename "$PWD")"
DEST="/root/$PKG"

for h in "${HOSTS[@]}"; do
  echo "Копирование пакета на $h:$DEST"
  ssh "${SSH_OPTS[@]}" "$h" "rm -rf '$DEST' && mkdir -p '$DEST'"
  tar -C "$(dirname "$PWD")" -czf - "$PKG" | ssh "${SSH_OPTS[@]}" "$h" "tar -C /root -xzf -"
done

echo "Готово."
