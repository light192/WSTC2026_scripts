# Image-specific notes

## Cisco IOS / IOSvL2

Configs assume these interface names from the provided topology snapshot:

- `GigabitEthernet0/0` ... `GigabitEthernet0/4` on routers, where shown;
- `GigabitEthernet1/0` and `GigabitEthernet1/1` on access switches, where shown.

If your image uses different interface names, change only the interface
sections. Do not change the logical addressing without updating
`inventory/D1_addressing_table.csv`, `docs/ADDRESSING_NOTES.md`, and the
Day 2 fault scripts to match.

`HQ-SW-D` is configured as an L3 switch (`ip routing`, routed ports to
HQ-R). If your switch image doesn't support `ip routing`/`no switchport`,
replace it with a router image or adapt the design.

`DC1`/`DC2` need `ip http server` (DC1) and SSH (DC2, already enabled via
the shared header) reachable on their loopbacks for tickets T04/T08 to have
a concrete "cloud service"/"cloud backup target" to test against — see
`docs/ADDRESSING_NOTES.md`.

## Debian

The Linux scripts auto-detect the first non-loopback interface. Override it
if needed:

```bash
D1_IFACE=ens3 ./00_d1_linux_common_prepare.sh DC-LNX01
```

`00_d1_linux_common_prepare.sh` installs `iptables-persistent` on every
Debian node so that host-firewall faults applied later (Day 2 T05) survive
a reboot. If your image ships without `debconf-set-selections` /
`netfilter-persistent`, install and enable them manually before relying on
any iptables-based fault.

## Windows

The Windows scripts use the first active adapter. If a VM has multiple
adapters, check the intended one manually before running the common script.

`Install-ADDSForest` on HQ-AD01 reboots the server automatically. Re-run
`10_HQ-AD01_prepare_ad_dns_ntp.ps1` after that reboot to finish DNS records
and NTP configuration — the script detects whether the forest already
exists and skips straight to that step.
