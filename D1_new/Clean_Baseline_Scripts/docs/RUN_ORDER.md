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

Run on each Debian node as root:

```bash
./00_d1_linux_common_prepare.sh DC-LNX01
./10_DC-LNX01_prepare_web_portal.sh
```

Use the script matching each node's name/role:

- `DC-LNX01` → intranet web portal;
- `DC-LNX02` → DNS/utility (forwarding resolver for the DC side);
- `DC-SVC01` → Service Desk / monitoring / app;
- `DC-CL01` → DC test client;
- `HQ-LNX01` → web/SSH/syslog client.

## 4. Verification

Run:

- Cisco: commands in `validation/validate_cisco_clean_baseline.txt`;
- Linux: `validation/validate_linux_clean_baseline.sh`;
- Windows: `validation/validate_windows_clean_baseline.ps1`.

Do not apply any Day 2 fault script until every check above passes and a
snapshot has been taken (see `WHAT_TO_SNAPSHOT.md`).
