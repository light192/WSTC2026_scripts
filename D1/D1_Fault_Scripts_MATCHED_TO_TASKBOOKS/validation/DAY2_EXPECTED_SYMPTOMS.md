# Day 2 expected symptoms quick-check

Run these checks after all Day 2 faults are applied.

| Ticket | Quick-check | Expected faulty result |
|---|---|---|
| T01 | From HQ-WS01: resolve/open `dc-lnx01.skill39.d1`; also check local HQ resources | dc-lnx01 resolves to a wrong IP or web fails; local HQ resources are otherwise reachable. |
| T02 | From DC-Win01: `Test-NetConnection 10.19.20.10 -Port 389`, `Resolve-DnsName hq-ad01...` | AD/DNS/domain traffic to HQ-AD01 fails from DC-Win01. |
| T03 | From HQ-WS01: `ping 10.19.20.20`; open `\hq-file01\shared` | Ping succeeds; SMB fails. |
| T04 | From DC-CL01: resolve Cloud name; then ping/curl Cloud IP/service | DNS resolution succeeds; Cloud reachability fails. |
| T05 | From DC-LNX02: `ping 10.19.20.30`; `ssh 10.19.20.30` | Ping succeeds; SSH fails. |
| T06 | Simulate disabling HQ-GW1 Internet uplink and test HQ users to DC | HQ-GW2 remains up, but failover does not restore access. |
| T07 | Open `http://DC-SVC01:8080/`; POST/open `/submit` | Page opens; submit returns backend/proxy error. |
| T08 | From DC-LNX01: run backup job or test TCP/22/873 to Cloud backup loopback | Local DC connectivity works; Cloud backup target fails. |
| T09 | From DC local host: curl DC-SVC01; from HQ-LNX01: curl DC-SVC01 | Local DC check passes; HQ monitoring source fails. |
| T10 | From DC local host: DC web works; from HQ: local HQ DNS works; query DC-LNX02 recursively from HQ | Local checks work; cross-site recursive DNS is blocked/unstable. |

Adjust IPs if your clean baseline uses the newer 10.21.10.0/24 DC addressing.
