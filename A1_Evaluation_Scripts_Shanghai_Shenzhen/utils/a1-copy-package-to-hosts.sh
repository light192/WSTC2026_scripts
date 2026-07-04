#!/usr/bin/env bash
# Copy local checker to all A1 hosts when SSH connectivity exists.
# Run from the package root.
set -euo pipefail

HOSTS=(
  root@10.11.10.1
  root@10.11.10.20
  root@10.11.20.1
  root@10.11.20.20
  root@10.11.30.10
  root@10.11.40.10
  root@10.11.40.20
)

for h in "${HOSTS[@]}"; do
  echo "Copying package to $h:/root/A1_Evaluation_Scripts_Shanghai_Shenzhen"
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$h" 'rm -rf /root/A1_Evaluation_Scripts_Shanghai_Shenzhen && mkdir -p /root/A1_Evaluation_Scripts_Shanghai_Shenzhen'
  tar -C "$(dirname "$PWD")" -czf - "$(basename "$PWD")" | ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$h" 'tar -C /root -xzf -'
done

echo "Done."
