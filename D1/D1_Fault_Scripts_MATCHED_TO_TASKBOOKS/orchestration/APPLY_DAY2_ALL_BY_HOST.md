# Apply Day 2 faults — all closed-control tickets at once

Start state: restore every device/VM to snapshot `D1-CLEAN`.

Do **not** apply Day 1 faults together with Day 2 faults.

## Cisco devices

Paste these files into the matching device console:

| Device | File |
|---|---|
| DC-GW | `cisco/day2/DC-GW_apply_day2_matched_faults.ios` |
| HQ-GW1 | `cisco/day2/HQ-GW1_apply_day2_matched_faults.ios` |
| HQ-GW2 | `cisco/day2/HQ-GW2_apply_day2_matched_faults.ios` |
| DC2 | `cisco/day2/DC2_apply_day2_matched_faults.ios` |

## Linux hosts

Copy and run as root:

| Host | File |
|---|---|
| HQ-LNX01 | `linux/day2/HQ-LNX01_apply_day2_matched_faults.sh` |
| DC-SVC01 | `linux/day2/DC-SVC01_apply_day2_matched_faults.sh` |
| DC-LNX02 | `linux/day2/DC-LNX02_apply_day2_matched_faults.sh` |

## Windows hosts

Run PowerShell as Administrator:

| Host | File |
|---|---|
| HQ-AD01 | `windows/day2/HQ-AD01_apply_day2_matched_faults.ps1` |
| DC-Win01 | `windows/day2/DC-Win01_apply_day2_matched_faults.ps1` |
| HQ-FILE01 | `windows/day2/HQ-FILE01_apply_day2_matched_faults.ps1` |

## After applying

Use `validation/DAY2_EXPECTED_SYMPTOMS.md` to verify that the intended symptoms are visible.
