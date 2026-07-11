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
$script:B1CheckerVersion = '2026-07-11.14'

function Test-B1LengthOnlyText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $nonEmptyLines = @($Text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($nonEmptyLines.Count -eq 0) { return $false }

    $hasLengthValue = $false
    foreach ($line in $nonEmptyLines) {
        if ($line -match '^\s*Length\s*:\s*\d+\s*$') {
            $hasLengthValue = $true
            continue
        }
        if ($line -match '^\s*Length\s*$' -or $line -match '^\s*-{3,}\s*$' -or $line -match '^\s*\d+\s*$') {
            continue
        }
        return $false
    }
    return $hasLengthValue -or ($nonEmptyLines -contains 'Length')
}

function Add-B1TextItem {
    param(
        [object]$Value,
        [System.Collections.Generic.List[string]]$Lines
    )
    if ($null -eq $Value) { return }

    $baseValue = $Value.PSObject.BaseObject
    if ($baseValue -is [string]) {
        $Lines.Add($baseValue.TrimEnd())
        return
    }
    if ($baseValue -is [System.ValueType]) {
        $Lines.Add(([string]$baseValue).TrimEnd())
        return
    }
    if ($baseValue -is [System.Collections.IEnumerable] -and -not ($baseValue -is [System.Collections.IDictionary])) {
        foreach ($item in $baseValue) {
            Add-B1TextItem -Value $item -Lines $Lines
        }
        return
    }

    $formatted = (($Value | Out-String -Width 4096).TrimEnd())
    if (Test-B1LengthOnlyText $formatted) {
        $fallback = ([string]$Value.PSObject.BaseObject).TrimEnd()
        if (-not [string]::IsNullOrWhiteSpace($fallback) -and -not (Test-B1LengthOnlyText $fallback)) {
            $Lines.Add($fallback)
            return
        }
    }
    $Lines.Add($formatted)
}

function ConvertTo-B1Text {
    param([object]$Value)
    if ($null -eq $Value) { return '' }

    $lines = New-Object System.Collections.Generic.List[string]
    Add-B1TextItem -Value $Value -Lines $lines
    $result = (($lines -join [Environment]::NewLine).TrimEnd())
    if (Test-B1LengthOnlyText $result) {
        $fallbackLines = New-Object System.Collections.Generic.List[string]
        foreach ($item in @($Value)) {
            if ($null -eq $item) { continue }
            $text = ([string]$item.PSObject.BaseObject).TrimEnd()
            if (-not [string]::IsNullOrWhiteSpace($text) -and -not (Test-B1LengthOnlyText $text)) {
                $fallbackLines.Add($text)
            }
        }
        if ($fallbackLines.Count -gt 0) {
            return (($fallbackLines -join [Environment]::NewLine).TrimEnd())
        }
        return '(вывод команды получен PowerShell как объекты Length; native output could not be recovered as text)'
    }
    return $result
}

function Invoke-B1NativeText {
    param([string[]]$Commands)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($command in @($Commands)) {
        if ([string]::IsNullOrWhiteSpace($command)) { continue }
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $env:ComSpec
        $psi.Arguments = "/d /c $command"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [Console]::OutputEncoding
        $psi.StandardErrorEncoding = [Console]::OutputEncoding

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $psi
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()

        $text = (($stdout + $stderr).TrimEnd())
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            foreach ($line in @($text -split "`r?`n")) {
                $lines.Add($line)
            }
        } elseif ($process.ExitCode -ne 0) {
            $lines.Add("ExitCode=$($process.ExitCode)")
        }
    }
    return (($lines -join [Environment]::NewLine).TrimEnd())
}

function Select-B1RelevantOutput {
    param(
        [string]$Text,
        [string[]]$RelevantTerms = @(),
        [string]$RelevantPattern,
        [int]$ContextLines = 1
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }
    if ($Text -eq '(пустой вывод)') { return $Text }

    $terms = @($RelevantTerms | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $filterRequested = $terms.Count -gt 0 -or -not [string]::IsNullOrWhiteSpace($RelevantPattern)
    if (-not $filterRequested) { return $Text }

    $lines = @($Text -split "`r?`n")
    $include = @{}
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $matched = $false
        if (-not [string]::IsNullOrWhiteSpace($RelevantPattern) -and $line -match $RelevantPattern) {
            $matched = $true
        }
        if (-not $matched) {
            foreach ($term in $terms) {
                if ($line.IndexOf($term, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $matched = $true
                    break
                }
            }
        }
        if ($matched) {
            $from = [Math]::Max(0, $i - $ContextLines)
            $to = [Math]::Min($lines.Count - 1, $i + $ContextLines)
            for ($j = $from; $j -le $to; $j++) {
                $include[$j] = $true
            }
        }
    }

    if ($include.Count -eq 0) {
        return '(релевантные строки не найдены; полный вывод скрыт, решение принято по полному выводу команды)'
    }

    $selected = @($include.Keys | Sort-Object { [int]$_ })
    $out = @()
    foreach ($idx in $selected) {
        $lineIndex = [int]$idx
        $out += $lines[$lineIndex]
    }
    return (($out -join [Environment]::NewLine).TrimEnd())
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

function Write-B1VersionBanner {
    param([string]$HostKey)
    $commonPath = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($commonPath)) { $commonPath = Join-Path $PSScriptRoot 'b1-common.ps1' }
    $criteriaHash = ''
    try {
        if (Test-Path -LiteralPath $script:CriteriaMapPath) {
            $criteriaHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $script:CriteriaMapPath).Hash.Substring(0, 12)
        }
    } catch {
        $criteriaHash = 'unavailable'
    }
    Write-B1Log "B1 checker version: $script:B1CheckerVersion" Green
    Write-B1Log "B1 host: $HostKey" DarkGray
    Write-B1Log "B1 common loaded from: $commonPath" DarkGray
    Write-B1Log "B1 root: $script:B1Root" DarkGray
    Write-B1Log "B1 criteria: $script:CriteriaMapPath sha256:$criteriaHash" DarkGray
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
    $internetZoneHosts = @('INET-SRV01','INET-CL01','ISP-SHA01','ISP-BJ')
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
        [string[]]$RelevantTerms = @(),
        [string]$RelevantPattern,
        [int]$ContextLines = 1,
        [switch]$AllowError
    )
    Write-B1Log "Команда: $Command" Cyan
    try {
        $value = & $ScriptBlock
        $text = ConvertTo-B1Text $value
        if ([string]::IsNullOrWhiteSpace($text)) { $text = '(пустой вывод)' }
        $displayText = Select-B1RelevantOutput -Text $text -RelevantTerms $RelevantTerms -RelevantPattern $RelevantPattern -ContextLines $ContextLines
        if (Test-B1LengthOnlyText $displayText) {
            $displayText = '(вывод скрыт: PowerShell получил строки как объекты Length. В этой версии native-команды запускаются через cmd /d /c; если вы видите это сообщение, пришлите полный блок команды.)'
        }
        if ($displayText -ne $text) {
            Write-B1Log 'Фактический вывод (отфильтровано до релевантных строк):' Blue
        } else {
            Write-B1Log 'Фактический вывод:' Blue
        }
        Write-B1Log $displayText Gray
        return [pscustomobject]@{ Ok = $true; Value = $value; Text = $text; DisplayText = $displayText; Error = $null }
    } catch {
        $text = $_.Exception.Message
        Write-B1Log 'Фактический вывод:' Blue
        Write-B1Log "[ERROR] $text" Red
        if (-not $AllowError) {
            return [pscustomobject]@{ Ok = $false; Value = $null; Text = "[ERROR] $text"; DisplayText = "[ERROR] $text"; Error = $_ }
        }
        return [pscustomobject]@{ Ok = $true; Value = $null; Text = "[ERROR] $text"; DisplayText = "[ERROR] $text"; Error = $_ }
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
    $ips = if ($Profile.ContainsKey('IPs')) { @($Profile['IPs']) } else { @() }
    $dnsServers = if ($Profile.ContainsKey('Dns')) { @($Profile['Dns']) } else { @() }
    $gateways = if ($Profile.ContainsKey('Gateways')) { @($Profile['Gateways']) } else { @() }
    $expectedTerms = @($ips + $dnsServers + $gateways) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $r = Invoke-B1Evidence 'Get-NetIPConfiguration | show Interface/IP/Gateway; Get-DnsClientServerAddress -AddressFamily IPv4; Get-NetRoute -DestinationPrefix 0.0.0.0/0' {
        $configs = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4Address })
        foreach ($cfg in $configs) {
            $gateway = (@($cfg.IPv4DefaultGateway | ForEach-Object { $_.NextHop }) -join ',')
            foreach ($addr in @($cfg.IPv4Address)) {
                "IPv4 Interface=$($cfg.InterfaceAlias); Address=$($addr.IPAddress)/$($addr.PrefixLength); Gateway=$gateway"
            }
        }
        $dnsRows = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.ServerAddresses })
        foreach ($dnsRow in $dnsRows) {
            "DNS Interface=$($dnsRow.InterfaceAlias); Servers=$(@($dnsRow.ServerAddresses) -join ',')"
        }
        $routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
        foreach ($route in $routes) {
            "DefaultRoute Destination=$($route.DestinationPrefix); NextHop=$($route.NextHop); Interface=$($route.InterfaceAlias); Metric=$($route.RouteMetric)"
        }
    } -RelevantTerms $expectedTerms -ContextLines 0 -AllowError
    $text = $r.Text
    $missing = @()
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
    $invalidTargets = @(@($Targets) | Where-Object { $_ -match '^198\.18\.10[01]\.31$' })
    if ($invalidTargets.Count -gt 0) {
        return @('FAIL', "Obsolete checker path requested invalid WAN target(s): $($invalidTargets -join ', '). Update B1 common script; A1.07/B1.07 must use INET-SRV01 198.18.200.10 service checks.")
    }
    $bad = @()
    foreach ($target in $Targets) {
        $r = Invoke-B1Evidence "Test-Connection $target -Count 2 -Quiet" { Test-Connection $target -Count 2 -Quiet }
        if (-not [bool]$r.Value) { $bad += $target }
    }
    if ($bad.Count -eq 0) { return @('PASS', "All targets reachable: $($Targets -join ', ')") }
    return @('FAIL', "Unreachable targets: $($bad -join ', ')")
}

function Test-B1RouterInternetServices {
    param([hashtable]$Profile)
    $nextHop = @($Profile['Gateways'])[0]
    $staticPrefixes = @($Profile['Routes'].Keys | Sort-Object)
    $routePrefixes = @('0.0.0.0/0') + $staticPrefixes + @('198.18.200.0/24','198.18.201.0/24')
    $required = @(
        'DNS 198.18.200.10:53=True',
        'HTTP 198.18.200.10:80=True'
    )
    $r = Invoke-B1Evidence 'Get-NetRoute route-table checks; Find-NetRoute 198.18.200.10/198.18.201.10; Test-NetConnection 198.18.200.10 -Port 53/80' {
        foreach ($prefix in $routePrefixes) {
            "Route $prefix"
            Get-NetRoute -DestinationPrefix $prefix -ErrorAction SilentlyContinue |
                Select-Object DestinationPrefix,NextHop,InterfaceAlias,RouteMetric
        }
        "Best route to 198.18.200.10"
        Find-NetRoute -RemoteIPAddress '198.18.200.10' -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty SelectedNetRoute -ErrorAction SilentlyContinue |
            Select-Object DestinationPrefix,NextHop,InterfaceAlias,RouteMetric
        "Best route to 198.18.201.10"
        Find-NetRoute -RemoteIPAddress '198.18.201.10' -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty SelectedNetRoute -ErrorAction SilentlyContinue |
            Select-Object DestinationPrefix,NextHop,InterfaceAlias,RouteMetric
        "DNS 198.18.200.10:53=$(Test-NetConnection '198.18.200.10' -Port 53 -InformationLevel Quiet -WarningAction SilentlyContinue)"
        "HTTP 198.18.200.10:80=$(Test-NetConnection '198.18.200.10' -Port 80 -InformationLevel Quiet -WarningAction SilentlyContinue)"
    } -RelevantTerms ($routePrefixes + @($nextHop,'198.18.200.10','198.18.201.10') + $required) -ContextLines 0 -AllowError

    $missing = @()
    if ($r.Text -notmatch [regex]::Escape($nextHop)) { $missing += "next-hop $nextHop" }
    foreach ($term in $required) {
        if ($r.Text -notmatch [regex]::Escape($term)) { $missing += $term }
    }
    if ($missing.Count -eq 0) { return @('PASS', 'Route table and DNS/HTTP service checks to INET-SRV01 are proven.') }
    return @('FAIL', "Missing expected route/service evidence: $($missing -join ', ')")
}

function Test-B1StaticRoutes {
    param([hashtable]$Routes)
    $bad = @()
    foreach ($prefix in $Routes.Keys) {
        $expectedNextHop = $Routes[$prefix]
        $r = Invoke-B1Evidence "Get-NetRoute -DestinationPrefix $prefix" {
            Get-NetRoute -DestinationPrefix $prefix -ErrorAction SilentlyContinue |
                Select-Object DestinationPrefix,NextHop,InterfaceAlias,RouteMetric
        } -RelevantTerms @($prefix, $expectedNextHop) -ContextLines 0 -AllowError
        if ($r.Text -notmatch [regex]::Escape($expectedNextHop)) {
            $bad += "$prefix via $expectedNextHop"
        }
    }
    if ($bad.Count -eq 0) { return @('PASS', 'Static routes have expected next-hop values.') }
    return @('FAIL', "Routes not proven: $($bad -join ', ')")
}

function Test-B1DomainJoin {
    param([string[]]$ExpectedOuFragments)
    $cs = Invoke-B1Evidence '(Get-CimInstance Win32_ComputerSystem).PartOfDomain; Get-ADComputer/LDAP DistinguishedName' {
        Get-CimInstance Win32_ComputerSystem | Select-Object Name,Domain,PartOfDomain
    } -RelevantTerms @('Name','Domain','PartOfDomain','True') -ContextLines 0
    $part = (Get-CimInstance Win32_ComputerSystem).PartOfDomain
    if (-not $part) { return @('FAIL', 'Computer is not domain joined.') }
    $expectedTerms = @($env:COMPUTERNAME) + @($ExpectedOuFragments | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $ad = $null
    if (Get-Command Get-ADComputer -ErrorAction SilentlyContinue) {
        $ad = Invoke-B1Evidence "Get-ADComputer $env:COMPUTERNAME -Properties DistinguishedName" {
            Get-ADComputer $env:COMPUTERNAME -Properties DistinguishedName | Select-Object Name,DistinguishedName
        } -RelevantTerms $expectedTerms -ContextLines 2 -AllowError
    } else {
        $ad = Invoke-B1Evidence "LDAP query computer DistinguishedName for $env:COMPUTERNAME" {
            $csLocal = Get-CimInstance Win32_ComputerSystem
            $ldapRoots = New-Object System.Collections.Generic.List[string]
            $ldapRoots.Add('LDAP://RootDSE')
            if (-not [string]::IsNullOrWhiteSpace($csLocal.Domain)) {
                $ldapRoots.Add(("LDAP://{0}/RootDSE" -f $csLocal.Domain))
                $nltest = Invoke-B1NativeText @("nltest /dsgetdc:$($csLocal.Domain)")
                $dcLine = @($nltest -split "`r?`n" | Where-Object { $_ -match '\\\\[^ ]+' } | Select-Object -First 1)
                if ($dcLine) {
                    $dcName = ([regex]::Match($dcLine, '\\\\([^ ]+)')).Groups[1].Value
                    if (-not [string]::IsNullOrWhiteSpace($dcName)) {
                        $ldapRoots.Add(("LDAP://{0}/RootDSE" -f $dcName))
                    }
                }
            }
            $root = $null
            $lastError = $null
            foreach ($rootPath in @($ldapRoots | Select-Object -Unique)) {
                try {
                    $candidateRoot = [ADSI]$rootPath
                    [void]$candidateRoot.defaultNamingContext
                    $root = $candidateRoot
                    "LDAPRoot=$rootPath"
                    break
                } catch {
                    $lastError = $_.Exception.Message
                }
            }
            if ($null -eq $root) {
                throw "LDAP RootDSE unavailable. Last error: $lastError"
            }
            $searchRoot = [ADSI]("LDAP://{0}" -f $root.defaultNamingContext)
            $searcher = New-Object DirectoryServices.DirectorySearcher($searchRoot)
            $searcher.Filter = "(&(objectCategory=computer)(sAMAccountName=$env:COMPUTERNAME`$))"
            [void]$searcher.PropertiesToLoad.Add('distinguishedName')
            $found = $searcher.FindOne()
            if ($null -ne $found -and $found.Properties['distinguishedname'].Count -gt 0) {
                [pscustomobject]@{
                    Name = $env:COMPUTERNAME
                    DistinguishedName = [string]$found.Properties['distinguishedname'][0]
                }
            }
        } -RelevantTerms $expectedTerms -ContextLines 2 -AllowError
    }
    if (-not $ad -or -not $ad.Ok -or $ad.Error -or [string]::IsNullOrWhiteSpace($ad.Text) -or $ad.Text -match '^\[ERROR\]') {
        return @('WARN', 'Domain joined, but AD/LDAP query is unavailable for OU validation.')
    }
    foreach ($fragment in $ExpectedOuFragments) {
        if ($fragment -and $ad.Text -notmatch [regex]::Escape($fragment)) {
            return @('FAIL', "Domain joined, but AD OU fragment not found: $fragment")
        }
    }
    return @('PASS', 'Domain join and AD placement are proven.')
}

function Test-B1Workgroup {
    param([string]$ExpectedName)
    $r = Invoke-B1Evidence '(Get-CimInstance Win32_ComputerSystem) | Select Name,Domain,PartOfDomain' {
        Get-CimInstance Win32_ComputerSystem | Select-Object Name,Domain,PartOfDomain
    } -RelevantTerms @($ExpectedName, 'PartOfDomain', 'False') -ContextLines 0
    $cs = Get-CimInstance Win32_ComputerSystem
    if (($cs.Name.ToUpperInvariant() -eq $ExpectedName) -and (-not $cs.PartOfDomain)) {
        return @('PASS', 'Host is a workgroup host as expected.')
    }
    return @('FAIL', "Name/domain state mismatch. Name=$($cs.Name), PartOfDomain=$($cs.PartOfDomain)")
}

function Test-B1AdObjectTerms {
    param([string]$Command, [scriptblock]$ScriptBlock, [string[]]$Terms, [string]$PassMessage)
    $r = Invoke-B1Evidence $Command $ScriptBlock -RelevantTerms $Terms -ContextLines 0
    if (-not $r.Ok) { return @('FAIL', 'Command failed.') }
    $missing = @()
    foreach ($t in $Terms) {
        if ($r.Text -notmatch [regex]::Escape($t)) { $missing += $t }
    }
    if ($missing.Count -eq 0) { return @('PASS', $PassMessage) }
    return @('FAIL', "Missing expected terms: $($missing -join ', ')")
}

function Test-B1CommandWarn {
    param(
        [string]$Command,
        [scriptblock]$ScriptBlock,
        [string]$Message,
        [string[]]$RelevantTerms = @(),
        [string]$RelevantPattern
    )
    Invoke-B1Evidence $Command $ScriptBlock -RelevantTerms $RelevantTerms -RelevantPattern $RelevantPattern -ContextLines 0 -AllowError | Out-Null
    return @('WARN', $Message)
}

function Test-B1LapsPassword {
    param([string]$HostKey)
    $r = Invoke-B1Evidence "Get-LapsADPassword -Identity $HostKey -AsPlainText" {
        Get-LapsADPassword -Identity $HostKey -AsPlainText |
            Select-Object ComputerName,DistinguishedName,Account,Password,PasswordUpdateTime,ExpirationTimestamp,DecryptionStatus
    } -RelevantTerms @($HostKey,'Password','ExpirationTimestamp','PasswordUpdateTime','Success') -ContextLines 1 -AllowError
    if (-not $r.Ok) { return @('FAIL', 'LAPS query failed.') }
    $items = @($r.Value)
    $hasPassword = $false
    $hasTime = $false
    $successOk = $true
    foreach ($item in $items) {
        if (-not $item) { continue }
        if ($item.PSObject.Properties['Password'] -and -not [string]::IsNullOrWhiteSpace([string]$item.Password)) {
            $hasPassword = $true
        }
        if (($item.PSObject.Properties['ExpirationTimestamp'] -and -not [string]::IsNullOrWhiteSpace([string]$item.ExpirationTimestamp)) -or
            ($item.PSObject.Properties['PasswordUpdateTime'] -and -not [string]::IsNullOrWhiteSpace([string]$item.PasswordUpdateTime))) {
            $hasTime = $true
        }
        if ($item.PSObject.Properties['DecryptionStatus'] -and ([string]$item.DecryptionStatus) -notmatch 'Success') {
            $successOk = $false
        }
    }
    if ($hasPassword -and $hasTime -and $successOk) {
        return @('PASS', "Windows LAPS password exists in AD for $HostKey.")
    }
    $missing = @()
    if (-not $hasPassword) { $missing += 'Password' }
    if (-not $hasTime) { $missing += 'ExpirationTimestamp/PasswordUpdateTime' }
    if (-not $successOk) { $missing += 'DecryptionStatus=Success' }
    return @('FAIL', "LAPS evidence incomplete: $($missing -join ', ')")
}

function Test-B1ClientFirewallBaseline {
    $r = Invoke-B1Evidence "Get-NetFirewallProfile Domain; ICMP Echo allow rules; Remote Desktop Users members" {
        $domainProfile = Get-NetFirewallProfile -Profile Domain
        $enabledAllowRules = @(Get-NetFirewallRule -Enabled True -Action Allow -ErrorAction SilentlyContinue)
        $icmpRules = New-Object System.Collections.Generic.List[object]
        foreach ($rule in $enabledAllowRules) {
            $portFilters = @(Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue)
            foreach ($filter in $portFilters) {
                if ($filter.Protocol -match 'ICMPv4|ICMPv6|1|58' -and ($filter.IcmpType -in @('8','Any','*') -or [string]::IsNullOrWhiteSpace([string]$filter.IcmpType))) {
                    $icmpRules.Add([pscustomobject]@{
                        DisplayName = $rule.DisplayName
                        Direction = $rule.Direction
                        Action = $rule.Action
                        Profile = $rule.Profile
                        Protocol = $filter.Protocol
                        IcmpType = $filter.IcmpType
                    })
                }
            }
        }
        $rdpMembers = @(Get-LocalGroupMember 'Remote Desktop Users' -ErrorAction SilentlyContinue)
        $riskyRdpMembers = @(
            $rdpMembers |
                Where-Object {
                    $_.Name -match '\\(Domain Users|Authenticated Users|Guests|Guest)$|^(Everyone|Authenticated Users|Guests|Guest)$'
                }
        )

        [pscustomobject]@{
            Check = 'DomainFirewallEnabled'
            Value = [bool]$domainProfile.Enabled
        }
        [pscustomobject]@{
            Check = 'DefaultInboundAction'
            Value = [string]$domainProfile.DefaultInboundAction
        }
        [pscustomobject]@{
            Check = 'IcmpEchoAllowed'
            Value = ($icmpRules.Count -gt 0)
        }
        [pscustomobject]@{
            Check = 'IcmpEchoAllowRuleCount'
            Value = $icmpRules.Count
        }
        $icmpRules | Select-Object DisplayName,Direction,Action,Profile,Protocol,IcmpType
        [pscustomobject]@{
            Check = 'RemoteDesktopUsersMemberCount'
            Value = $rdpMembers.Count
        }
        if ($rdpMembers.Count -eq 0) {
            [pscustomobject]@{
                Check = 'RemoteDesktopUsersMembers'
                Value = 'None'
            }
        } else {
            $rdpMembers | Select-Object Name,ObjectClass,PrincipalSource
        }
        [pscustomobject]@{
            Check = 'RiskyRdpMemberCount'
            Value = $riskyRdpMembers.Count
        }
    } -RelevantTerms @('DomainFirewallEnabled','IcmpEchoAllowed','RemoteDesktopUsersMemberCount','RiskyRdpMemberCount','True','False') -ContextLines 2 -AllowError

    if (-not $r.Ok) { return @('FAIL', 'Firewall/RDP baseline query failed.') }
    $items = @($r.Value | Where-Object { $_ })
    $domainEnabled = $items | Where-Object { $_.PSObject.Properties['Check'] -and $_.Check -eq 'DomainFirewallEnabled' } | Select-Object -First 1
    $icmpAllowed = $items | Where-Object { $_.PSObject.Properties['Check'] -and $_.Check -eq 'IcmpEchoAllowed' } | Select-Object -First 1
    $riskyCount = $items | Where-Object { $_.PSObject.Properties['Check'] -and $_.Check -eq 'RiskyRdpMemberCount' } | Select-Object -First 1

    $missing = @()
    if (-not $domainEnabled -or -not [bool]$domainEnabled.Value) { $missing += 'Domain firewall enabled' }
    if (-not $icmpAllowed -or -not [bool]$icmpAllowed.Value) { $missing += 'ICMP Echo allow rule' }
    if ($riskyCount -and [int]$riskyCount.Value -gt 0) { $missing += 'no broad/risky Remote Desktop Users members' }
    if ($missing.Count -eq 0) {
        return @('PASS', 'Domain firewall is enabled, ICMP Echo is allowed, and no broad RDP group members were found.')
    }
    return @('FAIL', "Baseline mismatch: $($missing -join ', ')")
}

function Test-B1BitLockerDataVolume {
    $r = Invoke-B1Evidence 'Get-BitLockerVolume data volumes; manage-bde -status <detected data volume>' {
        $fixedLetters = @(
            Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
                Where-Object { $_.DeviceID -ne 'C:' } |
                Select-Object -ExpandProperty DeviceID
        )
        $volumes = @(
            foreach ($letter in $fixedLetters) {
                Get-BitLockerVolume -MountPoint $letter -ErrorAction SilentlyContinue
            }
        )
        $volumes |
            Select-Object MountPoint,VolumeType,VolumeStatus,EncryptionPercentage,ProtectionStatus,KeyProtector
        $candidate = @(
            $volumes |
                Where-Object {
                    $_.ProtectionStatus -eq 'On' -and
                    ($_.VolumeStatus -match 'Encrypted|EncryptionInProgress|FullyEncrypted') -and
                    ($_.KeyProtector | Out-String) -match 'Recovery'
                }
        ) | Select-Object -First 1
        if ($candidate) {
            "=== manage-bde $($candidate.MountPoint) ==="
            Invoke-B1NativeText @("manage-bde -status $($candidate.MountPoint)")
        }
    } -RelevantTerms @('MountPoint','ProtectionStatus','On','Recovery','FullyEncrypted','Percentage Encrypted') -ContextLines 3 -AllowError
    if (-not $r.Ok) { return @('FAIL', 'BitLocker data volume query failed.') }
    $volumes = @($r.Value | Where-Object { $_ -and $_.PSObject.Properties['MountPoint'] })
    $candidate = @(
        $volumes |
            Where-Object {
                $_.ProtectionStatus -eq 'On' -and
                ($_.VolumeStatus -match 'Encrypted|EncryptionInProgress|FullyEncrypted') -and
                ($_.KeyProtector | Out-String) -match 'Recovery'
            }
    ) | Select-Object -First 1
    if ($candidate) {
        return @('PASS', "BitLocker protection is enabled on data volume $($candidate.MountPoint) with recovery protector.")
    }
    return @('FAIL', 'No protected fixed data volume with a recovery protector was found.')
}

function Test-B1BitLockerRecoveryInAd {
    param([string]$HostKey)
    $r = Invoke-B1Evidence "Get BitLocker recovery objects for $HostKey via AD module or LDAP" {
        if (Get-Command Get-ADComputer -ErrorAction SilentlyContinue) {
            $comp = Get-ADComputer $HostKey -Properties DistinguishedName
            Get-ADObject -SearchBase $comp.DistinguishedName -LDAPFilter '(objectClass=msFVE-RecoveryInformation)' -Properties msFVE-RecoveryPassword |
                Select-Object Name,DistinguishedName,msFVE-RecoveryPassword
        } else {
            $root = [ADSI]'LDAP://RootDSE'
            $searchRoot = [ADSI]("LDAP://{0}" -f $root.defaultNamingContext)
            $computerSearcher = New-Object DirectoryServices.DirectorySearcher($searchRoot)
            $computerSearcher.Filter = "(&(objectCategory=computer)(sAMAccountName=$HostKey`$))"
            [void]$computerSearcher.PropertiesToLoad.Add('distinguishedName')
            $computer = $computerSearcher.FindOne()
            if ($null -eq $computer -or $computer.Properties['distinguishedname'].Count -eq 0) {
                return
            }
            $computerDn = [string]$computer.Properties['distinguishedname'][0]
            $recoveryRoot = [ADSI]("LDAP://{0}" -f $computerDn)
            $recoverySearcher = New-Object DirectoryServices.DirectorySearcher($recoveryRoot)
            $recoverySearcher.SearchScope = [DirectoryServices.SearchScope]::OneLevel
            $recoverySearcher.Filter = '(objectClass=msFVE-RecoveryInformation)'
            [void]$recoverySearcher.PropertiesToLoad.Add('distinguishedName')
            [void]$recoverySearcher.PropertiesToLoad.Add('msFVE-RecoveryPassword')
            foreach ($found in @($recoverySearcher.FindAll())) {
                [pscustomobject]@{
                    Name = [string]$found.Properties['name'][0]
                    DistinguishedName = [string]$found.Properties['distinguishedname'][0]
                    RecoveryPasswordPresent = ($found.Properties['msfve-recoverypassword'].Count -gt 0)
                }
            }
        }
    } -RelevantTerms @($HostKey,'msFVE-RecoveryInformation','RecoveryPassword','True') -ContextLines 2 -AllowError
    if (-not $r.Ok -or $r.Error -or $r.Text -match '^\[ERROR\]') {
        return @('WARN', "BitLocker recovery AD/LDAP query is unavailable for $HostKey.")
    }
    $items = @($r.Value | Where-Object { $_ })
    if ($items.Count -eq 0) {
        return @('FAIL', "No BitLocker recovery object found under $HostKey.")
    }
    foreach ($item in $items) {
        if (($item.PSObject.Properties['msFVE-RecoveryPassword'] -and -not [string]::IsNullOrWhiteSpace([string]$item.'msFVE-RecoveryPassword')) -or
            ($item.PSObject.Properties['RecoveryPasswordPresent'] -and [bool]$item.RecoveryPasswordPresent)) {
            return @('PASS', "BitLocker recovery information exists in AD for $HostKey.")
        }
    }
    return @('FAIL', "BitLocker recovery object exists for $HostKey, but recovery password is not visible.")
}

function Import-B1UsersCsvNormalized {
    param([string]$Path)
    $rawRows = @(Import-Csv -LiteralPath $Path -Delimiter ';')
    foreach ($row in $rawRows) {
        $normalized = [ordered]@{}
        foreach ($property in $row.PSObject.Properties) {
            $name = ([string]$property.Name).Trim()
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $normalized[$name] = ([string]$property.Value).Trim()
        }
        [pscustomobject]$normalized
    }
}

function Test-B1UsersCsv {
    $path = 'C:\Skills\b1-users.csv'
    $r = Invoke-B1Evidence "Import-Csv $path -Delimiter ';' | Select FirstName,LastName,Department,Site" {
        $rows = @(Import-B1UsersCsvNormalized -Path $path)
        (($rows | Select-Object FirstName,LastName,Department,Site | Format-Table -AutoSize | Out-String -Width 200).TrimEnd())
        "UserCount=$($rows.Count)"
    } -AllowError
    if (-not $r.Ok) { return @('FAIL', 'CSV import failed.') }
    $rows = @(Import-B1UsersCsvNormalized -Path $path)
    $requiredColumns = @('FirstName','LastName','Department','Site')
    $missingColumns = @()
    foreach ($column in $requiredColumns) {
        if ($rows.Count -eq 0 -or -not $rows[0].PSObject.Properties[$column]) { $missingColumns += $column }
    }
    if ($missingColumns.Count -gt 0) {
        return @('FAIL', "CSV missing expected columns: $($missingColumns -join ', ')")
    }
    if ($rows.Count -lt 8) {
        return @('FAIL', "CSV user count is $($rows.Count), expected at least 8.")
    }
    $emptyCells = @()
    foreach ($row in $rows) {
        foreach ($column in $requiredColumns) {
            if ([string]::IsNullOrWhiteSpace([string]$row.$column)) {
                $emptyCells += $column
            }
        }
    }
    if ($emptyCells.Count -gt 0) {
        return @('FAIL', "CSV has empty required values in: $((@($emptyCells) | Select-Object -Unique) -join ', ')")
    }
    return @('PASS', "CSV file has required columns and $($rows.Count) populated users.")
}

function Test-B1RepadminShowRepl {
    $r = Invoke-B1Evidence 'repadmin /showrepl' { Invoke-B1NativeText @('repadmin /showrepl') } -RelevantPattern '(?i)error|fail|successful|last attempt|source|destination|naming context' -ContextLines 0 -AllowError
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
            RelayServer = '10.21.20.20'
        }
        'BJ-RTR01' = @{
            IPs = @('198.18.101.10','10.31.20.1','10.31.30.1')
            Gateways = @('198.18.101.1')
            Routes = @{ '10.21.10.0/24' = '198.18.101.1'; '10.21.20.0/24' = '198.18.101.1'; '10.21.30.0/24' = '198.18.101.1' }
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
            } -RelevantTerms @('RemoteAccess','Running','Enabled','Forwarding') -ContextLines 0 -AllowError
            if ($r.Text -match 'Enabled|Running') { return @('PASS', 'Routing/forwarding evidence is present.') }
            return @('FAIL', 'Routing/forwarding is not proven.')
        }
        4 { return Test-B1StaticRoutes $p.Routes }
        5 {
            $r = Invoke-B1Evidence 'cmd /d /c "netsh routing ip relay show ifbinding"; cmd /d /c "netsh routing ip relay show global"' {
                Invoke-B1NativeText @(
                    'netsh routing ip relay show ifbinding',
                    'netsh routing ip relay show global'
                )
            } -RelevantTerms @($p.RelayServer,'Relay','DHCP','ifbinding') -ContextLines 0 -AllowError
            if ($r.Text -match [regex]::Escape($p.RelayServer)) { return @('PASS', "DHCP relay points to $($p.RelayServer).") }
            return @('WARN', 'DHCP relay evidence is not conclusive from local command output.')
        }
        6 {
            $r = Invoke-B1Evidence 'Get-NetNat; netsh routing ip nat show interface' {
                Get-NetNat -ErrorAction SilentlyContinue
                Invoke-B1NativeText @('netsh routing ip nat show interface')
            } -RelevantPattern '(?i)nat|interface|private|external|10\.21\.|10\.31\.' -ContextLines 0 -AllowError
            if ($r.Text -eq '(пустой вывод)' -or $r.Text -notmatch '10\.21\.|10\.31\.') { return @('PASS', 'NAT for private inter-site networks is not visible.') }
            return @('FAIL', 'NAT evidence mentions private inter-site networks.')
        }
        7 { return Test-B1RouterInternetServices $p }
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
            $r = Invoke-B1Evidence "Get-ADReplicationSubnet -Filter * | Where-Object Name -eq '10.21.10.0/24'" { Get-ADReplicationSubnet -Filter * | Where-Object Name -eq '10.21.10.0/24' } -RelevantTerms @('10.21.10.0/24') -ContextLines 0 -AllowError
            if ($r.Text -eq '(пустой вывод)') { return @('PASS', 'DMZ subnet is absent from AD Sites.') }
            return @('FAIL', 'DMZ subnet is present in AD Sites.')
        }
        10 { return Test-B1AdObjectTerms 'Get-ADReplicationSiteLink -Filter * | Select Name,Cost,ReplicationFrequencyInMinutes' { Get-ADReplicationSiteLink -Filter * | Select Name,Cost,ReplicationFrequencyInMinutes } @('100','15') 'Site link cost and interval are visible.' }
        11 {
            $r = Invoke-B1Evidence 'repadmin /replsummary; repadmin /showrepl' { Invoke-B1NativeText @('repadmin /replsummary','repadmin /showrepl') } -RelevantPattern '(?i)error|fail|successful|last attempt|source|destination|largest delta|total' -ContextLines 0 -AllowError
            if ($r.Text -match 'fails\s*:\s*0|0\s*/\s*\d+') { return @('PASS', 'Replication output does not show failures.') }
            return @('WARN', 'Review repadmin output for replication failures.')
        }
        12 { return Test-B1AdObjectTerms 'net share; Test-Path \\SHA-DC01\SYSVOL; Test-Path \\SHA-DC01\NETLOGON' { Invoke-B1NativeText @('net share'); "SYSVOL=$(Test-Path '\\SHA-DC01\SYSVOL')"; "NETLOGON=$(Test-Path '\\SHA-DC01\NETLOGON')" } @('SYSVOL','NETLOGON','SYSVOL=True','NETLOGON=True') 'SYSVOL and NETLOGON are available.' }
        13 { return Test-B1AdObjectTerms 'Get-DnsServerZone -Name nb-b1.local' { Get-DnsServerZone -Name 'nb-b1.local' | Select ZoneName,ZoneType,IsDsIntegrated } @('nb-b1.local','Primary','True') 'AD-integrated forward zone exists.' }
        14 { return Test-B1AdObjectTerms 'Get-DnsServerZone' { Get-DnsServerZone | Select ZoneName } @('10.21.10','10.21.20','10.21.30','10.31.20','10.31.30','198.18.100','198.18.101','198.18.200','198.18.201') 'Reverse zones are visible.' }
        15 { return Test-B1AdObjectTerms 'Resolve-DnsName host records -Server 10.21.20.10' { 'sha-rtr01','sha-dc01','sha-fs01','bj-rtr01','bj-dc02','bj-srv01','sha-web01','sha-app01','files','bj-files','intranet' | ForEach-Object { Resolve-DnsName "$_.nb-b1.local" -Server '10.21.20.10' -ErrorAction SilentlyContinue } } @('10.21.20.10','10.31.20.10') 'DNS A/CNAME resolution returns records.' }
        16 { return Test-B1AdObjectTerms 'Resolve-DnsName PTR records -Server 10.21.20.10' { '10.21.20.10','10.21.20.20','10.31.20.10','10.31.20.20','10.21.10.11','10.21.10.12' | ForEach-Object { Resolve-DnsName $_ -Server '10.21.20.10' -ErrorAction SilentlyContinue } } @('nb-b1.local') 'PTR lookups return domain names.' }
        17 { return Test-B1AdObjectTerms 'Resolve-DnsName _ldap/_kerberos SRV -Server 10.21.20.10' { Resolve-DnsName '_ldap._tcp.dc._msdcs.nb-b1.local' -Type SRV -Server '10.21.20.10'; Resolve-DnsName '_kerberos._tcp.nb-b1.local' -Type SRV -Server '10.21.20.10' } @('SHA-DC01','BJ-DC02') 'AD DS SRV records are visible.' }
        18 { return Test-B1AdObjectTerms 'Get-DnsServerForwarder' { Get-DnsServerForwarder | Select IPAddress } @('198.18.200.10') 'DNS forwarder points to simulated Internet DNS.' }
        19 { return Test-B1AdObjectTerms "Get-GPO -Name GPO-B1-Domain-Baseline; Get-GPInheritance -Target 'DC=nb-b1,DC=local'" { Get-GPO -Name 'GPO-B1-Domain-Baseline'; Get-GPInheritance -Target 'DC=nb-b1,DC=local' } @('GPO-B1-Domain-Baseline') 'Domain baseline GPO exists and inheritance is readable.' }
        20 { return Test-B1CommandWarn 'Get-GPOReport -Name GPO-B1-Domain-Baseline -ReportType Xml' { Get-GPOReport -Name 'GPO-B1-Domain-Baseline' -ReportType Xml } 'Review GPO XML output for banner, NB_TRAINING, LM hash prevention and Windows Update schedule.' -RelevantTerms @('NB_TRAINING','LegalNotice','NoLMHash','LMCompatibilityLevel','WindowsUpdate','ScheduledInstall') }
        21 { return Test-B1AdObjectTerms "Get-ADObject schema msLAPS-PasswordExpirationTime" { Get-ADObject -SearchBase (Get-ADRootDSE).SchemaNamingContext -LDAPFilter '(lDAPDisplayName=msLAPS-PasswordExpirationTime)' -Properties lDAPDisplayName | Select lDAPDisplayName } @('msLAPS-PasswordExpirationTime') 'Windows LAPS schema attribute exists.' }
        22 { return Test-B1CommandWarn "Find-LapsADExtendedRights -Identity 'OU=10-Workstations,DC=nb-b1,DC=local'" { Find-LapsADExtendedRights -Identity 'OU=10-Workstations,DC=nb-b1,DC=local' } 'Review output and confirm GG_LAPS_Readers has LAPS read rights.' -RelevantTerms @('GG_LAPS_Readers','msLAPS','ExtendedRight','Read') }
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
        9 { return Test-B1CommandWarn 'dcdiag /test:advertising /test:dns' { Invoke-B1NativeText @('dcdiag /test:advertising /test:dns') } 'Review dcdiag output and confirm Advertising/DNS have no critical failures.' -RelevantPattern '(?i)advertising|dns|passed|failed|error|warning|starting test' }
    }
}

function Test-B1FileServerAspect {
    param([string]$HostKey, [int]$Seq)
    $isSha = $HostKey -eq 'SHA-FS01'
    $profile = if ($isSha) {
        @{ IPs=@('10.21.20.20'); Dns=@('10.21.20.10'); DhcpDns=@('10.21.20.10','10.31.20.10'); Ou='00-Servers'; Scope='10.21.30.0'; Router='10.21.30.1'; Shares=@('Common','IT','Home$'); ShareTerms=@('Common','C:\Shares\Common','IT','C:\Shares\IT','Home$','C:\Shares\Home') }
    } else {
        @{ IPs=@('10.31.20.20'); Dns=@('10.31.20.10'); DhcpDns=@('10.31.20.10','10.21.20.10'); Ou='00-Servers'; Scope='10.31.30.0'; Router='10.31.30.1'; Shares=@('Branch'); ShareTerms=@('Branch','C:\Shares\Branch') }
    }

    if ($isSha) {
        switch ($Seq) {
            1 { $r1 = Test-B1Hostname $HostKey; $r2 = Test-B1IpProfile $profile; if ($r1[0] -eq 'PASS' -and $r2[0] -eq 'PASS') { return @('PASS','Hostname and IP profile are correct.') }; return @('FAIL', "$($r1[1]); $($r2[1])") }
            2 { return Test-B1AdObjectTerms 'Get-Service WinRM; Test-WSMan localhost' { Get-Service WinRM; Test-WSMan localhost } @('Running') 'WinRM is available for remote administration.' }
            3 { return Test-B1AdObjectTerms 'Get-DhcpServerInDC; Get-WindowsFeature DHCP' { Get-DhcpServerInDC; Get-WindowsFeature DHCP } @($HostKey,'DHCP') 'DHCP role and authorization evidence is present.' }
            4 { return Test-B1AdObjectTerms 'Get-DhcpServerv4Scope; Get-DhcpServerv4ExclusionRange' { Get-DhcpServerv4Scope | Select ScopeId,StartRange,EndRange,Name; Get-DhcpServerv4ExclusionRange -ScopeId $profile.Scope | Select ScopeId,StartRange,EndRange } @($profile.Scope,'100','119','200') 'Expected DHCP scope/range and exclusion are visible.' }
            5 { return Test-B1AdObjectTerms "Get-DhcpServerv4OptionValue -ScopeId $($profile.Scope)" { Get-DhcpServerv4OptionValue -ScopeId $profile.Scope } @($profile.Router,$profile.DhcpDns[0],$profile.DhcpDns[1],'nb-b1.local') 'DHCP router/DNS/suffix options are visible.' }
            6 { return Test-B1CommandWarn 'Get-DhcpServerv4DnsSetting' { Get-DhcpServerv4DnsSetting } 'Review dynamic DNS settings and confirm DHCP registers A/PTR records.' -RelevantTerms @('Dynamic','DNS','PTR','A','Update') }
            7 { return Test-B1AdObjectTerms 'Get-SmbShare' { Get-SmbShare | Select Name,Path } $profile.ShareTerms 'Expected SMB shares and paths exist.' }
            8 { return Test-B1AdObjectTerms 'Get-Acl C:\Shares\Common' { $acl=Get-Acl 'C:\Shares\Common'; $acl | Select-Object Path,Owner,Group,AccessToString; $acl.Access | Select-Object IdentityReference,FileSystemRights,AccessControlType,IsInherited,InheritanceFlags,PropagationFlags } @('GG_File_Common_RW','GG_File_Common_RO') 'Common ACL contains required groups.' }
            9 { return Test-B1AdObjectTerms 'Get-Acl C:\Shares\IT' { $acl=Get-Acl 'C:\Shares\IT'; $acl | Select-Object Path,Owner,Group,AccessToString; $acl.Access | Select-Object IdentityReference,FileSystemRights,AccessControlType,IsInherited,InheritanceFlags,PropagationFlags } @('GG_File_IT_RW') 'IT ACL contains required group.' }
            10 { return Test-B1CommandWarn 'Get-ChildItem C:\Shares\Home; Get-Acl C:\Shares\Home' { Get-ChildItem 'C:\Shares\Home' -ErrorAction SilentlyContinue; Get-Acl 'C:\Shares\Home' -ErrorAction SilentlyContinue } 'Review home folders and ACL isolation for individual users.' -RelevantTerms @('Home','IdentityReference','FileSystemRights','AccessToString') }
        }
    }

    switch ($Seq) {
        1 { $r1 = Test-B1Hostname $HostKey; $r2 = Test-B1IpProfile $profile; if ($r1[0] -eq 'PASS' -and $r2[0] -eq 'PASS') { return @('PASS','Hostname and IP profile are correct.') }; return @('FAIL', "$($r1[1]); $($r2[1])") }
        2 { return Test-B1AdObjectTerms 'Get-DhcpServerInDC; Get-WindowsFeature DHCP' { Get-DhcpServerInDC; Get-WindowsFeature DHCP } @($HostKey,'DHCP') 'DHCP role and authorization evidence is present.' }
        3 { return Test-B1AdObjectTerms 'Get-DhcpServerv4Scope; Get-DhcpServerv4ExclusionRange' { Get-DhcpServerv4Scope | Select ScopeId,StartRange,EndRange,Name; Get-DhcpServerv4ExclusionRange -ScopeId $profile.Scope | Select ScopeId,StartRange,EndRange } @($profile.Scope,'100','119','200') 'Expected DHCP scope/range and exclusion are visible.' }
        4 { return Test-B1AdObjectTerms "Get-DhcpServerv4OptionValue -ScopeId $($profile.Scope)" { Get-DhcpServerv4OptionValue -ScopeId $profile.Scope } @($profile.Router,$profile.DhcpDns[0],$profile.DhcpDns[1],'nb-b1.local') 'DHCP router/DNS/suffix options are visible.' }
        5 { return Test-B1CommandWarn 'Get-DhcpServerv4DnsSetting' { Get-DhcpServerv4DnsSetting } 'Review dynamic DNS settings and confirm DHCP registers A/PTR records.' -RelevantTerms @('Dynamic','DNS','PTR','A','Update') }
        6 { return Test-B1AdObjectTerms 'Get-SmbShare -Name Branch' { Get-SmbShare -Name 'Branch' | Select Name,Path } $profile.ShareTerms 'Expected Branch share and path exist.' }
        7 { return Test-B1AdObjectTerms 'Get-Acl C:\Shares\Branch' { $acl=Get-Acl 'C:\Shares\Branch'; $acl | Select-Object Path,Owner,Group,AccessToString; $acl.Access | Select-Object IdentityReference,FileSystemRights,AccessControlType,IsInherited,InheritanceFlags,PropagationFlags } @('GG_File_Beijing_RW') 'Branch ACL contains required group.' }
        8 { return Test-B1AdObjectTerms 'Get-Service WinRM; Test-WSMan localhost' { Get-Service WinRM; Test-WSMan localhost } @('Running') 'Remote administration is available.' }
    }
}

function Test-B1ClientAspect {
    param([string]$HostKey, [int]$Seq)
    $isSha = $HostKey -eq 'SHA-CL01'
    $profile = if ($isSha) {
        @{ Range='10.21.30.'; Gateway='10.21.30.1'; Dns=@('10.21.20.10','10.31.20.10'); Ou=@('10-Workstations','Shanghai'); CrossNames=@('bj-dc02.nb-b1.local','bj-files.nb-b1.local'); CrossTarget='bj-srv01.nb-b1.local' }
    } else {
        @{ Range='10.31.30.'; Gateway='10.31.30.1'; Dns=@('10.31.20.10','10.21.20.10'); Ou=@('10-Workstations','Beijing'); CrossNames=@('sha-dc01.nb-b1.local','files.nb-b1.local'); CrossTarget='sha-fs01.nb-b1.local' }
    }
    if ($isSha) {
        switch ($Seq) {
            1 { return Test-B1IpProfile @{ IPs=@($profile.Range); Gateways=@($profile.Gateway); Dns=$profile.Dns } }
            2 { return Test-B1DomainJoin $profile.Ou }
            3 { return Test-B1AdObjectTerms 'gpresult /r /scope computer' { Invoke-B1NativeText @('gpresult /r /scope computer') } @('GPO-B1-Workstations-Security') 'Workstations security GPO is applied.' }
            4 { return Test-B1CommandWarn "Get-NetFirewallProfile -Profile Domain; Get-NetFirewallRule; Get-LocalGroupMember 'Remote Desktop Users'" { Get-NetFirewallProfile -Profile Domain; Get-NetFirewallRule -DisplayGroup 'File and Printer Sharing' -ErrorAction SilentlyContinue; Get-LocalGroupMember 'Remote Desktop Users' -ErrorAction SilentlyContinue } 'Review firewall, ICMP and RDP local group evidence.' -RelevantTerms @('Domain','Enabled','File and Printer Sharing','Remote Desktop','Allow') }
            5 { return Test-B1CommandWarn "Get-LapsADPassword -Identity $HostKey -AsPlainText" { Get-LapsADPassword -Identity $HostKey -AsPlainText } "Review LAPS output and confirm AD password exists for $HostKey." -RelevantTerms @($HostKey,'Password','Expiration','Account','msLAPS') }
            6 { return Test-B1AdObjectTerms 'Get-BitLockerVolume -MountPoint D:; manage-bde -status D:' { Get-BitLockerVolume -MountPoint 'D:'; Invoke-B1NativeText @('manage-bde -status D:') } @('On','Recovery') 'BitLocker D: protection/recovery evidence is visible.' }
            7 { return Test-B1CommandWarn "Get-ADObject BitLocker recovery under $HostKey" { $comp=Get-ADComputer $HostKey; Get-ADObject -SearchBase $comp.DistinguishedName -LDAPFilter '(objectClass=msFVE-RecoveryInformation)' -Properties msFVE-RecoveryPassword } "Review BitLocker recovery object for $HostKey." -RelevantTerms @($HostKey,'msFVE-RecoveryPassword','Recovery') }
            8 { return Test-B1AdObjectTerms 'Import-Csv C:\Skills\b1-users.csv' { Import-Csv 'C:\Skills\b1-users.csv' | Select-Object FirstName,LastName,Department,Site } @('FirstName','LastName','Department','Site') 'CSV file has required columns.' }
            4 { return Test-B1ClientFirewallBaseline }
            5 { return Test-B1LapsPassword $HostKey }
            6 { return Test-B1BitLockerDataVolume }
            7 { return Test-B1BitLockerRecoveryInAd $HostKey }
            8 { return Test-B1UsersCsv }
            9 { return Test-B1CommandWarn 'Get-Content C:\Skills\Import-B1Users.ps1' { Get-Content 'C:\Skills\Import-B1Users.ps1' } 'Review script content for OU, user and group membership automation.' -RelevantTerms @('Import-Csv','New-ADUser','Add-ADGroupMember','OU=20-Users','GG_') }
            10 { return Test-B1CommandWarn 'Run Import-B1Users.ps1 twice and inspect output' { Test-Path 'C:\Skills\Import-B1Users.ps1'; Get-ChildItem 'C:\Skills' } 'Idempotency requires reviewing two script runs and AD object state.' -RelevantTerms @('Import-B1Users.ps1','True','LastWriteTime','Mode') }
            11 { return Test-B1CommandWarn 'net use' { Invoke-B1NativeText @('net use') } 'Review mapped drives under intended Shanghai/IT/GUEST users.' -RelevantTerms @('Common','IT','Home','files','OK','Unavailable') }
            12 { return Test-B1CommandWarn 'File access smoke commands' { Test-Path '\\files.nb-b1.local\Common'; Test-Path '\\files.nb-b1.local\IT'; Test-Path '\\SHA-FS01\Home$' } 'Run create/read/delete tests under different users and review output.' -RelevantTerms @('True','False','Common','IT','Home') }
            13 { return Test-B1AdObjectTerms "Resolve-DnsName cross-site names; Test-NetConnection $($profile.CrossTarget) -Port 445" { $profile.CrossNames | ForEach-Object { Resolve-DnsName $_ }; Test-NetConnection $profile.CrossTarget -Port 445 } @('TcpTestSucceeded') 'Cross-site DNS/SMB evidence is present.' }
            14 { return Test-B1AdObjectTerms 'git -C C:\Skills status; git -C C:\Skills log --oneline -1' { Invoke-B1NativeText @('git -C C:\Skills status','git -C C:\Skills log --oneline -1') } @('final commit') 'Git final commit evidence is visible.' }
            15 { return Test-B1AdObjectTerms 'Get-Content C:\Skills\B1-selfcheck.txt' { Get-Content 'C:\Skills\B1-selfcheck.txt' } @('AD','DNS','DHCP') 'Self-check file contains infrastructure checks.' }
        }
    }

    switch ($Seq) {
        1 { return Test-B1IpProfile @{ IPs=@($profile.Range); Gateways=@($profile.Gateway); Dns=$profile.Dns } }
        2 { return Test-B1DomainJoin $profile.Ou }
        3 { return Test-B1AdObjectTerms 'gpresult /r /scope computer' { Invoke-B1NativeText @('gpresult /r /scope computer') } @('GPO-B1-Workstations-Security') 'Workstations security GPO is applied.' }
        4 { return Test-B1LapsPassword $HostKey }
        5 { return Test-B1CommandWarn 'net use' { Invoke-B1NativeText @('net use') } 'Review drive mappings for Beijing users.' -RelevantTerms @('Branch','bj-files','OK','Unavailable') }
        6 { return Test-B1CommandWarn '\\bj-files.nb-b1.local\Branch access tests' { Test-Path '\\bj-files.nb-b1.local\Branch'; Invoke-B1NativeText @('dir \\bj-files.nb-b1.local\Branch') } 'Review Branch share access under the intended Beijing/GUEST users.' -RelevantTerms @('Branch','True','File(s)','Directory','Access') }
        7 { return Test-B1AdObjectTerms "Resolve-DnsName cross-site names; Test-NetConnection $($profile.CrossTarget) -Port 445" { $profile.CrossNames | ForEach-Object { Resolve-DnsName $_ }; Test-NetConnection $profile.CrossTarget -Port 445 } @('TcpTestSucceeded') 'Cross-site DNS/SMB evidence is present.' }
        8 { return Test-B1AdObjectTerms 'Resolve-DnsName www.internet.lab' { Resolve-DnsName 'www.internet.lab' } @('www.internet.lab') 'Simulated Internet DNS name resolves.' }
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
        'ISP-BJ' = @{ IPs=@('198.18.101.1','198.18.201.1','203.0.113.1'); Gateways=@('203.0.113.2') }
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
            $required = @(
                'DNS 198.18.200.10:53=True',
                'HTTP 198.18.200.10:80=True',
                'DNS www.internet.lab via 198.18.200.10=True'
            )
            $r = Invoke-B1Evidence 'Test-NetConnection 198.18.200.10 -Port 53/80; Resolve-DnsName www.internet.lab -Server 198.18.200.10' {
                "DNS 198.18.200.10:53=$(Test-NetConnection '198.18.200.10' -Port 53 -InformationLevel Quiet -WarningAction SilentlyContinue)"
                "HTTP 198.18.200.10:80=$(Test-NetConnection '198.18.200.10' -Port 80 -InformationLevel Quiet -WarningAction SilentlyContinue)"
                $dns = @(Resolve-DnsName 'www.internet.lab' -Server '198.18.200.10' -ErrorAction SilentlyContinue)
                "DNS www.internet.lab via 198.18.200.10=$([bool]$dns.Count)"
                if ($dns.Count -gt 0) { $dns | Select-Object Name,Type,IPAddress,NameHost }
            } -RelevantTerms ($required + @('www.internet.lab','198.18.200.10')) -ContextLines 0 -AllowError
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
    Write-B1VersionBanner -HostKey $HostKey
    if ($script:B1ReportEnabled) {
        Write-B1Log "Каталог отчета: $script:ReportDir" DarkGray
    } else {
        Write-B1Log 'Отчет: отключен. Для записи отчета используйте -Report или -ReportDir <path>.' DarkGray
    }
    Write-B1Log "Версия скриптов: $script:B1ScriptVersion" DarkGray
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
