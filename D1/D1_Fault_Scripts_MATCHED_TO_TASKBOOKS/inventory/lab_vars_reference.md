# D1 lab variable reference

These fault scripts are matched to the current Day 1 and Day 2 taskbooks, but they are written for the clean snapshot created from `D1_Clean_Baseline_Scripts`.

Default addressing used by the scripts:

| Role | Default value |
|---|---|
| HQ-WS01 | 10.19.10.11 |
| HQ-AD01 | 10.19.20.10 |
| HQ-FILE01 | 10.19.20.20 |
| HQ-LNX01 | 10.19.20.30 |
| DC-LNX01 | 10.19.110.11 |
| DC-LNX02 | 10.19.110.12 |
| DC-CL01 | 10.19.120.11 |
| DC-Win01 | 10.19.110.21 |
| DC-SVC01 | 10.19.110.31 |
| Cloud service loopback | 10.19.210.1 |
| Cloud backup loopback | 10.19.220.1 |

The styled taskbooks display the simplified `skill39.d1` names. To make the faults useful on the clean baseline, Windows DNS fault scripts touch both:

- `skill39.d1` taskbook names, for example `dc-lnx01.skill39.d1`;
- `dc.d1.skills` / `corp.d1.skills` clean-baseline names, where applicable.

If your live clean snapshot uses the newer 10.21.10.0/24 DC addressing instead of 10.19.110.0/24 and 10.19.120.0/24, adjust the IP variables at the top of the Windows/Linux scripts and Cisco ACL statements before applying.
