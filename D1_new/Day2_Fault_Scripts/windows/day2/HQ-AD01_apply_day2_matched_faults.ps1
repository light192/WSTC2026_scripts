# T01: HQ-WS01 cannot open dc-lnx01.skill39.d1, local HQ resources remain reachable.
# Run on HQ-AD01 as Administrator.
$ErrorActionPreference = 'Continue'
Import-Module DnsServer -ErrorAction SilentlyContinue
$wrongIp = '10.21.10.254'
$rightIp = '10.21.10.10'
$zone = 'skill39.d1'
Get-DnsServerResourceRecord -ZoneName $zone -Name 'dc-lnx01' -RRType A -ErrorAction SilentlyContinue | Remove-DnsServerResourceRecord -ZoneName $zone -Force -ErrorAction SilentlyContinue
Add-DnsServerResourceRecordA -ZoneName $zone -Name 'dc-lnx01' -IPv4Address $wrongIp -TimeToLive 00:05:00 -ErrorAction SilentlyContinue | Out-Null
Clear-DnsServerCache -Force -ErrorAction SilentlyContinue
Write-Host "T01 fault applied on HQ-AD01: dc-lnx01.skill39.d1 A record points to $wrongIp instead of $rightIp."
