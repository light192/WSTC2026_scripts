# Day 2 expected symptoms quick-check

Run these checks after all Day 2 faults are applied. Addresses/FQDNs are the
taskbook's own (see `Clean_Baseline_Scripts/inventory/D1_addressing_table.csv`).

| Ticket | Quick-check | Expected faulty result |
|---|---|---|
| T01 | From HQ-WS01: `Resolve-DnsName dc-lnx01.skill39.d1`; open `http://dc-lnx01.skill39.d1/`; also check local HQ resources | Resolves to `10.21.10.254` (wrong) and the web page fails; local HQ resources (HQ-FILE01, HQ-AD01) are still reachable. |
| T02 | From DC-Win01: `Test-NetConnection 10.19.20.10 -Port 389`; `Resolve-DnsName hq-ad01.skill39.d1` | AD/DNS/domain traffic to HQ-AD01 fails from DC-Win01. |
| T03 | From HQ-WS01: `ping 10.19.20.20`; open `\\hq-file01\shared` | Ping to HQ-FILE01 (10.19.20.20) succeeds; SMB fails. |
| T04 | From DC-CL01: `dig +short dc1.cloud.skill39.d1`; then `curl http://10.201.1.1/` | DNS resolution succeeds (10.201.1.1); HTTP to the Cloud service fails. |
| T05 | From DC-LNX02: `ping 10.19.20.30`; `ssh 10.19.20.30` | Ping succeeds; SSH is reset/refused. |
| T06 | Shut the Internet-facing interface on HQ-GW1 (Gi0/0) and test HQ users' access to the DC network | HQ-GW2 stays up, but HQ traffic to DC still fails — HSRP does not fail over and/or HQ-GW2 has no WAN route. |
| T07 | Open `http://dc-svc01.skill39.d1:8080/`; submit the form (`POST /submit`) | Page opens; submit returns a proxy/backend error (dead upstream port). |
| T08 | From DC-LNX01: `ssh -p 22 10.201.2.1` or a backup job against it | Local DC connectivity (e.g. to DC-LNX02) works; the Cloud backup target is unreachable. |
| T09 | Locally on the DC network: `curl http://dc-svc01.skill39.d1:8080/healthz`; from HQ-LNX01: same curl | Local DC check passes; the HQ-LNX01 monitoring source fails. |
| T10 | Locally on DC: `dig dc-lnx01.skill39.d1 @127.0.0.1`; from HQ-LNX01 or HQ-WS01, query DC-LNX02 directly: `dig dc-lnx01.skill39.d1 @10.21.10.20` | DC-local recursion works; the recursive query issued directly against DC-LNX02 from an HQ-network source is refused. |
