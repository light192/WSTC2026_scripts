$ruleName = 'D1-G02-Block-SMB-From-DC'

Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule

$remoteAddresses = @(
    '10.19.110.0/24',
    '10.19.120.0/24'
)

New-NetFirewallRule -DisplayName $ruleName `
    -Direction Inbound `
    -Action Block `
    -Protocol TCP `
    -LocalPort 445 `
    -RemoteAddress $remoteAddresses `
    -ErrorAction Stop