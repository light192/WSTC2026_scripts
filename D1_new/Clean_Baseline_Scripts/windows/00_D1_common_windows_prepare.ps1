# Common D1 clean-baseline prep for Windows nodes. Run as Administrator.
# Addressing matches D1_Day2_Competitor_Task_EN_styled.pdf exactly.
param(
    [Parameter(Mandatory=$true)][ValidateSet('HQ-AD01','HQ-FILE01','HQ-WS01','DC-Win01')] [string]$NodeName
)

$Map = @{
    'HQ-AD01'   = @{ IP='10.19.20.10'; Prefix=24; GW='10.19.20.1'; DNS=@('10.19.20.10','127.0.0.1') }
    'HQ-FILE01' = @{ IP='10.19.20.20'; Prefix=24; GW='10.19.20.1'; DNS=@('10.19.20.10') }
    'HQ-WS01'   = @{ IP='10.19.10.10'; Prefix=24; GW='10.19.10.1'; DNS=@('10.19.20.10') }
    'DC-Win01'  = @{ IP='10.21.10.40'; Prefix=24; GW='10.21.10.1'; DNS=@('10.21.10.20','10.19.20.10') }
}
$Cfg = $Map[$NodeName]
$If = Get-NetAdapter | Where-Object {$_.Status -eq 'Up'} | Select-Object -First 1
if (-not $If) { throw 'No active network adapter found.' }

Rename-Computer -NewName $NodeName -Force -ErrorAction SilentlyContinue
Get-NetIPAddress -InterfaceIndex $If.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
Get-NetRoute -InterfaceIndex $If.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress -InterfaceIndex $If.ifIndex -IPAddress $Cfg.IP -PrefixLength $Cfg.Prefix -DefaultGateway $Cfg.GW
Set-DnsClientServerAddress -InterfaceIndex $If.ifIndex -ServerAddresses $Cfg.DNS
Set-TimeZone -Id 'Romance Standard Time'
New-Item -ItemType Directory -Path C:\D1-Baseline -Force | Out-Null
"node=$NodeName`nip=$($Cfg.IP)`ngateway=$($Cfg.GW)`ndns=$($Cfg.DNS -join ',')" | Set-Content C:\D1-Baseline\identity.txt
Write-Host "D1 common Windows baseline prepared on $NodeName. A reboot may be required after the rename."
