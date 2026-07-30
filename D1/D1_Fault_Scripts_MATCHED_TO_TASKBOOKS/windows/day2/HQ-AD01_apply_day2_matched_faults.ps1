# T01: HQ-WS01 cannot open dc-lnx01.skill39.d1, local HQ resources remain reachable.
# Run on HQ-AD01 as Administrator.
$ErrorActionPreference = 'Continue'
Import-Module DnsServer -ErrorAction SilentlyContinue
$wrongIp = '10.19.110.254'
$rightIpClean = '10.19.110.11'
$zones = @('skill39.d1','dc.d1.skills')
foreach ($zone in $zones) {
    if (-not (Get-DnsServerZone -Name $zone -ErrorAction SilentlyContinue)) {
        Add-DnsServerPrimaryZone -Name $zone -ReplicationScope 'Forest' -ErrorAction SilentlyContinue | Out-Null
    }
    Get-DnsServerResourceRecord -ZoneName $zone -Name 'dc-lnx01' -RRType A -ErrorAction SilentlyContinue | Remove-DnsServerResourceRecord -ZoneName $zone -Force -ErrorAction SilentlyContinue
    Add-DnsServerResourceRecordA -ZoneName $zone -Name 'dc-lnx01' -IPv4Address $wrongIp -TimeToLive 00:05:00 -ErrorAction SilentlyContinue | Out-Null
}
Clear-DnsServerCache -Force -ErrorAction SilentlyContinue
Write-Host "T01 fault applied on HQ-AD01: dc-lnx01 DNS A record points to $wrongIp instead of $rightIpClean."
