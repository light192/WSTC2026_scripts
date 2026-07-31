# D1 clean baseline: DC-Win01 Windows service host (PDF role: "Windows service host").
# Run as Administrator after the common prep.
Install-WindowsFeature Web-Server -IncludeManagementTools
'D1_DC_WIN01_APP_OK' | Set-Content C:\inetpub\wwwroot\index.html
New-Item -ItemType Directory -Path C:\inetpub\wwwroot\healthz -Force | Out-Null
'OK' | Set-Content C:\inetpub\wwwroot\healthz\index.html

New-Item -ItemType Directory -Path C:\D1-Baseline -Force | Out-Null
@'
Test-NetConnection 10.19.20.10 -Port 389
Resolve-DnsName hq-ad01.skill39.d1
'@ | Set-Content C:\D1-Baseline\domain-checks.ps1
'D1_DC_WIN01_READY' | Set-Content C:\D1-Baseline\app-ready.txt
