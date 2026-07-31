# What to snapshot after building the D1 clean baseline

Only snapshot/checkpoint after every check in
`validation/validate_*` has passed.

Recommended snapshot name:

`D1-CLEAN-PDF-MATCHED`

Snapshot every node:

- Cisco: export the startup-config or save the PNETLab node checkpoints;
- Windows: checkpoint after AD DS/DNS has fully settled and every A record
  in `10_HQ-AD01_prepare_ad_dns_ntp.ps1` resolves;
- Debian: checkpoint after all services are enabled and the validation
  script passes.

Do not apply any Day 2 fault script before this snapshot exists — restore
to it, then apply `Day2_Fault_Scripts`, for every competitor run.
