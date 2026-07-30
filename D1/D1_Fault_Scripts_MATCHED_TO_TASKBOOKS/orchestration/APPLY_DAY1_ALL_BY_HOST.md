# Apply Day 1 faults — all guided tickets at once

Start state: restore every device/VM to snapshot `D1-CLEAN`.

Do **not** apply Day 2 faults together with Day 1 faults.

## Cisco devices

Paste these files into the matching device console:

| Device | File |
|---|---|
| DC-GW | `cisco/day1/DC-GW_apply_day1_matched_faults.ios` |
| HQ-GW1 | `cisco/day1/HQ-GW1_apply_day1_matched_faults.ios` |
| HQ-GW2 | `cisco/day1/HQ-GW2_apply_day1_matched_faults.ios` |
| Internet | `cisco/day1/Internet_apply_day1_matched_faults.ios` |
| HQ-R | `cisco/day1/HQ-R_apply_day1_matched_faults.ios` |

## Linux hosts

Copy and run as root:

| Host | File |
|---|---|
| HQ-LNX01 | `linux/day1/HQ-LNX01_apply_day1_matched_faults.sh` |
| DC-SVC01 | `linux/day1/DC-SVC01_apply_day1_matched_faults.sh` |

Example:

```bash
chmod +x HQ-LNX01_apply_day1_matched_faults.sh
sudo ./HQ-LNX01_apply_day1_matched_faults.sh
```

## Windows hosts

Run PowerShell as Administrator:

| Host | File |
|---|---|
| HQ-FILE01 | `windows/day1/HQ-FILE01_apply_day1_matched_faults.ps1` |
| HQ-WS01 | `windows/day1/HQ-WS01_apply_day1_matched_faults.ps1` |

Example:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\HQ-WS01_apply_day1_matched_faults.ps1
```

## After applying

Use `validation/DAY1_EXPECTED_SYMPTOMS.md` to verify that the intended symptoms are visible.
