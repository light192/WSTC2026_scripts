# D1 clean-baseline check (Windows).
$targets = @(
  @{Name='HQ-AD01 DNS'; Host='hq-ad01.skill39.d1'; Port=53},
  @{Name='HQ-FILE01 SMB'; Host='hq-file01.skill39.d1'; Port=445},
  @{Name='DC-LNX01 HTTP'; Host='dc-lnx01.skill39.d1'; Port=80},
  @{Name='DC-Win01 HTTP'; Host='dc-win01.skill39.d1'; Port=80},
  @{Name='DC-SVC01 Service Desk'; Host='dc-svc01.skill39.d1'; Port=8080}
)
Get-NetIPConfiguration
foreach ($t in $targets) {
    Write-Host "=== $($t.Name) ==="
    Resolve-DnsName $t.Host -ErrorAction Continue
    Test-NetConnection $t.Host -Port $t.Port
}
