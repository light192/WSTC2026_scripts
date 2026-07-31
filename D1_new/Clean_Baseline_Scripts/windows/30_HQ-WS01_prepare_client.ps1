# D1 clean baseline: HQ-WS01 client. Run as Administrator after the common prep.
New-Item -ItemType Directory -Path C:\D1-Baseline -Force | Out-Null
@'
Resolve-DnsName hq-ad01.skill39.d1
Resolve-DnsName dc-lnx01.skill39.d1
Test-NetConnection 10.19.20.10 -Port 53
Test-NetConnection dc-lnx01.skill39.d1 -Port 80
Test-NetConnection hq-file01.skill39.d1 -Port 445
'@ | Set-Content C:\D1-Baseline\client-checks.ps1
'D1_HQ_WS01_READY' | Set-Content C:\D1-Baseline\client-ready.txt
