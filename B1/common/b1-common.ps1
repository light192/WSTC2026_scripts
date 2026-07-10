Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:B1Root = Split-Path -Parent $PSScriptRoot
$script:CriteriaMapPath = Join-Path $script:B1Root 'criteria\b1_criteria_map.tsv'
$script:ReportDir = Join-Path $script:B1Root 'reports'
$script:ResultsPath = Join-Path $script:ReportDir 'b1-results.tsv'
$script:DetailPath = Join-Path $script:ReportDir 'b1-detail.log'
$script:SummaryPath = Join-Path $script:ReportDir 'b1-summary.txt'
$script:PauseBetweenChecks = $true
$script:B1ReportEnabled = $false
$script:B1ResultRows = @()

function ConvertTo-B1Text {
    param([object]$Value)
    if ($null -eq $Value) { return '' }

    $baseValue = $Value.PSObject.BaseObject
    if ($baseValue -is [string]) { return $baseValue.TrimEnd() }
    if ($baseValue -is [System.ValueType]) { return ([string]$baseValue).TrimEnd() }

    if ($baseValue -is [System.Collections.IEnumerable]) {
        $items = @()
        foreach ($item in $baseValue) {
            if ($null -eq $item) { continue }
            $baseItem = $item.PSObject.BaseObject
            if ($baseItem -is [string] -or $baseItem -is [System.ValueType]) {
                $items += [string]$baseItem
            } else {
                $items += (($item | Out-String -Width 4096).Trim())
            }
        }
        return (($items -join [Environment]::NewLine).TrimEnd())
    }

    return (($Value | Out-String -Width 4096).Trim())
}

function Write-B1Log {
    param([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    Write-Host $Text -ForegroundColor $Color
    if (-not $script:B1ReportEnabled) { return }
    try {
        Add-Content -LiteralPath $script:DetailPath -Value $Text -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Host "[WARN] Не удалось записать в лог $script:DetailPath: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Write-B1Section {
    param([string]$Text)
    Write-Host ''
    Write-B1Log '######################################################################################' Magenta
    Write-B1Log $Text Magenta
    Write-B1Log '######################################################################################' Magenta
    Write-Host ''
}

function Initialize-B1Report {
    param(
        [string]$HostKey,
        [string]$ReportDir,
        [switch]$EnableReport
    )
    $script:B1ReportEnabled = $false
    $script:B1ResultRows = @()

    if (-not $EnableReport -and [string]::IsNullOrWhiteSpace($ReportDir)) {
        $script:ReportDir = $null
        $script:ResultsPath = $null
        $script:DetailPath = $null
        $script:SummaryPath = $null
        return
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($ReportDir)) {
        $candidates.Add($ReportDir)
        $candidates.Add((Join-Path $ReportDir $HostKey))
    }
    $candidates.Add((Join-Path $script:B1Root "reports\$HostKey"))
    $candidates.Add((Join-Path $env:TEMP "B1-reports\$HostKey"))

    $seen = @{}
    $lastError = $null
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try {
            $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($candidate)
        } catch {
            $resolved = $candidate
        }
        if ($seen.ContainsKey($resolved.ToUpperInvariant())) { continue }
        $seen[$resolved.ToUpperInvariant()] = $true

        $script:ReportDir = $resolved
        $script:ResultsPath = Join-Path $script:ReportDir 'b1-results.tsv'
        $script:DetailPath = Join-Path $script:ReportDir 'b1-detail.log'
        $script:SummaryPath = Join-Path $script:ReportDir 'b1-summary.txt'
        try {
            New-Item -ItemType Directory -Path $script:ReportDir -Force -ErrorAction Stop | Out-Null
            Set-Content -LiteralPath $script:ResultsPath -Value "AspectID`tGroupID`tHostKey`tMaxMark`tStatus`tMessage" -Encoding UTF8 -ErrorAction Stop
            Set-Content -LiteralPath $script:DetailPath -Value '' -Encoding UTF8 -ErrorAction Stop
            if (Test-Path -LiteralPath $script:SummaryPath) { Remove-Item -LiteralPath $script:SummaryPath -Force -ErrorAction Stop }
            $script:B1ReportEnabled = $true
            if ($candidate -ne $ReportDir -and -not [string]::IsNullOrWhiteSpace($ReportDir)) {
                Write-Host "Не удалось использовать каталог отчета '$ReportDir'. Отчет будет записан в '$script:ReportDir'." -ForegroundColor Yellow
            }
            return
        } catch {
            $lastError = $_.Exception.Message
        }
    }

    throw "Не удалось создать файлы отчета. Последняя ошибка: $lastError"
}

function Get-B1Criteria {
    param([string]$HostKey)
    if (-not (Test-Path $script:CriteriaMapPath)) {
        throw "Criteria map not found: $script:CriteriaMapPath"
    }
    $HostKey = $HostKey.ToUpperInvariant()
    $allCriteria = @(Import-Csv -Path $script:CriteriaMapPath -Delimiter "`t" -Encoding UTF8)
    $internetZoneHosts = @('INET-SRV01','INET-CL01','ISP-SHA01','ISP-BJ01')
    if ($internetZoneHosts -contains $HostKey) {
        return $allCriteria |
            Where-Object { $_.GroupID -eq 'K1' } |
            ForEach-Object {
                [pscustomobject]@{
                    AspectID = $_.AspectID
                    GroupID = $_.GroupID
                    HostKey = $HostKey
                    MaxMark = $_.MaxMark
                    Description = $_.Description
                    VerificationCommands = $_.VerificationCommands
                    ExpectedResult = $_.ExpectedResult
                    WSOS = $_.WSOS
                }
            } |
            Sort-Object AspectID
    }
    return $allCriteria |
        Where-Object { $_.HostKey -eq $HostKey } |
        Sort-Object AspectID
}

function Start-B1Aspect {
    param([object]$Aspect)
    Write-Host ''
    Write-B1Log "[$($Aspect.AspectID)] $($Aspect.Description)" Yellow
    Write-B1Log "Команды из marking scheme: $($Aspect.VerificationCommands)" Cyan
    Write-B1Log "Ожидаемый результат: $($Aspect.ExpectedResult)" DarkCyan
}

function Invoke-B1Evidence {
    param(
        [string]$Command,
        [scriptblock]$ScriptBlock,
        [switch]$AllowError
    )
    Write-B1Log "Команда: $Command" Cyan
    try {
        $value = & $ScriptBlock
        $text = ConvertTo-B1Text $value
        if ([string]::IsNullOrWhiteSpace($text)) { $text = '(пустой вывод)' }
        Write-B1Log 'Фактический вывод:' Blue
        Write-B1Log $text Gray
        return [pscustomobject]@{ Ok = $true; Value = $value; Text = $text; Error = $null }
    } catch {
        $text = $_.Exception.Message
        Write-B1Log 'Фактический вывод:' Blue
        Write-B1Log "[ERROR] $text" Red
        if (-not $AllowError) {
            return [pscustomobject]@{ Ok = $false; Value = $null; Text = "[ERROR] $text"; Error = $_ }
        }
        return [pscustomobject]@{ Ok = $true; Value = $null; Text = "[ERROR] $text"; Error = $_ }
    }
}

function Complete-B1Aspect {
    param(
        [object]$Aspect,
        [string]$Status,
        [string]$Message
    )
    $line = "{0}`t{1}`t{2}`t{3}`t{4}`t{5}" -f $Aspect.AspectID, $Aspect.GroupID, $Aspect.HostKey, $Aspect.MaxMark, $Status, $Message
    $script:B1ResultRows += [pscustomobject]@{
        AspectID = $Aspect.AspectID
        GroupID = $Aspect.GroupID
        HostKey = $Aspect.HostKey
        MaxMark = $Aspect.MaxMark
        Status = $Status
        Message = $Message
    }
    if ($script:B1ReportEnabled) {
        Add-Content -LiteralPath $script:ResultsPath -Value $line -Encoding UTF8
    }
    switch ($Status) {
        'PASS' { Write-B1Log "[PASS] $($Aspect.AspectID)/$($Aspect.MaxMark) - $Message" Green }
        'FAIL' { Write-B1Log "[FAIL] $($Aspect.AspectID)/$($Aspect.MaxMark) - $Message" Red }
        'WARN' { Write-B1Log "[WARN] $($Aspect.AspectID)/$($Aspect.MaxMark) - $Message" Yellow }
        default { Write-B1Log "[$Status] $($Aspect.AspectID)/$($Aspect.MaxMark) - $Message" Gray }
    }
    if ($script:PauseBetweenChecks) {
        Read-Host 'Нажмите Enter, чтобы продолжить'
    }
}

function Test-B1ContainsAll {
    param([string]$Text, [string[]]$Needles)
    foreach ($needle in $Needles) {
        if ($Text -notmatch [regex]::Escape($needle)) { return $false }
    }
    return $true
}

function Get-B1Ipv4ConfigText {
    $cfg = Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4Address }
    return ConvertTo-B1Text $cfg
}

function Test-B1Hostname {
    param([string]$Expected)
    $r = Invoke-B1Evidence 'hostname; $env:COMPUTERNAME' { "hostname=$(hostname); COMPUTERNAME=$env:COMPUTERNAME" }
    $actual = (hostname).Trim().ToUpperInvariant()
    if ($actual -eq $Expected.ToUpperInvariant()) { return @('PASS', "Hostname is $actual") }
    return @('FAIL', "Hostname is $actual, expected $Expected")
}

function Test-B1IpProfile {
    param([hashtable]$Profile)
    $r = Invoke-B1Evidence 'Get-NetIPConfiguration; Get-DnsClientServerAddress -AddressFamily IPv4; Get-NetRoute -DestinationPrefix 0.0.0.0/0' {
        Get-NetIPConfiguration | Where-Object { $_.IPv4Address }
        Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.ServerAddresses }
        Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
    } -AllowError
    $text = $r.Text
    $missing = @()
    $ips = if ($Profile.ContainsKey('IPs')) { @($Profile['IPs']) } else { @() }
    $dnsServers = if ($Profile.ContainsKey('Dns')) { @($Profile['Dns']) } else { @() }
    $gateways = if ($Profile.ContainsKey('Gateways')) { @($Profile['Gateways']) } else { @() }
    foreach ($ip in $ips) {
        if ($text -notmatch [regex]::Escape($ip)) { $missing += $ip }
    }
    foreach ($dns in $dnsServers) {
        if ($dns -and $text -notmatch [regex]::Escape($dns)) { $missing += "DNS:$dns" }
    }
    foreach ($gw in $gateways) {
        if ($gw -and $text -notmatch [regex]::Escape($gw)) { $missing += "GW:$gw" }
    }
    if ($missing.Count -eq 0) { return @('PASS', 'Expected IP/DNS/gateway values are present.') }
    return @('FAIL', "Missing expected values: $($missing -join ', ')")
}

function Test-B1Pings {
    param([string[]]$Targets)
    $bad = @()
    foreach ($target in $Targets) {
        $r = Invoke-B1Evidence "Test-Connection $target -Count 2 -Quiet" { Test-Connection $target -Count 2 -Quiet }
        if (-not [bool]$r.Value) { $bad += $target }
    }
    if ($bad.Count -eq 0) { return @('PASS', "All targets reachable: $($Targets -join ', ')") }
    return @('FAIL', "Unreachable targets: $($bad -join ', ')")
}

function Test-B1StaticRoutes {
    param([hashtable]$Routes)
    $bad = @()
    foreach ($prefix in $Routes.Keys) {
        $expectedNextHop = $Routes[$prefix]
        $r = Invoke-B1Evidence "Get-NetRoute -DestinationPrefix $prefix" {
            Get-NetRoute -DestinationPrefix $prefix -ErrorAction SilentlyContinue |
                Select-Object DestinationPrefix,NextHop,InterfaceAlias,RouteMetric
        } -AllowError
        if ($r.Text -notmatch [regex]::Escape($expectedNextHop)) {
            $bad += "$prefix via $expectedNextHop"
        }
    }
    if ($bad.Count -eq 0) { return @('PASS', 'Static routes have expected next-hop values.') }
    return @('FAIL', "Routes not proven: $($bad -join ', ')")
}

function Test-B1DomainJoin {
    param([string]$ExpectedSiteOuFragment)
    $cs = Invoke-B1Evidence '(Get-CimInstance Win32_ComputerSystem).PartOfDomain' {
        Get-CimInstance Win32_ComputerSystem | Select-Object Name,Domain,PartOfDomain
    }
    $part = (Get-CimInstance Win32_ComputerSystem).PartOfDomain
    if (-not $part) { return @('FAIL', 'Computer is not domain joined.') }
    if (Get-Command Get-ADComputer -ErrorAction SilentlyContinue) {
        $ad = Invoke-B1Evidence "Get-ADComputer $env:COMPUTERNAME -Properties DistinguishedName" {
            Get-ADComputer $env:COMPUTERNAME -Properties DistinguishedName | Select-Object Name,DistinguishedName
        } -AllowError
        if ($ExpectedSiteOuFragment -and $ad.Text -notmatch [regex]::Escape($ExpectedSiteOuFragment)) {
            return @('FAIL', "Domain joined, but AD OU fragment not found: $ExpectedSiteOuFragment")
        }
    } else {
        return @('WARN', 'Domain joined, but AD module is unavailable for OU validation.')
    }
    return @('PASS', 'Domain join and AD placement are proven.')
}

function Test-B1Workgroup {
    param([string]$ExpectedName)
    $r = Invoke-B1Evidence '(Get-CimInstance Win32_ComputerSystem) | Select Name,Domain,PartOfDomain' {
        Get-CimInstance Win32_ComputerSystem | Select-Object Name,Domain,PartOfDomain
    }
    $cs = Get-CimInstance Win32_ComputerSystem
    if (($cs.Name.ToUpperInvariant() -eq $ExpectedName) -and (-not $cs.PartOfDomain)) {
        return @('PASS', 'Host is a workgroup host as expected.')
    }
    return @('FAIL', "Name/domain state mismatch. Name=$($cs.Name), PartOfDomain=$($cs.PartOfDomain)")
}

function Test-B1AdObjectTerms {
    param([string]$Command, [scriptblock]$ScriptBlock, [string[]]$Terms, [string]$PassMessage)
    $r = Invoke-B1Evidence $Command $ScriptBlock
    if (-not $r.Ok) { return @('FAIL', 'Command failed.') }
    $missing = @()
    foreach ($t in $Terms) {
        if ($r.Text -notmatch [regex]::Escape($t)) { $missing += $t }
    }
    if ($missing.Count -eq 0) { return @('PASS', $PassMessage) }
    return @('FAIL', "Missing expected terms: $($missing -join ', ')")
}

function Test-B1CommandWarn {
    param([string]$Command, [scriptblock]$ScriptBlock, [string]$Message)
    Invoke-B1Evidence $Command $ScriptBlock -AllowError | Out-Null
    return @('WARN', $Message)
}

function Test-B1RepadminShowRepl {
    $r = Invoke-B1Evidence 'repadmin /showrepl' { repadmin /showrepl } -AllowError
    if ([string]::IsNullOrWhiteSpace($r.Text) -or $r.Text -eq '(пустой вывод)') {
        return @('WARN', 'repadmin returned no visible text; run the command manually and review replication state.')
    }
    $failurePattern = '(?im)\b(error|failed|fails\s*[:=]\s*[1-9][0-9]*|1722|8453|8524|1908|1256|8614)\b'
    if ($r.Text -match $failurePattern) {
        return @('FAIL', 'repadmin output contains replication error/failure indicators.')
    }
    if ($r.Text -match '(?im)\bsuccessful\b|0\s+fails|0\s+failures') {
        return @('PASS', 'repadmin output does not show failed inbound replication.')
    }
    return @('WARN', 'Review repadmin output; no explicit failure was found, but success markers were not detected.')
}

function Test-B1RouterAspect {
    param([string]$HostKey, [int]$Seq)
    $profiles = @{
        'SHA-RTR01' = @{
            IPs = @('198.18.100.10','10.21.10.1','10.21.20.1','10.21.30.1')
            Gateways = @('198.18.100.1')
            Routes = @{ '10.31.20.0/24' = '198.18.100.1'; '10.31.30.0/24' = '198.18.100.1' }
            Pings = @('198.18.100.1','198.18.101.10','198.18.200.10','198.18.201.10')
            RelayServer = '10.21.20.20'
        }
        'BJ-RTR01' = @{
            IPs = @('198.18.101.10','10.31.20.1','10.31.30.1')
            Gateways = @('198.18.101.1')
            Routes = @{ '10.21.10.0/24' = '198.18.101.1'; '10.21.20.0/24' = '198.18.101.1'; '10.21.30.0/24' = '198.18.101.1' }
            Pings = @('198.18.101.1','198.18.100.10','198.18.200.10','198.18.201.10')
            RelayServer = '10.31.20.20'
        }
    }
    $p = $profiles[$HostKey]
    switch ($Seq) {
        1 { return Test-B1Hostname $HostKey }
        2 { return Test-B1IpProfile $p }
        3 {
            $r = Invoke-B1Evidence 'Get-Service RemoteAccess; Get-NetIPInterface -AddressFamily IPv4 | Select InterfaceAlias,Forwarding' {
                Get-Service RemoteAccess -ErrorAction SilentlyContinue
                Get-NetIPInterface -AddressFamily IPv4 | Select-Object InterfaceAlias,Forwarding
            } -AllowError
            if ($r.Text -match 'Enabled|Running') { return @('PASS', 'Routing/forwarding evidence is present.') }
            return @('FAIL', 'Routing/forwarding is not proven.')
        }
        4 { return Test-B1StaticRoutes $p.Routes }
        5 {
            $r = Invoke-B1Evidence 'netsh routing ip relay show ifbinding; netsh routing ip relay show global' {
                netsh routing ip relay show ifbinding
                netsh routing ip relay show global
            } -AllowError
            if ($r.Text -match [regex]::Escape($p.RelayServer)) { return @('PASS', "DHCP relay points to $($p.RelayServer).") }
            return @('WARN', 'DHCP relay evidence is not conclusive from local command output.')
        }
        6 {
            $r = Invoke-B1Evidence 'Get-NetNat; netsh routing ip nat show interface' {
                Get-NetNat -ErrorAction SilentlyContinue
                netsh routing ip nat show interface
            } -AllowError
            if ($r.Text -eq '(пустой вывод)' -or $r.Text -notmatch '10\.21\.|10\.31\.') { return @('PASS', 'NAT for private inter-site networks is not visible.') }
            return @('FAIL', 'NAT evidence mentions private inter-site networks.')
        }
        7 { return Test-B1Pings $p.Pings }
    }
}

function Test-B1ShaDcAspect {
    param([int]$Seq)
    switch ($Seq) {
        1 { return Test-B1AdObjectTerms 'Get-ADDomain; Get-ADForest' { Get-ADDomain | Select DNSRoot,NetBIOSName; Get-ADForest | Select Name } @('nb-b1.local','NBB1') 'Domain and forest values match.' }
        2 { return Test-B1AdObjectTerms 'Get-ADDomainController SHA-DC01; Get-WindowsFeature DNS' { Get-ADDomainController SHA-DC01 | Select HostName,IsGlobalCatalog,Site; Get-WindowsFeature DNS } @('SHA-DC01','True','DNS') 'SHA-DC01 is DC/DNS/GC.' }
        3 { return Test-B1AdObjectTerms 'Get-DnsClientServerAddress -AddressFamily IPv4' { Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object ServerAddresses } @('10.21.20.10','10.31.20.10') 'DNS client order contains both DCs.' }
        4 { return Test-B1AdObjectTerms 'Get-ADOrganizationalUnit -Filter * | Select DistinguishedName' { Get-ADOrganizationalUnit -Filter * | Select DistinguishedName } @('00-Servers','Shanghai','Beijing','10-Workstations','20-Users','30-Groups','40-ServiceAccounts') 'Required OU structure is visible.' }
        5 { return Test-B1AdObjectTerms "Get-ADGroup -Filter * -SearchBase 'OU=30-Groups,DC=nb-b1,DC=local'" { Get-ADGroup -Filter * -SearchBase 'OU=30-Groups,DC=nb-b1,DC=local' | Select Name } @('GG_IT','GG_OPS','GG_FIN','GG_GUEST','GG_Shanghai_Users','GG_Beijing_Users','GG_LAPS_Readers','GG_File_Common_RW','GG_File_Common_RO','GG_File_IT_RW','GG_File_Beijing_RW') 'All required groups are visible.' }
        6 { return Test-B1AdObjectTerms 'Get-ADComputer SHA-DC01,SHA-FS01,BJ-DC02,BJ-SRV01 -Properties DistinguishedName' { 'SHA-DC01','SHA-FS01','BJ-DC02','BJ-SRV01' | ForEach-Object { Get-ADComputer $_ -Properties DistinguishedName | Select Name,DistinguishedName } } @('00-Servers','Shanghai','Beijing') 'Server computer accounts are in server OUs.' }
        7 { return Test-B1AdObjectTerms 'Get-ADReplicationSite -Filter *' { Get-ADReplicationSite -Filter * | Select Name } @('Shanghai','Beijing') 'AD sites exist.' }
        8 { return Test-B1AdObjectTerms 'Get-ADReplicationSubnet -Filter * | Select Name,Site' { Get-ADReplicationSubnet -Filter * | Select Name,Site } @('10.21.20.0/24','10.21.30.0/24','10.31.20.0/24','10.31.30.0/24','Shanghai','Beijing') 'AD subnets are visible.' }
        9 {
            $r = Invoke-B1Evidence "Get-ADReplicationSubnet -Filter * | Where-Object Name -eq '10.21.10.0/24'" { Get-ADReplicationSubnet -Filter * | Where-Object Name -eq '10.21.10.0/24' } -AllowError
            if ($r.Text -eq '(пустой вывод)') { return @('PASS', 'DMZ subnet is absent from AD Sites.') }
            return @('FAIL', 'DMZ subnet is present in AD Sites.')
        }
        10 { return Test-B1AdObjectTerms 'Get-ADReplicationSiteLink -Filter * | Select Name,Cost,ReplicationFrequencyInMinutes' { Get-ADReplicationSiteLink -Filter * | Select Name,Cost,ReplicationFrequencyInMinutes } @('100','15') 'Site link cost and interval are visible.' }
        11 {
            $r = Invoke-B1Evidence 'repadmin /replsummary; repadmin /showrepl' { repadmin /replsummary; repadmin /showrepl } -AllowError
            if ($r.Text -match 'fails\s*:\s*0|0\s*/\s*\d+') { return @('PASS', 'Replication output does not show failures.') }
            return @('WARN', 'Review repadmin output for replication failures.')
        }
        12 { return Test-B1AdObjectTerms 'net share; Test-Path \\SHA-DC01\SYSVOL; Test-Path \\SHA-DC01\NETLOGON' { net share; "SYSVOL=$(Test-Path '\\SHA-DC01\SYSVOL')"; "NETLOGON=$(Test-Path '\\SHA-DC01\NETLOGON')" } @('SYSVOL','NETLOGON','SYSVOL=True','NETLOGON=True') 'SYSVOL and NETLOGON are available.' }
        13 { return Test-B1AdObjectTerms 'Get-DnsServerZone -Name nb-b1.local' { Get-DnsServerZone -Name 'nb-b1.local' | Select ZoneName,ZoneType,IsDsIntegrated } @('nb-b1.local','Primary','True') 'AD-integrated forward zone exists.' }
        14 { return Test-B1AdObjectTerms 'Get-DnsServerZone' { Get-DnsServerZone | Select ZoneName } @('10.21.10','10.21.20','10.21.30','10.31.20','10.31.30','198.18.100','198.18.101','198.18.200','198.18.201') 'Reverse zones are visible.' }
        15 { return Test-B1AdObjectTerms 'Resolve-DnsName host records -Server 10.21.20.10' { 'sha-rtr01','sha-dc01','sha-fs01','bj-rtr01','bj-dc02','bj-srv01','sha-web01','sha-app01','files','bj-files','intranet' | ForEach-Object { Resolve-DnsName "$_.nb-b1.local" -Server '10.21.20.10' -ErrorAction SilentlyContinue } } @('10.21.20.10','10.31.20.10') 'DNS A/CNAME resolution returns records.' }
        16 { return Test-B1AdObjectTerms 'Resolve-DnsName PTR records -Server 10.21.20.10' { '10.21.20.10','10.21.20.20','10.31.20.10','10.31.20.20','10.21.10.11','10.21.10.12' | ForEach-Object { Resolve-DnsName $_ -Server '10.21.20.10' -ErrorAction SilentlyContinue } } @('nb-b1.local') 'PTR lookups return domain names.' }
        17 { return Test-B1AdObjectTerms 'Resolve-DnsName _ldap/_kerberos SRV -Server 10.21.20.10' { Resolve-DnsName '_ldap._tcp.dc._msdcs.nb-b1.local' -Type SRV -Server '10.21.20.10'; Resolve-DnsName '_kerberos._tcp.nb-b1.local' -Type SRV -Server '10.21.20.10' } @('SHA-DC01','BJ-DC02') 'AD DS SRV records are visible.' }
        18 { return Test-B1AdObjectTerms 'Get-DnsServerForwarder' { Get-DnsServerForwarder | Select IPAddress } @('198.18.200.10') 'DNS forwarder points to simulated Internet DNS.' }
        19 { return Test-B1AdObjectTerms "Get-GPO -Name GPO-B1-Domain-Baseline; Get-GPInheritance -Target 'DC=nb-b1,DC=local'" { Get-GPO -Name 'GPO-B1-Domain-Baseline'; Get-GPInheritance -Target 'DC=nb-b1,DC=local' } @('GPO-B1-Domain-Baseline') 'Domain baseline GPO exists and inheritance is readable.' }
        20 { return Test-B1CommandWarn 'Get-GPOReport -Name GPO-B1-Domain-Baseline -ReportType Xml' { Get-GPOReport -Name 'GPO-B1-Domain-Baseline' -ReportType Xml } 'Review GPO XML output for banner, NB_TRAINING, LM hash prevention and Windows Update schedule.' }
        21 { return Test-B1AdObjectTerms "Get-ADObject schema msLAPS-PasswordExpirationTime" { Get-ADObject -SearchBase (Get-ADRootDSE).SchemaNamingContext -LDAPFilter '(lDAPDisplayName=msLAPS-PasswordExpirationTime)' -Properties lDAPDisplayName | Select lDAPDisplayName } @('msLAPS-PasswordExpirationTime') 'Windows LAPS schema attribute exists.' }
        22 { return Test-B1CommandWarn "Find-LapsADExtendedRights -Identity 'OU=10-Workstations,DC=nb-b1,DC=local'" { Find-LapsADExtendedRights -Identity 'OU=10-Workstations,DC=nb-b1,DC=local' } 'Review output and confirm GG_LAPS_Readers has LAPS read rights.' }
        23 { return Test-B1AdObjectTerms 'Get-ADFineGrainedPasswordPolicy -Filter *; Get-ADFineGrainedPasswordPolicySubject' { $p=Get-ADFineGrainedPasswordPolicy -Filter *; $p; $p | ForEach-Object { Get-ADFineGrainedPasswordPolicySubject $_ } } @('14','30','10','GG_FIN') 'Fine-grained password policy evidence is present.' }
    }
}

function Test-B1BjDcAspect {
    param([int]$Seq)
    switch ($Seq) {
        1 { return Test-B1AdObjectTerms 'Get-ADDomainController BJ-DC02; Get-WindowsFeature DNS' { Get-ADDomainController BJ-DC02 | Select HostName,IsGlobalCatalog,Site; Get-WindowsFeature DNS } @('BJ-DC02','True','DNS') 'BJ-DC02 is DC/DNS/GC.' }
        2 { return Test-B1AdObjectTerms 'Get-DnsClientServerAddress -AddressFamily IPv4' { Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object ServerAddresses } @('10.31.20.10','10.21.20.10') 'DNS client order contains both DCs.' }
        3 { return Test-B1AdObjectTerms 'Get-ADDomainController BJ-DC02 | Select HostName,Site' { Get-ADDomainController BJ-DC02 | Select HostName,Site } @('Beijing') 'BJ-DC02 is in Beijing site.' }
        4 { return Test-B1AdObjectTerms 'Test-Path \\BJ-DC02\SYSVOL; Test-Path \\BJ-DC02\NETLOGON' { "SYSVOL=$(Test-Path '\\BJ-DC02\SYSVOL')"; "NETLOGON=$(Test-Path '\\BJ-DC02\NETLOGON')" } @('SYSVOL=True','NETLOGON=True') 'SYSVOL and NETLOGON are reachable.' }
        5 { return Test-B1RepadminShowRepl }
        6 { return Test-B1AdObjectTerms 'Get-DnsServerZone -Name nb-b1.local' { Get-DnsServerZone -Name 'nb-b1.local' | Select ZoneName,ZoneType,IsDsIntegrated } @('nb-b1.local','True') 'DNS zone replicated to BJ-DC02.' }
        7 { return Test-B1AdObjectTerms 'Resolve-DnsName core records/SRV -Server 10.31.20.10' { Resolve-DnsName 'sha-dc01.nb-b1.local' -Server '10.31.20.10'; Resolve-DnsName 'bj-dc02.nb-b1.local' -Server '10.31.20.10'; Resolve-DnsName '_ldap._tcp.dc._msdcs.nb-b1.local' -Type SRV -Server '10.31.20.10' } @('sha-dc01','bj-dc02') 'Beijing DNS resolves core records.' }
        8 { return Test-B1AdObjectTerms 'Get-DnsServerForwarder' { Get-DnsServerForwarder | Select IPAddress } @('198.18.200.10') 'DNS forwarder points to simulated Internet DNS.' }
        9 { return Test-B1CommandWarn 'dcdiag /test:advertising /test:dns' { dcdiag /test:advertising /test:dns } 'Review dcdiag output and confirm Advertising/DNS have no critical failures.' }
    }
}

function Test-B1FileServerAspect {
    param([string]$HostKey, [int]$Seq)
    $isSha = $HostKey -eq 'SHA-FS01'
    $profile = if ($isSha) {
        @{ IPs=@('10.21.20.20'); Dns=@('10.21.20.10','10.31.20.10'); Ou='00-Servers'; Scope='10.21.30.0'; Router='10.21.30.1'; Shares=@('Common','IT','Home$') }
    } else {
        @{ IPs=@('10.31.20.20'); Dns=@('10.31.20.10','10.21.20.10'); Ou='00-Servers'; Scope='10.31.30.0'; Router='10.31.30.1'; Shares=@('Branch') }
    }
    switch ($Seq) {
        1 { $r1 = Test-B1Hostname $HostKey; $r2 = Test-B1IpProfile $profile; if ($r1[0] -eq 'PASS' -and $r2[0] -eq 'PASS') { return @('PASS','Hostname and IP profile are correct.') }; return @('FAIL', "$($r1[1]); $($r2[1])") }
        2 { return Test-B1AdObjectTerms 'Get-Service WinRM; Test-WSMan localhost' { Get-Service WinRM; Test-WSMan localhost } @('Running') 'WinRM is available for remote administration.' }
        3 { return Test-B1AdObjectTerms 'Get-DhcpServerInDC; Get-WindowsFeature DHCP' { Get-DhcpServerInDC; Get-WindowsFeature DHCP } @($HostKey,'DHCP') 'DHCP role and authorization evidence is present.' }
        4 { return Test-B1AdObjectTerms 'Get-DhcpServerv4Scope' { Get-DhcpServerv4Scope | Select ScopeId,StartRange,EndRange,Name } @($profile.Scope,'100','200') 'Expected DHCP scope/range is visible.' }
        5 { return Test-B1AdObjectTerms "Get-DhcpServerv4OptionValue -ScopeId $($profile.Scope)" { Get-DhcpServerv4OptionValue -ScopeId $profile.Scope } @($profile.Router,'nb-b1.local') 'DHCP router/DNS/suffix options are visible.' }
        6 { return Test-B1CommandWarn 'Get-DhcpServerv4DnsSetting' { Get-DhcpServerv4DnsSetting } 'Review dynamic DNS settings and confirm DHCP registers A/PTR records.' }
        7 { return Test-B1AdObjectTerms 'Get-SmbShare' { Get-SmbShare | Select Name,Path } $profile.Shares 'Expected SMB shares exist.' }
        8 {
            if ($isSha) { return Test-B1AdObjectTerms 'Get-Acl C:\Shares\Common' { $acl=Get-Acl 'C:\Shares\Common'; $acl | Select-Object Path,Owner,Group,AccessToString; $acl.Access | Select-Object IdentityReference,FileSystemRights,AccessControlType,IsInherited,InheritanceFlags,PropagationFlags } @('GG_File_Common_RW','GG_File_Common_RO') 'Common ACL contains required groups.' }
            return Test-B1AdObjectTerms 'Get-Acl C:\Shares\Branch' { $acl=Get-Acl 'C:\Shares\Branch'; $acl | Select-Object Path,Owner,Group,AccessToString; $acl.Access | Select-Object IdentityReference,FileSystemRights,AccessControlType,IsInherited,InheritanceFlags,PropagationFlags } @('GG_File_Beijing_RW') 'Branch ACL contains required group.'
        }
        9 {
            if ($isSha) { return Test-B1AdObjectTerms 'Get-Acl C:\Shares\IT' { $acl=Get-Acl 'C:\Shares\IT'; $acl | Select-Object Path,Owner,Group,AccessToString; $acl.Access | Select-Object IdentityReference,FileSystemRights,AccessControlType,IsInherited,InheritanceFlags,PropagationFlags } @('GG_File_IT_RW') 'IT ACL contains required group.' }
            return Test-B1AdObjectTerms 'Get-Service WinRM; Test-WSMan localhost' { Get-Service WinRM; Test-WSMan localhost } @('Running') 'Remote administration is available.'
        }
        10 { return Test-B1CommandWarn 'Get-ChildItem C:\Shares\Home; Get-Acl C:\Shares\Home' { Get-ChildItem 'C:\Shares\Home' -ErrorAction SilentlyContinue; Get-Acl 'C:\Shares\Home' -ErrorAction SilentlyContinue } 'Review home folders and ACL isolation for individual users.' }
    }
}

function Test-B1ClientAspect {
    param([string]$HostKey, [int]$Seq)
    $isSha = $HostKey -eq 'SHA-CL01'
    $profile = if ($isSha) {
        @{ Range='10.21.30.'; Gateway='10.21.30.1'; Dns=@('10.21.20.10','10.31.20.10'); Ou='10-Workstations'; CrossNames=@('bj-dc02.nb-b1.local','bj-files.nb-b1.local'); CrossTarget='bj-srv01.nb-b1.local' }
    } else {
        @{ Range='10.31.30.'; Gateway='10.31.30.1'; Dns=@('10.31.20.10','10.21.20.10'); Ou='10-Workstations'; CrossNames=@('sha-dc01.nb-b1.local','files.nb-b1.local'); CrossTarget='sha-fs01.nb-b1.local' }
    }
    switch ($Seq) {
        1 { return Test-B1IpProfile @{ IPs=@($profile.Range); Gateways=@($profile.Gateway); Dns=$profile.Dns } }
        2 { return Test-B1DomainJoin $profile.Ou }
        3 { return Test-B1AdObjectTerms 'gpresult /r /scope computer' { gpresult /r /scope computer } @('GPO-B1-Workstations-Security') 'Workstations security GPO is applied.' }
        4 { return Test-B1CommandWarn "Get-NetFirewallProfile -Profile Domain; Get-NetFirewallRule; Get-LocalGroupMember 'Remote Desktop Users'" { Get-NetFirewallProfile -Profile Domain; Get-NetFirewallRule -DisplayGroup 'File and Printer Sharing' -ErrorAction SilentlyContinue; Get-LocalGroupMember 'Remote Desktop Users' -ErrorAction SilentlyContinue } 'Review firewall, ICMP and RDP local group evidence.' }
        5 { return Test-B1CommandWarn "Get-LapsADPassword -Identity $HostKey -AsPlainText" { Get-LapsADPassword -Identity $HostKey -AsPlainText } "Review LAPS output and confirm AD password exists for $HostKey." }
        6 {
            if ($isSha) { return Test-B1AdObjectTerms 'Get-BitLockerVolume -MountPoint D:; manage-bde -status D:' { Get-BitLockerVolume -MountPoint 'D:'; manage-bde -status D: } @('On','Recovery') 'BitLocker D: protection/recovery evidence is visible.' }
            return Test-B1CommandWarn 'net use' { net use } 'Review drive mappings for Beijing users.'
        }
        7 {
            if ($isSha) { return Test-B1CommandWarn "Get-ADObject BitLocker recovery under $HostKey" { $comp=Get-ADComputer $HostKey; Get-ADObject -SearchBase $comp.DistinguishedName -LDAPFilter '(objectClass=msFVE-RecoveryInformation)' -Properties msFVE-RecoveryPassword } "Review BitLocker recovery object for $HostKey." }
            return Test-B1CommandWarn '\\bj-files.nb-b1.local\Branch access tests' { Test-Path '\\bj-files.nb-b1.local\Branch'; cmd /c 'dir \\bj-files.nb-b1.local\Branch' } 'Review Branch share access under the intended Beijing/GUEST users.'
        }
        8 {
            if ($isSha) { return Test-B1AdObjectTerms 'Import-Csv C:\Skills\b1-users.csv' { Import-Csv 'C:\Skills\b1-users.csv' | Select-Object FirstName,LastName,Department,Site } @('FirstName','LastName','Department','Site') 'CSV file has required columns.' }
            return Test-B1AdObjectTerms "Resolve-DnsName cross-site names; Test-NetConnection $($profile.CrossTarget) -Port 445" { $profile.CrossNames | ForEach-Object { Resolve-DnsName $_ }; Test-NetConnection $profile.CrossTarget -Port 445 } @('TcpTestSucceeded') 'Cross-site DNS/SMB evidence is present.'
        }
        9 { return Test-B1CommandWarn 'Get-Content C:\Skills\Import-B1Users.ps1' { Get-Content 'C:\Skills\Import-B1Users.ps1' } 'Review script content for OU, user and group membership automation.' }
        10 { return Test-B1CommandWarn 'Run Import-B1Users.ps1 twice and inspect output' { Test-Path 'C:\Skills\Import-B1Users.ps1'; Get-ChildItem 'C:\Skills' } 'Idempotency requires reviewing two script runs and AD object state.' }
        11 { return Test-B1CommandWarn 'net use' { net use } 'Review mapped drives under intended Shanghai/IT/GUEST users.' }
        12 { return Test-B1CommandWarn 'File access smoke commands' { Test-Path '\\files.nb-b1.local\Common'; Test-Path '\\files.nb-b1.local\IT'; Test-Path '\\SHA-FS01\Home$' } 'Run create/read/delete tests under different users and review output.' }
        13 { return Test-B1AdObjectTerms "Resolve-DnsName cross-site names; Test-NetConnection $($profile.CrossTarget) -Port 445" { $profile.CrossNames | ForEach-Object { Resolve-DnsName $_ }; Test-NetConnection $profile.CrossTarget -Port 445 } @('TcpTestSucceeded') 'Cross-site DNS/SMB evidence is present.' }
        14 { return Test-B1AdObjectTerms 'git -C C:\Skills status; git -C C:\Skills log --oneline -1' { git -C 'C:\Skills' status; git -C 'C:\Skills' log --oneline -1 } @('final commit') 'Git final commit evidence is visible.' }
        15 { return Test-B1AdObjectTerms 'Get-Content C:\Skills\B1-selfcheck.txt' { Get-Content 'C:\Skills\B1-selfcheck.txt' } @('AD','DNS','DHCP') 'Self-check file contains infrastructure checks.' }
    }
}

function Test-B1DmzAspect {
    param([string]$HostKey, [int]$Seq)
    $profile = if ($HostKey -eq 'SHA-WEB01') {
        @{ IPs=@('10.21.10.11'); Gateways=@('10.21.10.1'); Dns=@(); Name='sha-web01.nb-b1.local' }
    } else {
        @{ IPs=@('10.21.10.12'); Gateways=@('10.21.10.1'); Dns=@(); Name='sha-app01.nb-b1.local' }
    }
    switch ($Seq) {
        1 { $r1=Test-B1Hostname $HostKey; $r2=Test-B1IpProfile $profile; if ($r1[0] -eq 'PASS' -and $r2[0] -eq 'PASS') { return @('PASS','Hostname, IP and gateway match.') }; return @('FAIL', "$($r1[1]); $($r2[1])") }
        2 { return Test-B1Workgroup $HostKey }
        3 { return Test-B1AdObjectTerms "Resolve-DnsName $($profile.Name); Test-Connection $($profile.Name)" { Resolve-DnsName $profile.Name -ErrorAction SilentlyContinue; Test-Connection $profile.Name -Count 2 -ErrorAction SilentlyContinue } @('nb-b1.local') 'DNS/PTR/reachability evidence is present.' }
    }
}

function Test-B1InetAspect {
    param([string]$HostKey, [int]$Seq)
    $profiles = @{
        'INET-SRV01' = @{ IPs=@('198.18.200.10'); Gateways=@('198.18.200.1') }
        'INET-CL01' = @{ IPs=@('198.18.201.10'); Gateways=@('198.18.201.1') }
        'ISP-SHA01' = @{ IPs=@('198.18.100.1','198.18.200.1','203.0.113.2'); Gateways=@('203.0.113.1') }
        'ISP-BJ01' = @{ IPs=@('198.18.101.1','198.18.201.1','203.0.113.1'); Gateways=@('203.0.113.2') }
    }
    $profile = $profiles[$HostKey]
    switch ($Seq) {
        1 {
            if (-not $profile) { return @('WARN', "No Internet-zone addressing profile is defined for $HostKey.") }
            $r1 = Test-B1Hostname $HostKey
            $r2 = Test-B1IpProfile $profile
            if ($r1[0] -eq 'PASS' -and $r2[0] -eq 'PASS') { return @('PASS', 'Local Internet-zone hostname, IP and gateway match the addressing plan.') }
            return @('FAIL', "$($r1[1]); $($r2[1])")
        }
        2 {
            $r = Invoke-B1Evidence 'Test-Connection 198.18.200.10/198.18.201.10; Resolve-DnsName www.internet.lab -Server 198.18.200.10; Test-NetConnection 198.18.200.10 -Port 80' {
                "Ping INET-SRV01 198.18.200.10=$(Test-Connection '198.18.200.10' -Count 2 -Quiet -ErrorAction SilentlyContinue)"
                "Ping INET-CL01 198.18.201.10=$(Test-Connection '198.18.201.10' -Count 2 -Quiet -ErrorAction SilentlyContinue)"
                $dns = @(Resolve-DnsName 'www.internet.lab' -Server '198.18.200.10' -ErrorAction SilentlyContinue)
                "DNS www.internet.lab via 198.18.200.10=$([bool]$dns.Count)"
                if ($dns.Count -gt 0) { $dns | Select-Object Name,Type,IPAddress,NameHost }
                "HTTP 198.18.200.10:80=$(Test-NetConnection '198.18.200.10' -Port 80 -InformationLevel Quiet -WarningAction SilentlyContinue)"
            } -AllowError
            $required = @(
                'Ping INET-SRV01 198.18.200.10=True',
                'Ping INET-CL01 198.18.201.10=True',
                'DNS www.internet.lab via 198.18.200.10=True'
            )
            $missing = @()
            foreach ($term in $required) {
                if ($r.Text -notmatch [regex]::Escape($term)) { $missing += $term }
            }
            if ($missing.Count -eq 0) { return @('PASS', 'Internet-zone reachability and DNS test name are proven.') }
            return @('FAIL', "Missing expected Internet-zone evidence: $($missing -join ', ')")
        }
    }
}

function Invoke-B1Aspect {
    param([string]$HostKey, [object]$Aspect)
    $parts = $Aspect.AspectID -split '\.'
    $group = $parts[0]
    $seq = [int]$parts[1]
    switch ($group) {
        'A1' { return Test-B1RouterAspect $HostKey $seq }
        'B1' { return Test-B1RouterAspect $HostKey $seq }
        'C1' { return Test-B1ShaDcAspect $seq }
        'D1' { return Test-B1BjDcAspect $seq }
        'E1' { return Test-B1FileServerAspect $HostKey $seq }
        'F1' { return Test-B1FileServerAspect $HostKey $seq }
        'G1' { return Test-B1ClientAspect $HostKey $seq }
        'H1' { return Test-B1ClientAspect $HostKey $seq }
        'I1' { return Test-B1DmzAspect $HostKey $seq }
        'J1' { return Test-B1DmzAspect $HostKey $seq }
        'K1' { return Test-B1InetAspect $HostKey $seq }
    }
    return @('WARN', "No evaluator implemented for $($Aspect.AspectID).")
}

function Write-B1Summary {
    $rows = @($script:B1ResultRows)
    $total = 0.0
    $pass = 0.0
    $fail = 0.0
    $warn = 0.0
    $counts = @{}
    foreach ($row in $rows) {
        $mark = [double]$row.MaxMark
        $total += $mark
        if (-not $counts.ContainsKey($row.Status)) { $counts[$row.Status] = 0 }
        $counts[$row.Status] += 1
        switch ($row.Status) {
            'PASS' { $pass += $mark }
            'FAIL' { $fail += $mark }
            'WARN' { $warn += $mark }
        }
    }
    $lines = @(
        'B1 Local Evaluation Summary',
        '===========================',
        "Passed marks: $([math]::Round($pass,2)) / $([math]::Round($total,2))",
        "Failed marks: $([math]::Round($fail,2))",
        "Warn marks:   $([math]::Round($warn,2))",
        '',
        'Counts:'
    )
    foreach ($key in ($counts.Keys | Sort-Object)) {
        $lines += "  $key`: $($counts[$key])"
    }
    if ($script:B1ReportEnabled) {
        Set-Content -LiteralPath $script:SummaryPath -Value ($lines -join [Environment]::NewLine) -Encoding UTF8
    }
    Write-Host ''
    Write-B1Log ($lines -join [Environment]::NewLine) DarkGray
}

function Invoke-B1HostChecks {
    param(
        [Parameter(Mandatory=$true)][string]$HostKey,
        [switch]$Report,
        [string]$ReportDir,
        [switch]$NoPause,
        [string]$StartFromAspect
    )
    $HostKey = $HostKey.ToUpperInvariant()
    $script:PauseBetweenChecks = -not $NoPause
    $enableReport = $Report -or (-not [string]::IsNullOrWhiteSpace($ReportDir))
    Initialize-B1Report -HostKey $HostKey -ReportDir $ReportDir -EnableReport:$enableReport
    Write-B1Section "B1 local checks for $HostKey"
    if ($script:B1ReportEnabled) {
        Write-B1Log "Каталог отчета: $script:ReportDir" DarkGray
    } else {
        Write-B1Log 'Отчет: отключен. Для записи отчета используйте -Report или -ReportDir <path>.' DarkGray
    }
    $criteria = @(Get-B1Criteria -HostKey $HostKey)
    if ($criteria.Count -eq 0) {
        throw "No criteria found for host $HostKey in $script:CriteriaMapPath"
    }
    foreach ($aspect in $criteria) {
        if ($StartFromAspect -and ([string]::Compare($aspect.AspectID, $StartFromAspect, [System.StringComparison]::OrdinalIgnoreCase) -lt 0)) {
            continue
        }
        Start-B1Aspect $aspect
        try {
            $result = Invoke-B1Aspect -HostKey $HostKey -Aspect $aspect
            Complete-B1Aspect -Aspect $aspect -Status $result[0] -Message $result[1]
        } catch {
            $exceptionText = $_.Exception.ToString()
            Invoke-B1Evidence 'Unhandled checker exception' { $exceptionText } -AllowError | Out-Null
            Complete-B1Aspect -Aspect $aspect -Status 'WARN' -Message "Checker exception: $($_.Exception.Message)"
        }
    }
    Write-B1Summary
}
