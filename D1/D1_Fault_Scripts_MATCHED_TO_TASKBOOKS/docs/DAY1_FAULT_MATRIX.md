# Day 1 fault matrix — matched to competitor taskbook

Apply these faults only after restoring the lab to snapshot `D1-CLEAN`.

| Ticket | Taskbook symptom | Injected fault | Host/device | Primary expected answer |
|---|---|---|---|---|
| G01 | HQ-WS01 cannot open `http://dc-lnx01.skill39.d1`; ping to local gateway succeeds | ACL blocks only HQ-WS01 HTTP to DC-LNX01 | DC-GW | Remove/fix the ACL on DC-GW Gi0/2.110 so HQ-WS01 can reach DC-LNX01 TCP/80. |
| G02 | DC-CL01 cannot open `\hq-file01\shared`; local DC services remain reachable | Windows Firewall blocks SMB from DC subnets to HQ-FILE01 | HQ-FILE01 | Remove/fix the blocking SMB firewall rule on HQ-FILE01. |
| G03 | Logs from HQ-LNX01 do not appear on DC-SVC01 | rsyslog forwarding target on HQ-LNX01 points to a wrong port/destination | HQ-LNX01 | Correct `/etc/rsyslog.d/60-d1-remote.conf` to forward to DC-SVC01 UDP/TCP 514 and restart rsyslog. |
| G04 | HQ-WS01 sign-in is slow and GPO applies inconsistently | Client time on HQ-WS01 is skewed and time service points to an invalid peer | HQ-WS01 | Restore time sync to HQ-AD01/domain hierarchy and resync. |
| G05 | Cloud DC reachable from DC but not from HQ | Internet router ACL blocks HQ subnets to Cloud loopbacks | Internet | Remove/fix the HQ-to-Cloud ACL on Internet Gi0/3 and Gi0/4. |
| G06 | MPLS is not preferred path for internal DC traffic | OSPF costs make Internet lower-cost than MPLS | HQ-GW1, HQ-GW2, DC-GW | Restore MPLS OSPF cost lower than Internet. |
| G07 | HQ-AD01 cannot SSH to HQ-R, physical HQ-SW-D links are up | VTY access-class on HQ-R blocks HQ-AD01 | HQ-R | Remove/fix VTY access-class on HQ-R or permit HQ-AD01. |
| G08 | DC-SVC01 Service Desk opens from DC but is intermittently unreachable from HQ | iptables random drop for HQ sources to DC-SVC01 TCP/8080 | DC-SVC01 | Remove path-specific firewall random-drop rules for HQ subnets. |
