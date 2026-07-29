# Проверка чистой базовой конфигурации D1 для Windows.
$targets = @(
  @{Name='HQ-AD01 DNS'; Host='hq-ad01.corp.d1.skills'; Port=53},
  @{Name='HQ-FILE01 SMB'; Host='hq-file01.corp.d1.skills'; Port=445},
  @{Name='HQ-FILE01 HTTP'; Host='hq-file01.corp.d1.skills'; Port=80},
  @{Name='DC-LNX01 HTTP'; Host='dc-lnx01.dc.d1.skills'; Port=80},
  @{Name='DC-Win01 HTTP'; Host='dc-win01.dc.d1.skills'; Port=80}
)
Get-NetIPConfiguration
foreach ($t in $targets) {
    Write-Host "=== $($t.Name) ==="
    Resolve-DnsName $t.Host -ErrorAction Continue
    Test-NetConnection $t.Host -Port $t.Port
}
