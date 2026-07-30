# G04: Slow Windows client authentication and inconsistent GPO.
# Run on HQ-WS01 as Administrator.
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Path 'C:\D1-Faults' -Force | Out-Null
Get-Date | Out-File 'C:\D1-Faults\G04-original-time.txt'
w32tm /config /manualpeerlist:'192.0.2.123' /syncfromflags:manual /update | Out-Null
Stop-Service w32time -Force -ErrorAction SilentlyContinue
Set-Date -Date (Get-Date).AddMinutes(11)
Write-Host 'G04 fault applied on HQ-WS01: client clock skewed and time sync pointed to invalid peer.'
