# D1_new PNETLab push tools

Two scripts that push `D1_new`'s Cisco `.ios` files straight into a running
PNETLab lab's device consoles - the same TCP-console mechanism the C1-C4
checkers (`C1/pnetlab_lib.py`, `C1/checker_lib.py`) use to run `show`
commands, just used here to paste configuration instead of reading it.

**Network devices only.** No Windows/Linux host is touched by these
scripts - apply `Clean_Baseline_Scripts/windows`, `/linux` and
`Day2_Fault_Scripts/windows`, `/linux` from inside each VM as documented in
`Clean_Baseline_Scripts/docs/RUN_ORDER.md` and
`Day2_Fault_Scripts/orchestration/APPLY_DAY2_ALL_BY_HOST.md`.

## Scripts

- `apply_clean_baseline_network.py` - pastes all 11
  `Clean_Baseline_Scripts/cisco/*_clean_baseline.ios` files (Internet, MPLS,
  DC1, DC2, DC-GW, Switch, HQ-GW1, HQ-GW2, HQ-SW, HQ-SW-D, HQ-R) in
  deployment order.
- `apply_day2_faults_network.py` - pastes the 4
  `Day2_Fault_Scripts/cisco/day2/*_apply_day2_matched_faults.ios` files
  (DC-GW, DC2, HQ-GW1, HQ-GW2) that carry the Day 2 network-side tickets
  (T04, T06, T08, T09).

Both share `d1_pnetlab_push.py`, which reuses `C1/pnetlab_lib.py` +
`C1/checker_lib.py` (login, PNETLab session join, node-to-console mapping,
`IOSConsoleSession`) rather than reimplementing them.

## Setup

1. Fix `pnet_url` and credentials in `creds.json` if needed (same shape as
   `C1/creds.json`..`C4/creds.json`; `device_username`/`device_password`
   are unused by this baseline's `line con 0`, which has no login, but are
   kept for parity and in case an image requires one).
2. Install dependencies:

   ```powershell
   py -m pip install -r .\D1_new\tools\requirements.txt
   ```

## Running

```powershell
# See exactly what would be pasted, without touching PNETLab:
py .\D1_new\tools\apply_clean_baseline_network.py --dry-run

# Apply the clean baseline (prompts to pick the running lab session,
# then asks for a final yes/no confirmation before sending anything):
py .\D1_new\tools\apply_clean_baseline_network.py

# Skip lab picking (you already know the PNETLab session id) and skip the
# confirmation prompt:
py .\D1_new\tools\apply_clean_baseline_network.py --session-id 4 --yes

# Only one or two devices:
py .\D1_new\tools\apply_clean_baseline_network.py --device DC-GW --device Switch

# Same options for the Day 2 faults, applied AFTER the baseline has been
# restored from its snapshot:
py .\D1_new\tools\apply_day2_faults_network.py --dry-run
py .\D1_new\tools\apply_day2_faults_network.py --session-id 4 --yes
```

`--lab` (default `D1`) is the substring used to find the running PNETLab
session when `--session-id` is not given - same selection flow as
`C4/c4_check_ios.py --session-id`.

## What each push actually does

For every target device, the script:

1. Opens the same TCP console `IOSConsoleSession` the checkers use.
2. Reads the device's `.ios` file. `Clean_Baseline_Scripts` files don't
   include `configure terminal` themselves (they assume it's typed by hand
   before pasting, per `docs/RUN_ORDER.md`), so the script prepends it;
   `Day2_Fault_Scripts` files already start with `configure terminal` and
   are sent as-is.
3. Pastes the whole file as one multi-line console paste (each line sent
   and waited on, same as `checker_lib._send_ios_command` already does
   internally for shorter multi-line pushes) - the file's own trailing
   `end` / `write memory` finishes the job and saves it.
4. Scans the console transcript for `% Invalid input` / `% Ambiguous` /
   `% Incomplete` and for the `write memory` `[OK]` marker, and reports
   PASS/FAIL per device in a summary table.

## Safety

This is **not** read-only, unlike the C1-C4 checkers - it changes live
device configuration. The script always shows exactly which devices/files
are targeted and asks for an explicit `yes` before connecting, unless
`--yes` is passed. Use `--dry-run` first if you just want to review the
config that would be sent.
