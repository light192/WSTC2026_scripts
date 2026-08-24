# D1 clean-baseline deployment order

This baseline's addressing matches `D1_Day2_Competitor_Task_EN_styled.pdf`
exactly — see `docs/ADDRESSING_NOTES.md` for the handful of gaps the PDF
leaves open and how they were filled in.

## 1. Cisco network devices

Paste/import the configs in this order:

1. `Internet_clean_baseline.ios`
2. `MPLS_clean_baseline.ios`
3. `DC1_clean_baseline.ios`
4. `DC2_clean_baseline.ios`
5. `DC-GW_clean_baseline.ios`
6. `Switch_clean_baseline.ios`
7. `HQ-GW1_clean_baseline.ios`
8. `HQ-GW2_clean_baseline.ios`
9. `HQ-SW_clean_baseline.ios`
10. `HQ-SW-D_clean_baseline.ios`
11. `HQ-R_clean_baseline.ios`

After applying the network configs, verify OSPF neighbors and routing tables
before configuring the servers (see `validation/validate_cisco_clean_baseline.txt`).

## 2. Windows nodes

Run PowerShell as Administrator:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\00_D1_common_windows_prepare.ps1 -NodeName HQ-AD01
# If the computer name changed, reboot, then run:
.\10_HQ-AD01_prepare_ad_dns_ntp.ps1
# Install-ADDSForest reboots the server; after that reboot, run
# 10_HQ-AD01_prepare_ad_dns_ntp.ps1 again to finish DNS records + NTP.
```

Then the remaining Windows nodes:

```powershell
.\00_D1_common_windows_prepare.ps1 -NodeName HQ-FILE01
.\20_HQ-FILE01_prepare_file.ps1

.\00_D1_common_windows_prepare.ps1 -NodeName HQ-WS01
.\30_HQ-WS01_prepare_client.ps1

.\00_D1_common_windows_prepare.ps1 -NodeName DC-Win01
.\40_DC-Win01_prepare_app.ps1
```

## 3. Debian nodes

If you deliver these scripts to the VM as a mounted **read-only** ISO
(`mount /dev/cdrom /mnt` or similar), don't run them with `./script.sh` or
`bash script.sh` directly - if the copy on the ISO ever picked up Windows
line endings (CRLF) during authoring, bash on Debian fails with a `syntax
error near unexpected token` and there is no way to fix it in place on a
read-only medium. Instead, always stream the file through `tr -d '\r'`
first - this works identically whether the file is clean or not, and never
needs write access to the mounted file:

```bash
D1=/mnt/Clean_Baseline_Scripts/linux   # adjust to your actual mount point

tr -d '\r' <"$D1/00_d1_linux_common_prepare.sh" | sudo bash -s -- DC-LNX01
tr -d '\r' <"$D1/10_DC-LNX01_prepare_web_portal.sh" | sudo bash -s --
```

Use the script matching each node's name/role:

- `DC-LNX01` → intranet web portal;
- `DC-LNX02` → DNS/utility (forwarding resolver for the DC side);
- `DC-SVC01` → Service Desk / monitoring / app;
- `DC-CL01` → DC test client;
- `HQ-LNX01` → web/SSH/syslog client.

Full command set for all five Debian nodes:

```bash
D1=/mnt/Clean_Baseline_Scripts/linux

tr -d '\r' <"$D1/00_d1_linux_common_prepare.sh" | sudo bash -s -- DC-LNX01
tr -d '\r' <"$D1/10_DC-LNX01_prepare_web_portal.sh" | sudo bash -s --

tr -d '\r' <"$D1/00_d1_linux_common_prepare.sh" | sudo bash -s -- DC-LNX02
tr -d '\r' <"$D1/20_DC-LNX02_prepare_dns_utility.sh" | sudo bash -s --

tr -d '\r' <"$D1/00_d1_linux_common_prepare.sh" | sudo bash -s -- DC-SVC01
tr -d '\r' <"$D1/30_DC-SVC01_prepare_servicedesk.sh" | sudo bash -s --

tr -d '\r' <"$D1/00_d1_linux_common_prepare.sh" | sudo bash -s -- DC-CL01
tr -d '\r' <"$D1/50_DC-CL01_prepare_client.sh" | sudo bash -s --

tr -d '\r' <"$D1/00_d1_linux_common_prepare.sh" | sudo bash -s -- HQ-LNX01
tr -d '\r' <"$D1/40_HQ-LNX01_prepare_web_ssh_syslog.sh" | sudo bash -s --
```

(On a writable copy - e.g. you already `cp`'d the ISO contents to local
disk - the plain `sudo bash 00_d1_linux_common_prepare.sh DC-LNX01` form
works too, as long as the copy itself is confirmed CRLF-free.)

## 4. Verification

- **Cisco** - `validation/validate_cisco_clean_baseline.txt` is not a single
  script; each section names the device(s) it targets. In short:
  - routing/OSPF/CDP/ping section → `Internet`, `MPLS`, `DC1`, `DC2`,
    `DC-GW`, `HQ-GW1`, `HQ-GW2`, `HQ-SW-D`, `HQ-R`;
  - `show standby brief` section → `HQ-GW1`, `HQ-GW2` only;
  - VLAN/trunk/STP section → `HQ-SW` and `Switch` (the DC access switch)
    only;
  - sourced traceroutes → `HQ-GW1` and `HQ-GW2` only (see the file for
    which traceroute goes on which).

- **Linux** - `validate_linux_clean_baseline.sh` is generic; run it on
  **every** Debian node (it reports the view from wherever it runs, and DC
  vs. HQ nodes are expected to show different resolvers):
  `DC-LNX01`, `DC-LNX02`, `DC-SVC01`, `DC-CL01`, `HQ-LNX01`.

  ```bash
  tr -d '\r' <"$D1/../validation/validate_linux_clean_baseline.sh" | bash
  ```

  (same CRLF-safe pattern as section 3 - run this on each of the 5 nodes.)

- **Windows** - `validate_windows_clean_baseline.ps1` is likewise generic;
  run it on **every** Windows node: `HQ-AD01`, `HQ-FILE01`, `HQ-WS01`,
  `DC-Win01`.

Do not apply any Day 2 fault script until every check above passes on every
listed node and a snapshot has been taken (see `WHAT_TO_SNAPSHOT.md`).
