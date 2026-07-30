# Day 1 expected symptoms quick-check

Run these checks after all Day 1 faults are applied.

| Ticket | Quick-check | Expected faulty result |
|---|---|---|
| G01 | From HQ-WS01: `ping 10.19.10.1`; then `curl http://10.19.110.11/` or browser to `http://dc-lnx01...` | Gateway ping succeeds; HTTP to DC-LNX01 fails from HQ-WS01. |
| G02 | From DC-CL01: `smbclient -L //10.19.20.20 -U student` or Windows SMB test | SMB to HQ-FILE01 fails; local DC pings/web still work. |
| G03 | From HQ-LNX01: `logger D1TEST`; on DC-SVC01 check `/var/log/remote/` | New HQ-LNX01 log does not arrive. |
| G04 | On HQ-WS01: `w32tm /query /status` and compare time with HQ-AD01 | Client time is skewed or time source is invalid. |
| G05 | From DC-LNX01: reach Cloud loopback/service; from HQ-LNX01/HQ-WS01 try same | DC reaches Cloud; HQ cannot. |
| G06 | From HQ host: traceroute/tracert to DC server LAN | Path prefers Internet instead of MPLS. |
| G07 | From HQ-AD01: `ssh expert@<HQ-R management/routed IP>` | SSH to HQ-R fails, while HQ-SW-D links remain up. |
| G08 | From DC host: repeated curl to DC-SVC01:8080; from HQ host: repeated curl to same | DC checks succeed; HQ checks fail intermittently. |

Adjust IPs if your clean baseline uses the newer 10.21.10.0/24 DC addressing.
