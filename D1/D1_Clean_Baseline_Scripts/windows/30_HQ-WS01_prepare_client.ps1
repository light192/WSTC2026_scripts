# Чистая базовая конфигурация D1: клиент HQ-WS01.
# Запустите от имени администратора после общей подготовки.
New-Item -ItemType Directory -Path C:\D1-Baseline -Force | Out-Null
@'
Resolve-DnsName hq-ad01.corp.d1.skills
Resolve-DnsName dc-lnx01.dc.d1.skills
Test-NetConnection 10.19.20.10 -Port 53
Test-NetConnection dc-lnx01.dc.d1.skills -Port 80
'@ | Set-Content C:\D1-Baseline\client-checks.ps1
'D1_HQ_WS01_READY' | Set-Content C:\D1-Baseline\client-ready.txt
