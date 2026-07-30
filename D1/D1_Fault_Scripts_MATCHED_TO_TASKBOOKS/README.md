# D1 fault injection scripts — matched to Day 1 and Day 2 taskbooks

This package replaces the previous mismatched fault injection scripts.

Use with the already created clean snapshot from `D1_Clean_Baseline_Scripts`:

1. Restore all devices and VMs to `D1-CLEAN`.
2. For Day 1, apply `orchestration/APPLY_DAY1_ALL_BY_HOST.md`.
3. For Day 2, restore back to `D1-CLEAN`, then apply `orchestration/APPLY_DAY2_ALL_BY_HOST.md`.
4. Do not combine Day 1 and Day 2 fault sets.
5. Validate symptoms using the files in `validation/`.

The scripts intentionally create symptoms matching the competitor taskbooks, not the earlier outdated fault map.

Important: These scripts are designed for a training lab. Cisco interface names and Windows/Linux service names must still be checked against the live PNETLab images before the official run.
