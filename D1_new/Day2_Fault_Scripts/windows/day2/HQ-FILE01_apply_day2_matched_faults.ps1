# T03: HQ-WS01 can ping HQ-FILE01 but cannot open \\hq-file01\shared.
# Run on HQ-FILE01 as Administrator.
$ErrorActionPreference = 'Stop'
$ruleName = 'D1-T03-Block-SMB-From-HQ-WS01'
Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $ruleName `
    -Direction Inbound `
    -Action Block `
    -Protocol TCP `
    -LocalPort 445 `
    -RemoteAddress '10.19.10.10' | Out-Null
Write-Host 'T03 fault applied on HQ-FILE01: SMB TCP/445 blocked from HQ-WS01 (10.19.10.10) only; ICMP remains allowed.'
