# T02: DC-Win01 cannot reach HQ domain resources.
# Run on DC-Win01 as Administrator.
$ErrorActionPreference = 'Stop'
$ruleName = 'D1-T02-Block-AD-to-HQ-AD01'
Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $ruleName `
    -Direction Outbound `
    -Action Block `
    -Protocol TCP `
    -RemoteAddress '10.19.20.10' `
    -RemotePort 53,88,135,139,389,445,464,636,3268,3269 | Out-Null
New-NetFirewallRule -DisplayName ($ruleName + '-UDP') `
    -Direction Outbound `
    -Action Block `
    -Protocol UDP `
    -RemoteAddress '10.19.20.10' `
    -RemotePort 53,88,123,389,464 | Out-Null
Write-Host 'T02 fault applied on DC-Win01: outbound AD/DNS/Kerberos/SMB to HQ-AD01 (10.19.20.10) is blocked.'
