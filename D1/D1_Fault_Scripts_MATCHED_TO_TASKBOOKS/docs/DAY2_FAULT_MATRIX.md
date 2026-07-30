# Day 2 fault matrix — matched to competitor taskbook

Apply these faults only after restoring the lab to snapshot `D1-CLEAN`. Do not combine Day 1 and Day 2 faults.

| Ticket | Taskbook symptom | Injected fault | Host/device | Primary expected answer |
|---|---|---|---|---|
| T01 | HQ-WS01 cannot open `dc-lnx01.skill39.d1`; local HQ resources are reachable | HQ DNS record for dc-lnx01 is poisoned/wrong | HQ-AD01 | Correct the A record for `dc-lnx01.skill39.d1` / `dc-lnx01.dc.d1.skills`. |
| T02 | DC-Win01 cannot reach HQ domain resources | Windows Firewall on DC-Win01 blocks outbound AD/DNS/SMB/Kerberos traffic to HQ-AD01 | DC-Win01 | Remove/fix outbound firewall rules to HQ-AD01. |
| T03 | HQ-WS01 can ping HQ-FILE01 but cannot open `\hq-file01\shared` | Windows Firewall on HQ-FILE01 blocks SMB from HQ-WS01 only | HQ-FILE01 | Remove/fix SMB block from HQ-WS01 to HQ-FILE01. |
| T04 | DC-CL01 resolves cloud names but cannot reach cloud service | DC-GW ACL blocks DC-CL01 traffic to Cloud loopbacks | DC-GW | Remove/fix ACL on DC-GW Gi0/0 toward Internet/Cloud. |
| T05 | DC-LNX02 cannot SSH to HQ-LNX01; ping succeeds | Linux firewall on HQ-LNX01 blocks TCP/22 from DC-LNX02 only | HQ-LNX01 | Remove host firewall rule and keep sshd running. |
| T06 | After HQ-GW1 Internet uplink is disabled, HQ users lose access to DC though HQ-GW2 is up | Backup gateway routing/FHRP design is broken: HQ-GW2 WAN OSPF adjacencies are made passive, and HQ-GW1 remains preferred | HQ-GW1, HQ-GW2 | Restore HQ-GW2 WAN OSPF participation and proper HSRP tracking/preempt policy. |
| T07 | DC-SVC01 ticket page opens, but submit reply fails | Nginx page works, but `/submit` proxies to a non-existing backend | DC-SVC01 | Fix application backend/upstream for submit action. |
| T08 | DC-LNX01 backup job to Cloud DC fails while local DC works | DC2 ACL blocks backup protocols from DC-LNX01 to Cloud backup loopback | DC2 | Remove/fix DC2 ACL for DC-LNX01 to Cloud backup TCP/22 or TCP/873. |
| T09 | Local DC check passes, but monitoring from HQ shows DC-SVC01 down | DC-GW ACL blocks HQ-LNX01 monitoring traffic to DC-SVC01 only | DC-GW | Remove/fix path-specific ACL blocking HQ monitor source. |
| T10 | DC web works locally, HQ DNS works locally, but cross-site access is unstable | DC-LNX02 DNS recursion is restricted to DC only, excluding HQ clients | DC-LNX02 | Restore DNS recursion/forwarding policy for HQ and DC networks. |
