# G02: DC-CL01 cannot open \hq-file01\shared while local DC services remain reachable.
# Run on HQ-FILE01 as Administrator.
$ErrorActionPreference = 'Stop'
$ruleName = 'D1-G02-Block-SMB-From-DC'
Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $ruleName `
    -Direction Inbound `
    -Action Block `
    -Protocol TCP `
    -LocalPort 445 `
    -RemoteAddress '10.19.110.0/24,10.19.120.0/24,10.21.10.0/24' | Out-Null
Write-Host 'G02 fault applied on HQ-FILE01: SMB TCP/445 blocked from DC subnets.'
