# Day 2 fault matrix — matched to D1_Day2_Competitor_Task_EN_styled.pdf

Apply these faults only after restoring the lab to the `D1-CLEAN-PDF-MATCHED`
snapshot taken from `Clean_Baseline_Scripts`. Do not combine with Day 1 faults.

Addressing used below is the taskbook's own addressing (see
`Clean_Baseline_Scripts/inventory/D1_addressing_table.csv`) — no translation
or hedging between two addressing schemes is required, unlike the older
`D1_Fault_Scripts_MATCHED_TO_TASKBOOKS` package.

| Ticket | Taskbook symptom | Injected fault | Host/device | Primary expected answer |
|---|---|---|---|---|
| T01 | HQ-WS01 cannot open `dc-lnx01.skill39.d1`; local HQ resources are reachable | HQ-AD01's DNS A record for `dc-lnx01.skill39.d1` is poisoned to `10.21.10.254` | HQ-AD01 | Correct the A record for `dc-lnx01.skill39.d1` back to `10.21.10.10`. |
| T02 | DC-Win01 cannot reach HQ domain resources | Windows Firewall on DC-Win01 blocks outbound AD/DNS/SMB/Kerberos traffic to HQ-AD01 (10.19.20.10) | DC-Win01 | Remove/fix the outbound firewall rules to HQ-AD01. |
| T03 | HQ-WS01 can ping HQ-FILE01 but cannot open `\\hq-file01\shared` | Windows Firewall on HQ-FILE01 blocks SMB (445) from HQ-WS01 (10.19.10.10) only | HQ-FILE01 | Remove/fix the SMB block from HQ-WS01 to HQ-FILE01. |
| T04 | DC-CL01 resolves cloud names but cannot reach the Cloud service | DC-GW ACL on Gi0/0 (toward Internet) blocks DC-CL01 (10.21.10.30) to the Cloud service loopback (10.201.1.1, DC1) | DC-GW | Remove/fix the ACL on DC-GW Gi0/0. |
| T05 | DC-LNX02 cannot SSH to HQ-LNX01; ping succeeds | Linux firewall on HQ-LNX01 rejects TCP/22 from DC-LNX02 (10.21.10.20) only | HQ-LNX01 | Remove the host firewall rule; keep sshd running. |
| T06 | After HQ-GW1's Internet uplink is disabled, HQ users lose access to DC though HQ-GW2 is up | Two causes: (1) HQ-GW1 HSRP tracking of Gi0/0 removed + priority raised, so HQ-GW1 stays HSRP-active even without its Internet uplink; (2) HQ-GW2's WAN OSPF adjacencies are made passive with inflated cost, so it has no route to DC even if it did take over | HQ-GW1, HQ-GW2 | Restore `standby track 1 decrement 20` (object 1 = `track 1 interface GigabitEthernet0/0 line-protocol`) + normal priority on HQ-GW1, and restore HQ-GW2's WAN OSPF participation/cost. |
| T07 | DC-SVC01 ticket page opens, but submitting a reply fails | nginx `/submit` on DC-SVC01 is repointed from the working backend (127.0.0.1:18080) to a dead port (127.0.0.1:19999) | DC-SVC01 | Fix the `/submit` proxy_pass back to the real backend port. |
| T08 | DC-LNX01 backup job to Cloud DC fails while local DC connectivity works | DC2 ACL blocks DC-LNX01 (10.21.10.10) to the Cloud backup loopback (10.201.2.1, DC2) on TCP/22 | DC2 | Remove/fix the DC2 ACL for DC-LNX01 to the cloud backup loopback. |
| T09 | Local DC check passes, but monitoring from HQ shows DC-SVC01 down | DC-GW ACL on Gi0/2 (toward the DC servers) blocks HQ-LNX01 (10.19.20.30) monitoring traffic to DC-SVC01 (10.21.10.50) port 8080 only | DC-GW | Remove/fix the path-specific ACL blocking the HQ monitoring source. |
| T10 | DC web works locally, HQ DNS works locally, but cross-site access is unstable | DC-LNX02's DNS recursion is restricted to the DC network (10.21.10.0/24) only, excluding HQ (10.19.0.0/16) | DC-LNX02 | Restore DNS recursion for HQ networks (`allow-recursion` back to DC + HQ). |
