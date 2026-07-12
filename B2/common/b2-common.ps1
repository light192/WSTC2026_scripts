Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:B2Root = Split-Path -Parent $PSScriptRoot
$script:B2CriteriaPath = Join-Path $script:B2Root 'criteria\b2_criteria_map.tsv'
$script:B2PauseBetweenChecks = $true
$script:B2ReportEnabled = $false
$script:B2Rows = @()
$script:B2Version = '2026-07-12.1'

function ConvertTo-B2Text {
    param([object]$Value)
    if ($null -eq $Value) { return '' }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Value)) {
        if ($null -eq $item) { continue }
        $base = $item.PSObject.BaseObject
        if ($base -is [string] -or $base -is [System.ValueType]) {
            $lines.Add(([string]$base).TrimEnd())
        } else {
            $lines.Add((($item | Out-String -Width 4096).TrimEnd()))
        }
    }
    return (($lines -join [Environment]::NewLine).TrimEnd())
}

function Select-B2RelevantOutput {
    param(
        [string]$Text,
        [string[]]$Terms = @(),
        [string]$Pattern,
        [int]$ContextLines = 0
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return '(пустой вывод)' }
    $terms = @($Terms | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($terms.Count -eq 0 -and [string]::IsNullOrWhiteSpace($Pattern)) { return $Text }

    $source = @($Text -split "`r?`n")
    $indexes = @{}
    for ($i = 0; $i -lt $source.Count; $i++) {
        $matched = $false
        if (-not [string]::IsNullOrWhiteSpace($Pattern) -and $source[$i] -match $Pattern) {
            $matched = $true
        }
        if (-not $matched) {
            foreach ($term in $terms) {
                if ($source[$i].IndexOf($term, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $matched = $true
                    break
                }
            }
        }
        if ($matched) {
            $from = [Math]::Max(0, $i - $ContextLines)
            $to = [Math]::Min($source.Count - 1, $i + $ContextLines)
            for ($j = $from; $j -le $to; $j++) { $indexes[$j] = $true }
        }
    }
    if ($indexes.Count -eq 0) {
        return '(релевантные строки не найдены; решение принято по полному выводу команды)'
    }
    return ((@($indexes.Keys | Sort-Object { [int]$_ } | ForEach-Object { $source[[int]$_] }) -join [Environment]::NewLine).TrimEnd())
}

function Write-B2Log {
    param([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    Write-Host $Text -ForegroundColor $Color
    if (-not $script:B2ReportEnabled) { return }
    try {
        Add-Content -LiteralPath $script:B2DetailPath -Value $Text -Encoding UTF8
    } catch {
        Write-Host "[WARN] Не удалось записать лог: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Write-B2Section {
    param([string]$Text)
    Write-Host ''
    Write-B2Log '######################################################################################' Magenta
    Write-B2Log $Text Magenta
    Write-B2Log '######################################################################################' Magenta
    Write-Host ''
}

function Initialize-B2Report {
    param([string]$HostKey, [switch]$Report, [string]$ReportDir)
    $script:B2Rows = @()
    $script:B2ReportEnabled = $false
    if (-not $Report -and [string]::IsNullOrWhiteSpace($ReportDir)) { return }

    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($ReportDir)) { $candidates.Add($ReportDir) }
    $candidates.Add((Join-Path $script:B2Root "reports\$HostKey"))
    $candidates.Add((Join-Path $env:TEMP "B2-reports\$HostKey"))
    $lastError = ''
    foreach ($candidate in $candidates) {
        try {
            New-Item -ItemType Directory -Path $candidate -Force | Out-Null
            $script:B2ReportDir = $candidate
            $script:B2ResultsPath = Join-Path $candidate 'b2-results.tsv'
            $script:B2DetailPath = Join-Path $candidate 'b2-detail.log'
            $script:B2SummaryPath = Join-Path $candidate 'b2-summary.txt'
            Set-Content -LiteralPath $script:B2ResultsPath -Value "AspectID`tGroupID`tHostKey`tMaxMark`tStatus`tMessage" -Encoding UTF8
            Set-Content -LiteralPath $script:B2DetailPath -Value '' -Encoding UTF8
            $script:B2ReportEnabled = $true
            return
        } catch {
            $lastError = $_.Exception.Message
        }
    }
    throw "Не удалось создать отчет: $lastError"
}

function Get-B2Criteria {
    param([string]$HostKey)
    if (-not (Test-Path -LiteralPath $script:B2CriteriaPath)) {
        throw "Не найдена карта критериев: $script:B2CriteriaPath"
    }
    return @(Import-Csv -LiteralPath $script:B2CriteriaPath -Delimiter "`t" -Encoding UTF8 |
        Where-Object { $_.HostKey -eq $HostKey } |
        Sort-Object AspectID)
}

function Start-B2Aspect {
    param([object]$Aspect)
    Write-Host ''
    Write-B2Log "[$($Aspect.AspectID)] $($Aspect.Description)" Yellow
    Write-B2Log "Команды из marking scheme: $($Aspect.VerificationCommands)" Cyan
    Write-B2Log "Ожидаемый результат: $($Aspect.ExpectedResult)" DarkCyan
}

function Invoke-B2Evidence {
    param(
        [string]$Command,
        [scriptblock]$ScriptBlock,
        [string[]]$RelevantTerms = @(),
        [string]$RelevantPattern,
        [int]$ContextLines = 0
    )
    Write-B2Log "Команда: $Command" Cyan
    try {
        $value = & $ScriptBlock
        $text = ConvertTo-B2Text $value
        if ([string]::IsNullOrWhiteSpace($text)) { $text = '(пустой вывод)' }
        $display = Select-B2RelevantOutput -Text $text -Terms $RelevantTerms -Pattern $RelevantPattern -ContextLines $ContextLines
        if ($display -ne $text) {
            Write-B2Log 'Фактический вывод (только релевантные строки):' Blue
        } else {
            Write-B2Log 'Фактический вывод:' Blue
        }
        Write-B2Log $display Gray
        return [pscustomobject]@{ Ok = $true; Text = $text; DisplayText = $display; Value = $value }
    } catch {
        $text = "[ERROR] $($_.Exception.Message)"
        Write-B2Log 'Фактический вывод:' Blue
        Write-B2Log $text Red
        return [pscustomobject]@{ Ok = $false; Text = $text; DisplayText = $text; Value = $null }
    }
}

function New-B2Result {
    param([string]$Status, [string]$Message)
    return @($Status, $Message)
}

function Test-B2ContainsAll {
    param([string]$Text, [string[]]$Terms)
    foreach ($term in @($Terms)) {
        if ($Text.IndexOf($term, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    }
    return $true
}

function Complete-B2Aspect {
    param([object]$Aspect, [string]$Status, [string]$Message)
    $script:B2Rows += [pscustomobject]@{
        AspectID = $Aspect.AspectID
        GroupID = $Aspect.GroupID
        HostKey = $Aspect.HostKey
        MaxMark = $Aspect.MaxMark
        Status = $Status
        Message = $Message
    }
    if ($script:B2ReportEnabled) {
        $safeMessage = $Message -replace "`t", ' ' -replace "`r?`n", ' '
        Add-Content -LiteralPath $script:B2ResultsPath -Value "$($Aspect.AspectID)`t$($Aspect.GroupID)`t$($Aspect.HostKey)`t$($Aspect.MaxMark)`t$Status`t$safeMessage" -Encoding UTF8
    }
    switch ($Status) {
        'PASS' { Write-B2Log "[PASS] $($Aspect.AspectID)/$($Aspect.MaxMark) - $Message" Green }
        'FAIL' { Write-B2Log "[FAIL] $($Aspect.AspectID)/$($Aspect.MaxMark) - $Message" Red }
        default { Write-B2Log "[WARN] $($Aspect.AspectID)/$($Aspect.MaxMark) - $Message" Yellow }
    }
    if ($script:B2PauseBetweenChecks) { [void](Read-Host 'Нажмите Enter, чтобы продолжить') }
}

function Invoke-B2NativeText {
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
        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $psi
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $text = (($stdout + $stderr).TrimEnd())
        if (-not [string]::IsNullOrWhiteSpace($text)) { $lines.Add($text) }
        $lines.Add("ExitCode=$($process.ExitCode)")
    }
    return (($lines -join [Environment]::NewLine).TrimEnd())
}

function Get-B2FeatureEvidence {
    param([string]$Name)
    $feature = Get-WindowsFeature -Name $Name -ErrorAction Stop
    return "Feature=$($feature.Name); InstallState=$($feature.InstallState); Installed=$($feature.Installed)"
}

function Get-B2TcpEvidence {
    param([string]$Target, [int]$Port)
    $ok = Test-NetConnection $Target -Port $Port -InformationLevel Quiet -WarningAction SilentlyContinue
    return "Target=$Target; Port=$Port; TcpTestSucceeded=$ok"
}

function Get-B2DnsEvidence {
    param([string]$Name, [string]$Server, [string]$Type = 'A')
    $args = @{ Name=$Name; Type=$Type; ErrorAction='Stop' }
    if (-not [string]::IsNullOrWhiteSpace($Server)) { $args.Server = $Server }
    $rows = @(Resolve-DnsName @args)
    foreach ($row in $rows) {
        "Name=$($row.Name); Type=$($row.Type); IPAddress=$($row.IPAddress); NameHost=$($row.NameHost)"
    }
}

function Get-B2WebsiteEvidence {
    param([string]$Name)
    Import-Module WebAdministration -ErrorAction Stop
    $site = Get-Website -Name $Name -ErrorAction Stop
    "Website=$($site.Name); State=$($site.State); PhysicalPath=$($site.PhysicalPath); Bindings=$($site.Bindings.Collection.bindingInformation -join ',')"
}

function Get-B2BindingEvidence {
    param([string]$Name)
    Import-Module WebAdministration -ErrorAction Stop
    foreach ($binding in @(Get-WebBinding -Name $Name -ErrorAction Stop)) {
        "Protocol=$($binding.protocol); BindingInformation=$($binding.bindingInformation); CertificateHash=$($binding.certificateHash); SslFlags=$($binding.sslFlags)"
    }
}

function Get-B2FirewallEvidence {
    param([int[]]$Ports)
    foreach ($rule in @(Get-NetFirewallRule -Enabled True -Direction Inbound -Action Allow -ErrorAction Stop)) {
        $portFilter = $rule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
        $addressFilter = $rule | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue
        if ($null -eq $portFilter) { continue }
        $localPorts = @($portFilter.LocalPort)
        $matched = $false
        foreach ($port in $Ports) {
            if ($localPorts -contains [string]$port -or $localPorts -contains $port) { $matched = $true }
        }
        if ($matched) {
            "Rule=$($rule.DisplayName); Protocol=$($portFilter.Protocol); LocalPort=$($localPorts -join ','); RemoteAddress=$(@($addressFilter.RemoteAddress) -join ','); Profile=$($rule.Profile)"
        }
    }
}

function Invoke-B2WebEvidence {
    param([string]$Uri)
    $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 12 -ErrorAction Stop
    "Uri=$Uri; StatusCode=$($response.StatusCode); ContentLength=$($response.Content.Length)"
    $plain = ($response.Content -replace '<[^>]+>', ' ' -replace '\s+', ' ').Trim()
    if ($plain.Length -gt 500) { $plain = $plain.Substring(0, 500) }
    "Content=$plain"
}

function Get-B2PortalCertDumpFromStore {
    $cert = @(Get-ChildItem Cert:\LocalMachine\My | Where-Object {
        $_.Subject -match 'portal' -or ($_.DnsNameList.Unicode -contains 'portal.nb-b2.local')
    } | Sort-Object NotAfter -Descending | Select-Object -First 1)
    if ($cert.Count -eq 0) { throw 'Portal certificate not found in LocalMachine\My.' }
    $tmp = Join-Path $env:TEMP ("b2-{0}.cer" -f [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllBytes($tmp, $cert[0].Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
        return Invoke-B2NativeText @("certutil -dump `"$tmp`"")
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Get-B2RemotePortalCertDump {
    param([string]$HostName, [int]$Port = 443)
    $tcp = [System.Net.Sockets.TcpClient]::new()
    $ssl = $null
    $tmp = Join-Path $env:TEMP ("b2-{0}.cer" -f [guid]::NewGuid().ToString('N'))
    try {
        $tcp.Connect($HostName, $Port)
        $callback = [System.Net.Security.RemoteCertificateValidationCallback]{ param($sender,$certificate,$chain,$errors) return $true }
        $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false, $callback)
        $ssl.AuthenticateAsClient($HostName)
        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($ssl.RemoteCertificate)
        [System.IO.File]::WriteAllBytes($tmp, $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
        return Invoke-B2NativeText @("certutil -dump `"$tmp`"")
    } finally {
        if ($null -ne $ssl) { $ssl.Dispose() }
        $tcp.Dispose()
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Get-B2CertificateUrls {
    param([string]$Dump, [string]$HostPattern)
    $matches = [regex]::Matches($Dump, 'http://[^\s\"<>]+', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $urls = @($matches | ForEach-Object { $_.Value.TrimEnd('.',',',')',']') } | Select-Object -Unique)
    if (-not [string]::IsNullOrWhiteSpace($HostPattern)) {
        $urls = @($urls | Where-Object { $_ -match $HostPattern })
    }
    return $urls
}

function Test-B2PublishedCertificateUrls {
    param([string]$Dump, [string]$HostPattern)
    $urls = @(Get-B2CertificateUrls -Dump $Dump -HostPattern $HostPattern)
    if ($urls.Count -eq 0) { return 'PublishedUrls=NOT_FOUND' }
    foreach ($url in $urls) {
        try {
            $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 12 -ErrorAction Stop
            "URL=$url; StatusCode=$($response.StatusCode); ContentLength=$($response.RawContentLength)"
        } catch {
            "URL=$url; ERROR=$($_.Exception.Message)"
        }
    }
}

function Get-B2PortalCertStoreEvidence {
    param([string]$StorePath = 'Cert:\LocalMachine\My')
    foreach ($cert in @(Get-ChildItem $StorePath | Where-Object {
        $_.Subject -match 'portal' -or ($_.DnsNameList.Unicode -contains 'portal.nb-b2.local')
    })) {
        "Subject=$($cert.Subject); Issuer=$($cert.Issuer); HasPrivateKey=$($cert.HasPrivateKey); Thumbprint=$($cert.Thumbprint); NotAfter=$($cert.NotAfter.ToString('s')); DNS=$(@($cert.DnsNameList.Unicode) -join ',')"
    }
}

function Get-B2PortalCertificateFile {
    $candidates = @('C:\Temp\portal.cer','C:\Skills\B2\portal.cer')
    foreach ($path in $candidates) { if (Test-Path -LiteralPath $path) { return $path } }
    return $null
}

function Test-B2AspectA {
    param([string]$HostKey, [string]$AspectID)
    switch ($AspectID) {
        'A1.01' {
            $r = Invoke-B2Evidence 'Get-ADDomain; Get-ADDomainController -Filter *; Get-DhcpServerInDC; Get-DnsServerZone' {
                $domain = Get-ADDomain
                "DomainDNSRoot=$($domain.DNSRoot); NetBIOSName=$($domain.NetBIOSName)"
                foreach ($dc in @(Get-ADDomainController -Filter *)) { "DomainController=$($dc.HostName); Site=$($dc.Site)" }
                if (Get-Command Get-DhcpServerInDC -ErrorAction SilentlyContinue) {
                    foreach ($dhcp in @(Get-DhcpServerInDC -ErrorAction SilentlyContinue)) { "DhcpServer=$($dhcp.DnsName); IP=$($dhcp.IPAddress)" }
                } else {
                    $config = (Get-ADRootDSE).ConfigurationNamingContext
                    foreach ($dhcp in @(Get-ADObject -SearchBase "CN=NetServices,CN=Services,$config" -LDAPFilter '(objectClass=dhcpClass)' -Properties dhcpServers -ErrorAction SilentlyContinue)) {
                        "DhcpServer=$($dhcp.Name); ADPath=$($dhcp.DistinguishedName); Values=$(@($dhcp.dhcpServers) -join ',')"
                    }
                }
                foreach ($zone in @(Get-DnsServerZone -ErrorAction SilentlyContinue)) { "DnsZone=$($zone.ZoneName); Type=$($zone.ZoneType)" }
            } -RelevantTerms @('DomainDNSRoot','DomainController','DhcpServer','DnsZone')
            if ($r.Ok -and (Test-B2ContainsAll $r.Text @('nb-b2.local','NBB2','SHA-DC01','BJ-DC02','DhcpServer=','DnsZone=nb-b2.local'))) {
                return New-B2Result PASS 'Домен, оба DC/DNS и авторизованный DHCP подтверждены.'
            }
            return New-B2Result FAIL 'Не подтверждён один из foundation-компонентов: домен, оба DC, DHCP или DNS-зона.'
        }
        'A1.02' {
            $expectedPrefix = if ($HostKey -eq 'SHA-CL01') { '10.22.30.' } else { '10.32.30.' }
            $expectedDns = if ($HostKey -eq 'SHA-CL01') { '10.22.20.10' } else { '10.32.20.10' }
            $r = Invoke-B2Evidence 'Get-NetIPConfiguration; Get-NetIPInterface; Get-CimInstance Win32_ComputerSystem' {
                $cs = Get-CimInstance Win32_ComputerSystem
                "Computer=$env:COMPUTERNAME; PartOfDomain=$($cs.PartOfDomain); Domain=$($cs.Domain)"
                foreach ($cfg in @(Get-NetIPConfiguration | Where-Object { $_.IPv4Address })) {
                    $adapter = Get-NetIPInterface -InterfaceIndex $cfg.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
                    foreach ($addr in @($cfg.IPv4Address)) {
                        "Interface=$($cfg.InterfaceAlias); IPv4=$($addr.IPAddress)/$($addr.PrefixLength); PrefixOrigin=$($addr.PrefixOrigin); Dhcp=$($adapter.Dhcp); DNS=$(@($cfg.DNSServer.ServerAddresses) -join ',')"
                    }
                }
            } -RelevantTerms @('PartOfDomain','IPv4=','Dhcp=','DNS=')
            if ($r.Ok -and (Test-B2ContainsAll $r.Text @('PartOfDomain=True','Domain=nb-b2.local',$expectedPrefix,'Dhcp=Enabled',$expectedDns))) {
                return New-B2Result PASS "Клиент в домене, использует DHCP-адрес из сети $($expectedPrefix)0/24 и локальный DNS домена."
            }
            return New-B2Result FAIL 'Не подтверждены domain membership и DHCP-адрес из требуемой ClientNet.'
        }
        'A1.03' {
            $r = Invoke-B2Evidence 'Resolve-DnsName sha-dc01.nb-b2.local, bj-dc02.nb-b2.local, bj-srv01.nb-b2.local' {
                Get-B2DnsEvidence 'sha-dc01.nb-b2.local' ''
                Get-B2DnsEvidence 'bj-dc02.nb-b2.local' ''
                Get-B2DnsEvidence 'bj-srv01.nb-b2.local' ''
            } -RelevantTerms @('sha-dc01','bj-dc02','bj-srv01','IPAddress=')
            if ($r.Ok -and (Test-B2ContainsAll $r.Text @('10.22.20.10','10.32.20.10','10.32.20.20'))) {
                return New-B2Result PASS 'Все foundation-имена разрешены в заданные адреса.'
            }
            return New-B2Result FAIL 'Один или несколько foundation-адресов DNS не совпадают.'
        }
        { $_ -in @('A1.04','A1.05') } {
            $prefixes = if ($AspectID -eq 'A1.04') {
                @('10.32.20.0/24','10.32.30.0/24','198.18.200.0/24','198.18.201.0/24')
            } else {
                @('10.22.10.0/24','10.22.20.0/24','10.22.30.0/24','198.18.200.0/24','198.18.201.0/24')
            }
            $nextHop = if ($AspectID -eq 'A1.04') { '198.18.100.1' } else { '198.18.101.1' }
            $r = Invoke-B2Evidence "Get-NetRoute for $($prefixes -join ', ')" {
                foreach ($prefix in $prefixes) {
                    $routes = @(Get-NetRoute -DestinationPrefix $prefix -ErrorAction SilentlyContinue | Sort-Object RouteMetric)
                    if ($routes.Count -eq 0) { "Prefix=$prefix; Route=NOT_FOUND" }
                    foreach ($route in $routes) { "Prefix=$prefix; NextHop=$($route.NextHop); Interface=$($route.InterfaceAlias); Metric=$($route.RouteMetric); State=$($route.State)" }
                }
            } -RelevantTerms $prefixes
            $ok = $r.Ok
            foreach ($prefix in $prefixes) {
                if ($r.Text -notmatch ([regex]::Escape("Prefix=$prefix") + '.*' + [regex]::Escape("NextHop=$nextHop"))) { $ok = $false }
            }
            if ($ok) { return New-B2Result PASS "Все требуемые маршруты используют next hop $nextHop." }
            return New-B2Result FAIL "Отсутствует маршрут или указан неверный next hop; ожидается $nextHop."
        }
        'A1.06' {
            $r = Invoke-B2Evidence '(Get-CimInstance Win32_ComputerSystem).PartOfDomain/Domain' {
                $cs = Get-CimInstance Win32_ComputerSystem
                "Computer=$env:COMPUTERNAME; PartOfDomain=$($cs.PartOfDomain); Domain=$($cs.Domain); LocalScriptExecution=True"
            } -RelevantTerms @('Computer=','PartOfDomain','Domain=','LocalScriptExecution')
            if ($r.Ok -and (Test-B2ContainsAll $r.Text @('PartOfDomain=False','LocalScriptExecution=True'))) {
                return New-B2Result PASS 'Сервер остаётся в workgroup; локальный запуск подтверждает доступность управления.'
            }
            return New-B2Result FAIL 'DMZ-сервер присоединён к домену или состояние не удалось подтвердить.'
        }
        'A1.07' {
            $r = Invoke-B2Evidence 'Test-NetConnection 10.22.10.11/10.22.10.12 -Port 5985' {
                Get-B2TcpEvidence '10.22.10.11' 5985
                Get-B2TcpEvidence '10.22.10.12' 5985
            } -RelevantTerms @('10.22.10.11','10.22.10.12','TcpTestSucceeded')
            $successCount = ([regex]::Matches($r.Text, 'TcpTestSucceeded=False', 'IgnoreCase')).Count
            if ($r.Ok -and $successCount -eq 2) { return New-B2Result PASS 'WinRM обоих DMZ-серверов недоступен с INET-CL01.' }
            return New-B2Result FAIL 'INET-CL01 имеет management-доступ хотя бы к одному DMZ-серверу.'
        }
    }
}

function Test-B2AspectB {
    param([string]$AspectID)
    switch ($AspectID) {
        'B1.01' {
            $names = @('50-PKI','60-WebServices','70-B2-Groups','80-B2-TestUsers')
            $r = Invoke-B2Evidence 'Get-ADOrganizationalUnit -Filter * | select Name,DistinguishedName' {
                foreach ($ou in @(Get-ADOrganizationalUnit -Filter * | Where-Object { $_.Name -in $names })) { "OU=$($ou.Name); DN=$($ou.DistinguishedName)" }
            } -RelevantTerms $names
            if ($r.Ok -and (Test-B2ContainsAll $r.Text $names)) { return New-B2Result PASS 'Все четыре B2 OU существуют.' }
            return New-B2Result FAIL 'Не найдена одна или несколько B2 OU.'
        }
        'B1.02' {
            $r = Invoke-B2Evidence 'Get-ADGroup GG_B2_PKI_Admins,GG_B2_Web_Enroll -Properties GroupScope,GroupCategory' {
                foreach ($name in @('GG_B2_PKI_Admins','GG_B2_Web_Enroll')) {
                    $group = Get-ADGroup $name -Properties GroupScope,GroupCategory
                    "Group=$($group.Name); Scope=$($group.GroupScope); Category=$($group.GroupCategory); DN=$($group.DistinguishedName)"
                }
            } -RelevantTerms @('GG_B2_PKI_Admins','GG_B2_Web_Enroll','Scope=','Category=')
            if ($r.Ok -and (Test-B2ContainsAll $r.Text @('Group=GG_B2_PKI_Admins','Group=GG_B2_Web_Enroll','Scope=Global','Category=Security'))) {
                $globalCount = ([regex]::Matches($r.Text,'Scope=Global','IgnoreCase')).Count
                $securityCount = ([regex]::Matches($r.Text,'Category=Security','IgnoreCase')).Count
                if ($globalCount -eq 2 -and $securityCount -eq 2) { return New-B2Result PASS 'Обе группы имеют тип Global Security.' }
            }
            return New-B2Result FAIL 'Группа отсутствует или имеет неверные scope/category.'
        }
        'B1.03' {
            $r = Invoke-B2Evidence 'Get-ADUser pki.admin1 -Properties Enabled,DistinguishedName,PasswordExpired,pwdLastSet' {
                $user = Get-ADUser 'pki.admin1' -Properties Enabled,DistinguishedName,PasswordExpired,pwdLastSet
                "User=$($user.SamAccountName); Enabled=$($user.Enabled); PasswordExpired=$($user.PasswordExpired); pwdLastSet=$($user.pwdLastSet); DN=$($user.DistinguishedName)"
            } -RelevantTerms @('User=','Enabled=','PasswordExpired=','pwdLastSet=','DN=')
            if ($r.Ok -and (Test-B2ContainsAll $r.Text @('User=pki.admin1','Enabled=True','PasswordExpired=False','OU=80-B2-TestUsers'))) {
                return New-B2Result PASS 'pki.admin1 включён, пароль установлен и пользователь находится в нужной OU.'
            }
            return New-B2Result FAIL 'Состояние или размещение pki.admin1 не соответствует заданию.'
        }
        'B1.04' {
            $r = Invoke-B2Evidence 'Get-ADPrincipalGroupMembership pki.admin1' {
                foreach ($group in @(Get-ADPrincipalGroupMembership 'pki.admin1')) { "Group=$($group.Name)" }
            } -RelevantTerms @('GG_B2_PKI_Admins','GG_B2_Web_Enroll')
            if ($r.Ok -and (Test-B2ContainsAll $r.Text @('GG_B2_PKI_Admins','GG_B2_Web_Enroll'))) { return New-B2Result PASS 'Обе требуемые группы входят в membership pki.admin1.' }
            return New-B2Result FAIL 'pki.admin1 не состоит в одной из требуемых групп.'
        }
        'B1.05' {
            $r = Invoke-B2Evidence 'certutil -getreg CA\Security' {
                Invoke-B2NativeText @('certutil -getreg CA\Security')
            } -RelevantTerms @('Security','GG_B2_PKI_Admins','Manage','Issue','Certificate') -ContextLines 2
            if ($r.Ok -and $r.Text -match 'GG_B2_PKI_Admins' -and $r.Text -match 'Manage') {
                return New-B2Result PASS 'В выводе CA security явно найдена группа и права управления.'
            }
            return New-B2Result WARN 'Security descriptor получен, но права Manage CA и Issue/Manage Certificates нужно подтвердить по показанному выводу или в CA console.'
        }
        'B1.06' {
            $r = Invoke-B2Evidence 'Get-ADGroup/Get-ADUser | select DistinguishedName' {
                foreach ($name in @('GG_B2_PKI_Admins','GG_B2_Web_Enroll')) { $g=Get-ADGroup $name; "Object=$name; DN=$($g.DistinguishedName)" }
                $u=Get-ADUser 'pki.admin1'; "Object=pki.admin1; DN=$($u.DistinguishedName)"
            } -RelevantTerms @('GG_B2_PKI_Admins','GG_B2_Web_Enroll','pki.admin1','DN=')
            if ($r.Ok -and ([regex]::Matches($r.Text,'OU=70-B2-Groups','IgnoreCase')).Count -eq 2 -and $r.Text -match 'OU=80-B2-TestUsers') {
                return New-B2Result PASS 'Группы и пользователь размещены в предназначенных OU.'
            }
            return New-B2Result FAIL 'DistinguishedName объектов не соответствует заданным OU.'
        }
    }
}

function Test-B2AspectC {
    param([string]$AspectID)
    switch ($AspectID) {
        'C1.01' {
            $r = Invoke-B2Evidence 'Get-WindowsFeature ADCS-Cert-Authority; certutil -config "BJ-SRV01\NB-B2-ENT-CA" -ping' {
                Get-B2FeatureEvidence 'ADCS-Cert-Authority'
                Invoke-B2NativeText @('certutil -config "BJ-SRV01\NB-B2-ENT-CA" -ping')
            } -RelevantTerms @('ADCS-Cert-Authority','Installed=True','NB-B2-ENT-CA','interface is alive','ExitCode=0')
            if ($r.Ok -and (Test-B2ContainsAll $r.Text @('Installed=True','ExitCode=0'))) { return New-B2Result PASS 'Роль CA установлена, CA отвечает.' }
            return New-B2Result FAIL 'Роль Certification Authority не установлена или CA не отвечает.'
        }
        'C1.02' {
            $r = Invoke-B2Evidence 'Get-WindowsFeature ADCS-Cert-Authority' { Get-B2FeatureEvidence 'ADCS-Cert-Authority' } -RelevantTerms @('Feature=','InstallState=','Installed=')
            if ($r.Ok -and $r.Text -match 'Installed=False') { return New-B2Result PASS 'Certification Authority на запрещённом хосте отсутствует.' }
            return New-B2Result FAIL 'На этом хосте установлена запрещённая роль Certification Authority.'
        }
        'C1.03' {
            $r = Invoke-B2Evidence 'certutil -config "BJ-SRV01\NB-B2-ENT-CA" -dump' {
                Invoke-B2NativeText @('certutil -config "BJ-SRV01\NB-B2-ENT-CA" -dump')
            } -RelevantTerms @('NB-B2-ENT-CA','Enterprise','Root CA','CA type','ExitCode=0') -ContextLines 1
            if ($r.Ok -and (Test-B2ContainsAll $r.Text @('NB-B2-ENT-CA','ExitCode=0')) -and $r.Text -match 'Enterprise.*Root|Root.*Enterprise') {
                return New-B2Result PASS 'Подтверждены имя и тип Enterprise Root CA.'
            }
            return New-B2Result FAIL 'Имя или тип CA не подтверждены.'
        }
        'C1.04' {
            $r = Invoke-B2Evidence 'certutil -getreg CA\CSP\Provider, CNGHashAlgorithm; export/dump CA certificate' {
                Invoke-B2NativeText @(
                    'certutil -getreg CA\CSP\Provider',
                    'certutil -getreg CA\CSP\CNGHashAlgorithm',
                    'certutil -getreg CA\CSP\HashAlgorithm'
                )
                $tmp = Join-Path $env:TEMP 'b2-ca-check.cer'
                try {
                    Invoke-B2NativeText @("certutil -ca.cert `"$tmp`"")
                    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($tmp)
                    $keySize = if ($cert.PublicKey.Key) { $cert.PublicKey.Key.KeySize } else { 0 }
                    "Subject=$($cert.Subject); PublicKeyAlgorithm=$($cert.PublicKey.Oid.FriendlyName); KeySize=$keySize; SignatureAlgorithm=$($cert.SignatureAlgorithm.FriendlyName)"
                } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
            } -RelevantTerms @('Provider','HashAlgorithm','KeySize=','SignatureAlgorithm=','Microsoft Software Key Storage Provider','4096','SHA256')
            if ($r.Ok -and (Test-B2ContainsAll $r.Text @('Microsoft Software Key Storage Provider','KeySize=4096')) -and $r.Text -match 'sha256') {
                return New-B2Result PASS 'Provider, RSA 4096 и SHA256 подтверждены.'
            }
            return New-B2Result FAIL 'Криптографические параметры CA не совпадают.'
        }
        'C1.05' {
            $r = Invoke-B2Evidence 'certutil -ca.cert; inspect NotBefore/NotAfter' {
                $tmp = Join-Path $env:TEMP 'b2-ca-validity.cer'
                try {
                    Invoke-B2NativeText @("certutil -ca.cert `"$tmp`"")
                    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($tmp)
                    $days = [Math]::Round(($cert.NotAfter - $cert.NotBefore).TotalDays, 0)
                    "Subject=$($cert.Subject); NotBefore=$($cert.NotBefore.ToString('s')); NotAfter=$($cert.NotAfter.ToString('s')); ValidityDays=$days"
                } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
            } -RelevantTerms @('Subject=','NotBefore=','NotAfter=','ValidityDays=')
            $match = [regex]::Match($r.Text,'ValidityDays=(\d+)')
            if ($r.Ok -and $match.Success -and [int]$match.Groups[1].Value -ge 3640 -and [int]$match.Groups[1].Value -le 3665) {
                return New-B2Result PASS 'Срок CA certificate соответствует 10 годам.'
            }
            return New-B2Result FAIL 'Срок действия CA certificate не равен примерно 10 годам.'
        }
        'C1.06' {
            $r = Invoke-B2Evidence 'certutil -getreg CA\CRLPeriod/Units and CA\CRLDeltaPeriod/Units' {
                Invoke-B2NativeText @(
                    'certutil -getreg CA\CRLPeriod',
                    'certutil -getreg CA\CRLPeriodUnits',
                    'certutil -getreg CA\CRLDeltaPeriod',
                    'certutil -getreg CA\CRLDeltaPeriodUnits'
                )
            } -RelevantPattern 'CRLPeriod|CRLDeltaPeriod|Days|REG_DWORD|ExitCode'
            $periodOk = $r.Text -match 'CRLPeriod[^\r\n]*Days' -or $r.Text -match 'CRLPeriod\s+REG_SZ\s+=\s+Days'
            $deltaOk = $r.Text -match 'CRLDeltaPeriod[^\r\n]*Days' -or $r.Text -match 'CRLDeltaPeriod\s+REG_SZ\s+=\s+Days'
            $seven = $r.Text -match 'CRLPeriodUnits[^\r\n]*(0x7|7)'
            $one = $r.Text -match 'CRLDeltaPeriodUnits[^\r\n]*(0x1|1)'
            if ($r.Ok -and $periodOk -and $deltaOk -and $seven -and $one) { return New-B2Result PASS 'CRL=7 days и Delta CRL=1 day подтверждены.' }
            return New-B2Result FAIL 'CRL/Delta CRL параметры не соответствуют 7/1 days.'
        }
        'C1.07' {
            $r = Invoke-B2Evidence 'Get-Service CertSvc; certutil -config "BJ-SRV01\NB-B2-ENT-CA" -ping' {
                $svc=Get-Service CertSvc; "Service=$($svc.Name); Status=$($svc.Status); StartType=$($svc.StartType)"
                Invoke-B2NativeText @('certutil -config "BJ-SRV01\NB-B2-ENT-CA" -ping')
            } -RelevantTerms @('Service=CertSvc','Status=Running','ExitCode=0','interface is alive')
            if ($r.Ok -and (Test-B2ContainsAll $r.Text @('Status=Running','ExitCode=0'))) { return New-B2Result PASS 'CertSvc работает и CA отвечает.' }
            return New-B2Result FAIL 'CertSvc не запущен или CA ping неуспешен.'
        }
        'C1.08' {
            $r = Invoke-B2Evidence 'Get-ChildItem Cert:\LocalMachine\Root | where Subject contains NB-B2-ENT-CA' {
                foreach ($cert in @(Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -like '*NB-B2-ENT-CA*' })) {
                    "Subject=$($cert.Subject); Issuer=$($cert.Issuer); Thumbprint=$($cert.Thumbprint); NotAfter=$($cert.NotAfter.ToString('s'))"
                }
            } -RelevantTerms @('NB-B2-ENT-CA','Thumbprint=','NotAfter=')
            if ($r.Ok -and $r.Text -match 'NB-B2-ENT-CA') { return New-B2Result PASS 'Root CA присутствует в LocalMachine\Root.' }
            return New-B2Result FAIL 'Root CA не найден в trusted roots клиента.'
        }
        'C1.09' {
            $r = Invoke-B2Evidence 'certutil -catemplates | findstr NB-B2-WebServer' {
                Invoke-B2NativeText @('certutil -catemplates | findstr /I NB-B2-WebServer')
            } -RelevantTerms @('NB-B2-WebServer','ExitCode=0')
            if ($r.Ok -and (Test-B2ContainsAll $r.Text @('NB-B2-WebServer','ExitCode=0'))) { return New-B2Result PASS 'Шаблон опубликован на CA.' }
            return New-B2Result FAIL 'NB-B2-WebServer не найден среди шаблонов CA.'
        }
    }
}

function Test-B2AspectD {
    param([string]$HostKey, [string]$AspectID)
    switch ($AspectID) {
        'D1.01' {
            $r = Invoke-B2Evidence 'Get-WebVirtualDirectory | select Alias,PhysicalPath' {
                Import-Module WebAdministration
                foreach ($vdir in @(Get-WebVirtualDirectory | Where-Object { $_.Path -eq '/pki' -or $_.Name -match '/pki$' })) {
                    "VirtualDirectory=$($vdir.Path); Name=$($vdir.Name); PhysicalPath=$($vdir.PhysicalPath)"
                }
            } -RelevantTerms @('/pki','C:\PKI-Publish','PhysicalPath=')
            if ($r.Ok -and (Test-B2ContainsAll $r.Text @('/pki','C:\PKI-Publish'))) { return New-B2Result PASS 'IIS /pki указывает на C:\PKI-Publish.' }
            return New-B2Result FAIL 'Virtual directory /pki отсутствует или указывает в другой каталог.'
        }
        'D1.02' {
            $r = Invoke-B2Evidence 'Get-ChildItem C:\PKI-Publish -File' {
                foreach ($file in @(Get-ChildItem 'C:\PKI-Publish' -File -ErrorAction Stop)) {
                    "File=$($file.Name); Extension=$($file.Extension); Length=$($file.Length); LastWriteTime=$($file.LastWriteTime.ToString('s'))"
                }
            } -RelevantPattern 'File=.*\.(crl|crt|cer);'
            if ($r.Ok -and $r.Text -match '(?i)\.crl' -and $r.Text -match '(?i)\.(crt|cer)') { return New-B2Result PASS 'Опубликованы CRL и CA certificate.' }
            return New-B2Result FAIL 'В C:\PKI-Publish нет CRL или CA certificate.'
        }
        'D1.03' {
            $file = Get-B2PortalCertificateFile
            $r = Invoke-B2Evidence 'Из portal.cer получить CDP/AIA URL pki.nb-b2.local и запросить конкретные файлы' {
                if ([string]::IsNullOrWhiteSpace($file)) { throw 'Не найден C:\Temp\portal.cer или C:\Skills\B2\portal.cer.' }
                "CertificateFile=$file"
                $dump = Invoke-B2NativeText @("certutil -dump `"$file`"")
                Test-B2PublishedCertificateUrls -Dump $dump -HostPattern 'pki\.nb-b2\.local'
            } -RelevantTerms @('CertificateFile=','URL=','StatusCode=','ERROR=','PublishedUrls=')
            if ($r.Ok -and $r.Text -match '(?i)\.crl.*StatusCode=200' -and $r.Text -match '(?i)\.(crt|cer).*StatusCode=200' -and $r.Text -notmatch 'ERROR=') {
                return New-B2Result PASS 'Конкретные CRL и CA certificate доступны по internal HTTP URL.'
            }
            return New-B2Result FAIL 'Не удалось получить конкретный CRL и CA certificate через pki.nb-b2.local.'
        }
        'D1.04' {
            $r = Invoke-B2Evidence 'Получить сертификат portal.b2.lab, извлечь CDP/AIA URL и запросить конкретные файлы pki.b2.lab' {
                $dump = Get-B2RemotePortalCertDump 'portal.b2.lab'
                Test-B2PublishedCertificateUrls -Dump $dump -HostPattern 'pki\.b2\.lab'
            } -RelevantTerms @('URL=','StatusCode=','ERROR=','PublishedUrls=')
            if ($r.Ok -and $r.Text -match '(?i)\.crl.*StatusCode=200' -and $r.Text -match '(?i)\.(crt|cer).*StatusCode=200' -and $r.Text -notmatch 'ERROR=') {
                return New-B2Result PASS 'Конкретные CRL и CA certificate доступны с INET-CL01.'
            }
            return New-B2Result FAIL 'Simulated public CDP/AIA файлы не найдены или недоступны.'
        }
        { $_ -in @('D1.05','D1.06') } {
            $file = Get-B2PortalCertificateFile
            $r = Invoke-B2Evidence 'certutil -dump C:\Temp\portal.cer | показать CDP/AIA HTTP URL' {
                if ([string]::IsNullOrWhiteSpace($file)) { throw 'Не найден portal.cer.' }
                "CertificateFile=$file"
                Invoke-B2NativeText @("certutil -dump `"$file`"")
            } -RelevantPattern 'CertificateFile=|CRL Distribution|Authority Information|http://pki\.(nb-b2\.local|b2\.lab)/pki/' -ContextLines 1
            if ($AspectID -eq 'D1.05') {
                if ($r.Ok -and (Test-B2ContainsAll $r.Text @('http://pki.nb-b2.local/pki/','http://pki.b2.lab/pki/')) -and $r.Text -match '(?i)\.crl') {
                    return New-B2Result PASS 'CDP содержит оба требуемых HTTP URL.'
                }
                return New-B2Result FAIL 'В CDP отсутствует internal или simulated public URL.'
            }
            if ($r.Ok -and $r.Text -match '(?i)Authority Information|AIA' -and $r.Text -match '(?i)http://pki\.(nb-b2\.local|b2\.lab)/pki/.*\.(crt|cer)') {
                return New-B2Result PASS 'AIA содержит HTTP URL CA certificate.'
            }
            return New-B2Result FAIL 'В AIA не найден доступный HTTP URL CA certificate.'
        }
        'D1.07' {
            if ($HostKey -eq 'SHA-CL01') {
                $file = Get-B2PortalCertificateFile
                $r = Invoke-B2Evidence 'certutil -verify C:\Temp\portal.cer' {
                    if ([string]::IsNullOrWhiteSpace($file)) { throw 'Не найден portal.cer.' }
                    Invoke-B2NativeText @("certutil -verify `"$file`"")
                } -RelevantPattern 'Verified|verification|revocation|error|failed|0x[0-9a-f]+|ExitCode=' -ContextLines 1
                if ($r.Ok -and $r.Text -match 'ExitCode=0' -and $r.Text -notmatch '(?i)revocation.*(offline|failed)|untrusted|expired') {
                    return New-B2Result PASS 'Внутренняя chain/revocation verification завершилась успешно.'
                }
                return New-B2Result FAIL 'certutil обнаружил ошибку chain/revocation.'
            }
            $r = Invoke-B2Evidence 'Invoke-WebRequest https://portal.b2.lab; получить CDP/AIA из сертификата и проверить URL' {
                Invoke-B2WebEvidence 'https://portal.b2.lab'
                $dump = Get-B2RemotePortalCertDump 'portal.b2.lab'
                Test-B2PublishedCertificateUrls -Dump $dump -HostPattern 'pki\.b2\.lab'
            } -RelevantTerms @('StatusCode=','URL=','ERROR=','PublishedUrls=')
            if ($r.Ok -and $r.Text -match 'Uri=https://portal\.b2\.lab; StatusCode=200' -and $r.Text -match 'URL=.*StatusCode=200' -and $r.Text -notmatch 'ERROR=') {
                return New-B2Result PASS 'Внешний клиент доверяет порталу и получает CDP/AIA.'
            }
            return New-B2Result FAIL 'На INET-CL01 не подтверждены trust и доступность CDP/AIA.'
        }
    }
}

function Test-B2AspectE {
    param([string]$AspectID)
    switch ($AspectID) {
        'E1.01' {
            $r = Invoke-B2Evidence 'certutil -catemplates | findstr NB-B2-WebServer' {
                Invoke-B2NativeText @('certutil -catemplates | findstr /I NB-B2-WebServer')
            } -RelevantTerms @('NB-B2-WebServer','ExitCode=0')
            if ($r.Ok -and (Test-B2ContainsAll $r.Text @('NB-B2-WebServer','ExitCode=0'))) { return New-B2Result PASS 'NB-B2-WebServer опубликован на CA.' }
            return New-B2Result FAIL 'Шаблон не опубликован.'
        }
        'E1.02' {
            $r = Invoke-B2Evidence 'certutil -v -template NB-B2-WebServer' {
                Invoke-B2NativeText @('certutil -v -template NB-B2-WebServer')
            } -RelevantPattern 'NB-B2-WebServer|Server Authentication|1\.3\.6\.1\.5\.5\.7\.3\.1|Key Usage|Key Length|Minimum|Subject Name|ENROLLEE_SUPPLIES_SUBJECT|2048|4096|ExitCode=' -ContextLines 1
            $eku = $r.Text -match 'Server Authentication|1\.3\.6\.1\.5\.5\.7\.3\.1'
            $keyLength = $r.Text -match '(2048|4096)'
            $subject = $r.Text -match 'ENROLLEE_SUPPLIES_SUBJECT|Supply in the request'
            if ($r.Ok -and $r.Text -match 'NB-B2-WebServer' -and $eku -and $keyLength -and $subject -and $r.Text -match 'ExitCode=0') {
                return New-B2Result PASS 'Основные EKU, key length и Supply in request подтверждены.'
            }
            return New-B2Result WARN 'Вывод шаблона показан; проверьте Digital Signature/Key Encipherment, EKU, key length и Supply in request.'
        }
        'E1.03' {
            $r = Invoke-B2Evidence 'Get-Acl AD:\<NB-B2-WebServer template DN>' {
                Import-Module ActiveDirectory
                $root = Get-ADRootDSE
                $template = Get-ADObject -SearchBase "CN=Certificate Templates,CN=Public Key Services,CN=Services,$($root.configurationNamingContext)" -LDAPFilter '(displayName=NB-B2-WebServer)'
                "TemplateDN=$($template.DistinguishedName)"
                foreach ($ace in @((Get-Acl ("AD:\" + $template.DistinguishedName)).Access | Where-Object { $_.IdentityReference -match 'GG_B2_Web_Enroll|Domain Admins' })) {
                    "Identity=$($ace.IdentityReference); Rights=$($ace.ActiveDirectoryRights); Type=$($ace.AccessControlType); ObjectType=$($ace.ObjectType)"
                }
            } -RelevantTerms @('TemplateDN=','GG_B2_Web_Enroll','Domain Admins','Rights=','Type=Allow')
            if ($r.Ok -and (Test-B2ContainsAll $r.Text @('GG_B2_Web_Enroll','Domain Admins','Type=Allow'))) {
                return New-B2Result WARN 'ACL обеих групп найдены; по ObjectType/GUI подтвердите Enroll для GG_B2_Web_Enroll и Full Control для Domain Admins.'
            }
            if (-not $r.Ok) { return New-B2Result WARN 'Не удалось прочитать ACL шаблона локальными средствами; проверьте Security tab Certificate Templates console.' }
            return New-B2Result FAIL 'Требуемые группы не найдены в ACL шаблона.'
        }
        'E1.04' {
            $r = Invoke-B2Evidence 'Найти INF/REQ и portal certificate с private key на SHA-WEB01' {
                foreach ($root in @('C:\Skills\B2','C:\Temp','C:\Web')) {
                    if (Test-Path $root) {
                        foreach ($f in @(Get-ChildItem $root -Recurse -File -Include *.inf,*.req -ErrorAction SilentlyContinue)) { "RequestFile=$($f.FullName); Extension=$($f.Extension); Length=$($f.Length)" }
                    }
                }
                Get-B2PortalCertStoreEvidence
            } -RelevantTerms @('RequestFile=','.inf','.req','Subject=','HasPrivateKey=','DNS=')
            if ($r.Ok -and $r.Text -match '(?i)\.inf' -and $r.Text -match '(?i)\.req' -and $r.Text -match 'HasPrivateKey=True') {
                return New-B2Result PASS 'INF/REQ найдены, portal certificate связан с локальным private key.'
            }
            return New-B2Result FAIL 'Не найдены CSR-материалы или связанный private key.'
        }
        'E1.05' {
            $r = Invoke-B2Evidence 'certutil -view issued requests for NB-B2-WebServer' {
                Invoke-B2NativeText @('certutil -view -restrict "Disposition=20,CertificateTemplate=NB-B2-WebServer" -out "RequestID,CertificateTemplate,CommonName,RequesterName,NotAfter"')
            } -RelevantPattern 'NB-B2-WebServer|portal|RequestID|RequesterName|NotAfter|ExitCode=' -ContextLines 1
            if ($r.Ok -and $r.Text -match 'NB-B2-WebServer' -and $r.Text -match 'portal' -and $r.Text -match 'ExitCode=0') {
                return New-B2Result PASS 'В CA database найден выданный portal certificate по нужному шаблону.'
            }
            return New-B2Result WARN 'CA database показана, но issuer/template конкретного portal certificate нужно подтвердить по строкам вывода.'
        }
        'E1.06' {
            $file = Get-B2PortalCertificateFile
            $r = Invoke-B2Evidence 'certutil -dump C:\Temp\portal.cer | SAN' {
                if ([string]::IsNullOrWhiteSpace($file)) { throw 'Не найден portal.cer.' }
                Invoke-B2NativeText @("certutil -dump `"$file`"")
            } -RelevantPattern 'Subject Alternative Name|DNS Name|portal\.(nb-b2\.local|b2\.lab)|ExitCode=' -ContextLines 1
            if ($r.Ok -and (Test-B2ContainsAll $r.Text @('portal.nb-b2.local','portal.b2.lab','ExitCode=0'))) { return New-B2Result PASS 'Оба SAN присутствуют.' }
            return New-B2Result FAIL 'В portal certificate отсутствует один из SAN.'
        }
        'E1.07' {
            $r = Invoke-B2Evidence 'Get-ChildItem Cert:\LocalMachine\My | portal certificate' {
                Get-B2PortalCertStoreEvidence
            } -RelevantTerms @('Subject=','Issuer=','HasPrivateKey=','DNS=','NB-B2-ENT-CA','portal.nb-b2.local','portal.b2.lab')
            if ($r.Ok -and (Test-B2ContainsAll $r.Text @('HasPrivateKey=True','NB-B2-ENT-CA','portal.nb-b2.local','portal.b2.lab'))) {
                return New-B2Result PASS 'Portal certificate установлен в LocalMachine\My и имеет private key.'
            }
            return New-B2Result FAIL 'Сертификат отсутствует, не имеет private key или содержит неверные issuer/SAN.'
        }
    }
}

function Test-B2AspectF {
    param([string]$HostKey, [string]$AspectID)
    switch ($AspectID) {
        'F1.01' {
            $r = Invoke-B2Evidence 'Resolve-DnsName portal/status/pki.nb-b2.local' {
                Get-B2DnsEvidence 'portal.nb-b2.local' ''
                Get-B2DnsEvidence 'status.nb-b2.local' ''
                Get-B2DnsEvidence 'pki.nb-b2.local' ''
            } -RelevantTerms @('portal.nb-b2.local','status.nb-b2.local','pki.nb-b2.local','IPAddress=')
            if ($r.Ok -and (Test-B2ContainsAll $r.Text @('10.22.10.11','10.22.10.12','10.32.20.20'))) { return New-B2Result PASS 'Все internal A records корректны.' }
            return New-B2Result FAIL 'Одна из internal A records отсутствует или неверна.'
        }
        'F1.02' {
            $r = Invoke-B2Evidence 'Resolve-DnsName ca.nb-b2.local -Type CNAME' { Get-B2DnsEvidence 'ca.nb-b2.local' '' 'CNAME' } -RelevantTerms @('ca.nb-b2.local','bj-srv01.nb-b2.local','NameHost=')
            if ($r.Ok -and $r.Text -match 'bj-srv01\.nb-b2\.local') { return New-B2Result PASS 'CNAME ca указывает на BJ-SRV01.' }
            return New-B2Result FAIL 'CNAME ca отсутствует или имеет неверную цель.'
        }
        'F1.03' {
            $r = Invoke-B2Evidence 'Resolve-DnsName 10.22.10.11, 10.22.10.12, 10.32.20.20 -Type PTR' {
                Get-B2DnsEvidence '10.22.10.11' '' 'PTR'
                Get-B2DnsEvidence '10.22.10.12' '' 'PTR'
                Get-B2DnsEvidence '10.32.20.20' '' 'PTR'
            } -RelevantTerms @('NameHost=','portal','status','pki','sha-web01','sha-app01','bj-srv01')
            $ptrCount = ([regex]::Matches($r.Text,'Type=PTR','IgnoreCase')).Count
            if ($r.Ok -and $ptrCount -ge 3) { return New-B2Result PASS 'Три PTR-записи получены.' }
            return New-B2Result FAIL 'Не подтверждены PTR для всех трёх адресов.'
        }
        'F1.04' {
            $r = Invoke-B2Evidence 'Get-DnsServerZone -Name b2.lab' {
                $zone=Get-DnsServerZone -Name 'b2.lab'; "Zone=$($zone.ZoneName); Type=$($zone.ZoneType); IsDsIntegrated=$($zone.IsDsIntegrated); IsReverseLookupZone=$($zone.IsReverseLookupZone)"
            } -RelevantTerms @('Zone=b2.lab','Type=','IsReverseLookupZone=False')
            if ($r.Ok -and $r.Text -match 'Zone=b2\.lab') { return New-B2Result PASS 'Simulated public zone b2.lab существует.' }
            return New-B2Result FAIL 'Зона b2.lab не найдена.'
        }
        { $_ -in @('F1.05','F1.07') } {
            $r = Invoke-B2Evidence 'Resolve-DnsName portal.b2.lab and pki.b2.lab -Server 198.18.200.10' {
                Get-B2DnsEvidence 'portal.b2.lab' '198.18.200.10'
                Get-B2DnsEvidence 'pki.b2.lab' '198.18.200.10'
            } -RelevantTerms @('portal.b2.lab','pki.b2.lab','10.22.10.11','10.32.20.20')
            if ($r.Ok -and (Test-B2ContainsAll $r.Text @('10.22.10.11','10.32.20.20'))) { return New-B2Result PASS 'Оба simulated public имени разрешены через INET-SRV01.' }
            return New-B2Result FAIL 'Simulated public DNS records отсутствуют или неверны.'
        }
        'F1.06' {
            $r = Invoke-B2Evidence 'Resolve-DnsName portal/status/pki.nb-b2.local' {
                Get-B2DnsEvidence 'portal.nb-b2.local' ''
                Get-B2DnsEvidence 'status.nb-b2.local' ''
                Get-B2DnsEvidence 'pki.nb-b2.local' ''
            } -RelevantTerms @('portal.nb-b2.local','status.nb-b2.local','pki.nb-b2.local','IPAddress=')
            if ($r.Ok -and (Test-B2ContainsAll $r.Text @('10.22.10.11','10.22.10.12','10.32.20.20'))) { return New-B2Result PASS "На $HostKey все internal B2 имена разрешаются." }
            return New-B2Result FAIL "На $HostKey не разрешается одно из internal B2 имён."
        }
    }
}

function Test-B2AspectG {
    param([string]$HostKey, [string]$AspectID)
    switch ($AspectID) {
        'G1.01' {
            $r = Invoke-B2Evidence 'Get-WindowsFeature Web-Server; Get-Website B2Portal; Test-Path C:\Web\B2Portal' {
                Get-B2FeatureEvidence 'Web-Server'
                Get-B2WebsiteEvidence 'B2Portal'
                "Path=C:\Web\B2Portal; Exists=$(Test-Path 'C:\Web\B2Portal')"
            } -RelevantTerms @('Feature=Web-Server','Installed=True','Website=B2Portal','PhysicalPath=C:\Web\B2Portal','Exists=True')
            if ($r.Ok -and (Test-B2ContainsAll $r.Text @('Installed=True','Website=B2Portal','PhysicalPath=C:\Web\B2Portal','Exists=True'))) {
                return New-B2Result PASS 'IIS, B2Portal и физический каталог подтверждены.'
            }
            return New-B2Result FAIL 'IIS, сайт или каталог B2Portal отсутствует.'
        }
        'G1.02' {
            $r = Invoke-B2Evidence 'Get-WebBinding -Name B2Portal' { Get-B2BindingEvidence 'B2Portal' } -RelevantTerms @('Protocol=','BindingInformation=')
            if ($r.Ok -and $r.Text -match 'Protocol=https' -and $r.Text -notmatch 'Protocol=http;.*:80:') { return New-B2Result PASS 'У B2Portal нет HTTP/80 binding.' }
            return New-B2Result FAIL 'У B2Portal найден HTTP/80 binding или отсутствует HTTPS.'
        }
        'G1.03' {
            $r = Invoke-B2Evidence 'Get-WebBinding -Name B2Portal | HTTPS bindings' { Get-B2BindingEvidence 'B2Portal' } -RelevantTerms @('Protocol=https','BindingInformation=','SslFlags=')
            $https = @($r.Text -split "`r?`n" | Where-Object { $_ -match 'Protocol=https' -and $_ -match ':443:' })
            $wildcard = @($https | Where-Object { $_ -match 'BindingInformation=[^;]*:443:\s*;' }).Count -gt 0
            $both = (Test-B2ContainsAll ($https -join "`n") @('portal.nb-b2.local','portal.b2.lab'))
            if ($r.Ok -and ($wildcard -or $both)) { return New-B2Result PASS 'HTTPS/443 binding обслуживает оба имени допустимым способом.' }
            return New-B2Result FAIL 'Не подтверждено обслуживание обоих имён на HTTPS/443.'
        }
        'G1.04' {
            $r = Invoke-B2Evidence 'Сопоставить certificateHash IIS HTTPS binding с LocalMachine\My' {
                Import-Module WebAdministration
                foreach ($binding in @(Get-WebBinding -Name 'B2Portal' -Protocol https)) {
                    $rawHash = $binding.certificateHash
                    if ($rawHash -is [byte[]]) { $hash = (($rawHash | ForEach-Object { $_.ToString('X2') }) -join '') }
                    else { $hash = ([string]$rawHash).Replace(' ','').ToUpperInvariant() }
                    "Binding=$($binding.bindingInformation); CertificateHash=$hash"
                    $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -eq $hash } | Select-Object -First 1
                    if ($null -eq $cert) { "BoundCertificate=NOT_FOUND"; continue }
                    "BoundSubject=$($cert.Subject); BoundIssuer=$($cert.Issuer); HasPrivateKey=$($cert.HasPrivateKey); DNS=$(@($cert.DnsNameList.Unicode) -join ',')"
                }
            } -RelevantTerms @('Binding=','CertificateHash=','BoundSubject=','BoundIssuer=','HasPrivateKey=','DNS=','NOT_FOUND')
            if ($r.Ok -and (Test-B2ContainsAll $r.Text @('NB-B2-ENT-CA','HasPrivateKey=True','portal.nb-b2.local','portal.b2.lab')) -and $r.Text -notmatch 'NOT_FOUND') {
                return New-B2Result PASS 'IIS binding использует нужный portal certificate.'
            }
            return New-B2Result FAIL 'Binding не сопоставлен с сертификатом нужного issuer/SAN.'
        }
        'G1.05' {
            $r = Invoke-B2Evidence 'Get-WebConfigurationProperty AnonymousAuthentication and DirectoryBrowse for B2Portal' {
                Import-Module WebAdministration
                $anon = Get-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Location 'B2Portal' -Filter 'system.webServer/security/authentication/anonymousAuthentication' -Name enabled
                $browse = Get-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Location 'B2Portal' -Filter 'system.webServer/directoryBrowse' -Name enabled
                "AnonymousEnabled=$($anon.Value); DirectoryBrowsingEnabled=$($browse.Value)"
            } -RelevantTerms @('AnonymousEnabled=','DirectoryBrowsingEnabled=')
            if ($r.Ok -and (Test-B2ContainsAll $r.Text @('AnonymousEnabled=True','DirectoryBrowsingEnabled=False'))) { return New-B2Result PASS 'Anonymous включена, directory browsing отключён.' }
            return New-B2Result FAIL 'Authentication или directory browsing настроены неверно.'
        }
        'G1.06' {
            $r = Invoke-B2Evidence 'Invoke-WebRequest https://portal.nb-b2.local' { Invoke-B2WebEvidence 'https://portal.nb-b2.local' } -RelevantTerms @('Uri=','StatusCode=','Content=','ERROR')
            if ($r.Ok -and $r.Text -match 'StatusCode=200') { return New-B2Result PASS "На $HostKey портал открывается без certificate warning." }
            return New-B2Result FAIL "На $HostKey HTTPS portal не прошёл проверку доверия/доступности."
        }
        'G1.07' {
            $r = Invoke-B2Evidence 'Invoke-WebRequest https://portal.b2.lab' { Invoke-B2WebEvidence 'https://portal.b2.lab' } -RelevantTerms @('Uri=','StatusCode=','Content=','ERROR')
            if ($r.Ok -and $r.Text -match 'StatusCode=200') { return New-B2Result PASS 'Simulated public portal открывается без certificate warning.' }
            return New-B2Result FAIL 'HTTPS portal.b2.lab недоступен или не проходит TLS validation.'
        }
        'G1.08' {
            $r = Invoke-B2Evidence 'Get-Content C:\Web\B2Portal\index.html' { Get-Content 'C:\Web\B2Portal\index.html' -Raw } -RelevantTerms @('NorthBridge B2 Secure Portal','Host: SHA-WEB01','Service: HTTPS Portal','Status: OK')
            $required = @('NorthBridge B2 Secure Portal','Host: SHA-WEB01','Service: HTTPS Portal','Status: OK')
            if ($r.Ok -and (Test-B2ContainsAll $r.Text $required)) { return New-B2Result PASS 'Страница содержит весь требуемый текст.' }
            return New-B2Result FAIL 'В index.html отсутствует требуемая строка.'
        }
    }
}

function Test-B2AspectH {
    param([string]$HostKey, [string]$AspectID)
    switch ($AspectID) {
        'H1.01' {
            $r = Invoke-B2Evidence 'Get-WindowsFeature Web-Server; Get-Website B2Status; Get-Content index.html' {
                Get-B2FeatureEvidence 'Web-Server'
                Get-B2WebsiteEvidence 'B2Status'
                "Path=C:\Web\B2Status; Exists=$(Test-Path 'C:\Web\B2Status')"
                Get-Content 'C:\Web\B2Status\index.html' -Raw -ErrorAction SilentlyContinue
            } -RelevantTerms @('Installed=True','Website=B2Status','PhysicalPath=C:\Web\B2Status','NorthBridge B2 Status Service','Host: SHA-APP01','Status: OK')
            $required = @('Installed=True','Website=B2Status','PhysicalPath=C:\Web\B2Status','NorthBridge B2 Status Service','Host: SHA-APP01','Status: OK')
            if ($r.Ok -and (Test-B2ContainsAll $r.Text $required)) { return New-B2Result PASS 'IIS, B2Status, path и содержимое подтверждены.' }
            return New-B2Result FAIL 'B2Status или его содержимое не соответствует заданию.'
        }
        'H1.02' {
            $r = Invoke-B2Evidence 'Get-WebBinding -Name B2Status' { Get-B2BindingEvidence 'B2Status' } -RelevantTerms @('Protocol=http','BindingInformation=','status.nb-b2.local')
            if ($r.Ok -and $r.Text -match 'Protocol=http' -and $r.Text -match ':8080:status\.nb-b2\.local') { return New-B2Result PASS 'HTTP/8080 binding с нужным hostname настроен.' }
            return New-B2Result FAIL 'Binding B2Status не соответствует HTTP/8080 status.nb-b2.local.'
        }
        'H1.03' {
            $r = Invoke-B2Evidence 'Test-NetConnection status.nb-b2.local -Port 8080; Invoke-WebRequest http://status.nb-b2.local:8080' {
                Get-B2TcpEvidence 'status.nb-b2.local' 8080
                Invoke-B2WebEvidence 'http://status.nb-b2.local:8080'
            } -RelevantTerms @('TcpTestSucceeded=','StatusCode=','Content=','NorthBridge B2 Status Service')
            if ($r.Ok -and (Test-B2ContainsAll $r.Text @('TcpTestSucceeded=True','StatusCode=200'))) { return New-B2Result PASS "B2Status доступен с $HostKey." }
            return New-B2Result FAIL "B2Status недоступен с $HostKey."
        }
        'H1.04' {
            $r = Invoke-B2Evidence 'Test-NetConnection 10.22.10.12 -Port 8080' { Get-B2TcpEvidence '10.22.10.12' 8080 } -RelevantTerms @('Target=','Port=','TcpTestSucceeded=')
            if ($r.Ok -and $r.Text -match 'TcpTestSucceeded=False') { return New-B2Result PASS 'Status service недоступен с INET-CL01.' }
            return New-B2Result FAIL 'INET-CL01 имеет доступ к status service.'
        }
    }
}

function Test-B2AspectI {
    param([string]$HostKey, [string]$AspectID)
    switch ($AspectID) {
        'I1.01' {
            $r = Invoke-B2Evidence 'Get-NetFirewallRule/PortFilter/AddressFilter for TCP/443' { Get-B2FirewallEvidence @(443) } -RelevantTerms @('LocalPort=443','RemoteAddress=','10.22.30.0/24','10.32.30.0/24','198.18.201.10')
            if ($r.Ok -and (Test-B2ContainsAll $r.Text @('10.22.30.0/24','10.32.30.0/24','198.18.201.10')) -and $r.Text -notmatch 'RemoteAddress=Any') {
                return New-B2Result PASS 'Firewall HTTPS разрешает три требуемых источника без Any.'
            }
            return New-B2Result FAIL 'Firewall TCP/443 не содержит все требуемые RemoteAddress или разрешает Any.'
        }
        'I1.02' {
            $target = if ($HostKey -eq 'INET-CL01') { 'portal.b2.lab' } else { 'portal.nb-b2.local' }
            $r = Invoke-B2Evidence "Test-NetConnection $target -Port 80" { Get-B2TcpEvidence $target 80 } -RelevantTerms @('Target=','Port=80','TcpTestSucceeded=')
            if ($r.Ok -and $r.Text -match 'TcpTestSucceeded=False') { return New-B2Result PASS "HTTP/80 не принимается с $HostKey." }
            return New-B2Result FAIL "HTTP/80 доступен с $HostKey."
        }
        'I1.03' {
            $r = Invoke-B2Evidence 'Get-NetFirewallRule for TCP/5985 on SHA-WEB01' { Get-B2FirewallEvidence @(5985) } -RelevantTerms @('LocalPort=5985','RemoteAddress=','10.22.30.0/24','198.18.201.10','Any')
            if ($r.Ok -and $r.Text -match '10\.22\.30\.0/24' -and $r.Text -notmatch '198\.18\.201\.10|RemoteAddress=Any') { return New-B2Result PASS 'WinRM разрешён только из Shanghai ClientNet.' }
            return New-B2Result FAIL 'WinRM RemoteAddress слишком широк или не включает Shanghai ClientNet.'
        }
        'I1.04' {
            $r = Invoke-B2Evidence 'Get-NetFirewallRule for TCP/8080 on SHA-APP01' { Get-B2FirewallEvidence @(8080) } -RelevantTerms @('LocalPort=8080','RemoteAddress=','10.22.30.0/24','10.32.30.0/24','Any')
            if ($r.Ok -and (Test-B2ContainsAll $r.Text @('10.22.30.0/24','10.32.30.0/24')) -and $r.Text -notmatch 'RemoteAddress=Any') { return New-B2Result PASS 'TCP/8080 разрешён для обеих внутренних ClientNet.' }
            return New-B2Result FAIL 'Firewall TCP/8080 не соответствует двум внутренним ClientNet.'
        }
        'I1.05' {
            $r = Invoke-B2Evidence 'Test-NetConnection 10.22.10.12 -Port 8080' { Get-B2TcpEvidence '10.22.10.12' 8080 } -RelevantTerms @('Target=','Port=8080','TcpTestSucceeded=')
            if ($r.Ok -and $r.Text -match 'TcpTestSucceeded=False') { return New-B2Result PASS 'INET-CL01 заблокирован на TCP/8080.' }
            return New-B2Result FAIL 'INET-CL01 проходит к SHA-APP01:8080.'
        }
        'I1.06' {
            $r = Invoke-B2Evidence 'Get-NetFirewallRule for TCP/5985 on SHA-APP01' { Get-B2FirewallEvidence @(5985) } -RelevantTerms @('LocalPort=5985','RemoteAddress=','10.22.30.0/24','198.18.201.10','Any')
            if ($r.Ok -and $r.Text -match '10\.22\.30\.0/24' -and $r.Text -notmatch '198\.18\.201\.10|RemoteAddress=Any') { return New-B2Result PASS 'WinRM SHA-APP01 ограничен Shanghai ClientNet.' }
            return New-B2Result FAIL 'WinRM SHA-APP01 имеет неверные RemoteAddress.'
        }
        'I1.07' {
            $r = Invoke-B2Evidence 'Get-NetFirewallRule for TCP/80 on BJ-SRV01' { Get-B2FirewallEvidence @(80) } -RelevantTerms @('LocalPort=80','RemoteAddress=','10.22.30.0/24','10.32.30.0/24','198.18.201.10','Any')
            if ($r.Ok -and (Test-B2ContainsAll $r.Text @('10.22.30.0/24','10.32.30.0/24','198.18.201.10'))) { return New-B2Result PASS 'HTTP CDP/AIA разрешён всем требуемым клиентам.' }
            return New-B2Result FAIL 'Firewall BJ-SRV01:80 не включает один из требуемых источников.'
        }
        'I1.08' {
            $r = Invoke-B2Evidence 'Test-NetConnection 10.32.20.20 -Port 135,445,5985,3389' {
                foreach ($port in @(135,445,5985,3389)) { Get-B2TcpEvidence '10.32.20.20' $port }
            } -RelevantTerms @('Port=135','Port=445','Port=5985','Port=3389','TcpTestSucceeded=')
            $blocked = ([regex]::Matches($r.Text,'TcpTestSucceeded=False','IgnoreCase')).Count
            if ($r.Ok -and $blocked -eq 4) { return New-B2Result PASS 'Все четыре management-порта недоступны с INET-CL01.' }
            return New-B2Result FAIL 'Хотя бы один management-порт BJ-SRV01 доступен с simulated Internet.'
        }
    }
}

function Test-B2AspectJ {
    param([string]$HostKey, [string]$AspectID)
    switch ($AspectID) {
        'J1.01' {
            $file = Get-B2PortalCertificateFile
            $r = Invoke-B2Evidence 'Invoke-WebRequest https://portal.nb-b2.local; certutil -verify portal.cer' {
                Invoke-B2WebEvidence 'https://portal.nb-b2.local'
                if ([string]::IsNullOrWhiteSpace($file)) { throw 'Не найден portal.cer.' }
                Invoke-B2NativeText @("certutil -verify `"$file`"")
            } -RelevantPattern 'StatusCode=|Verified|verification|revocation|error|failed|ExitCode=' -ContextLines 1
            if ($r.Ok -and $r.Text -match 'StatusCode=200' -and $r.Text -match 'ExitCode=0' -and $r.Text -notmatch '(?i)untrusted|revocation.*(offline|failed)|expired') {
                return New-B2Result PASS 'HTTPS trust и certutil verification успешны.'
            }
            return New-B2Result FAIL 'SHA-CL01 обнаружил ошибку HTTPS trust/chain/revocation.'
        }
        'J1.02' {
            $r = Invoke-B2Evidence 'Invoke-WebRequest https://portal.nb-b2.local' { Invoke-B2WebEvidence 'https://portal.nb-b2.local' } -RelevantTerms @('Uri=','StatusCode=','Content=')
            if ($r.Ok -and $r.Text -match 'StatusCode=200') { return New-B2Result PASS 'BJ-CL01 доверяет internal portal certificate.' }
            return New-B2Result FAIL 'BJ-CL01 не открывает портал без TLS warning.'
        }
        'J1.03' {
            $r = Invoke-B2Evidence 'Проверить Root CA в LocalMachine\Root; Invoke-WebRequest https://portal.b2.lab' {
                foreach ($cert in @(Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -like '*NB-B2-ENT-CA*' })) { "TrustedRoot=$($cert.Subject); Thumbprint=$($cert.Thumbprint)" }
                Invoke-B2WebEvidence 'https://portal.b2.lab'
            } -RelevantTerms @('TrustedRoot=','NB-B2-ENT-CA','StatusCode=','Content=')
            if ($r.Ok -and (Test-B2ContainsAll $r.Text @('TrustedRoot=','NB-B2-ENT-CA','StatusCode=200'))) { return New-B2Result PASS 'Root CA установлен вручную, portal.b2.lab проходит TLS validation.' }
            return New-B2Result FAIL 'На INET-CL01 отсутствует Root CA или HTTPS validation неуспешна.'
        }
        'J1.04' {
            if ($HostKey -eq 'SHA-CL01') {
                $file = Get-B2PortalCertificateFile
                $r = Invoke-B2Evidence 'certutil -verify portal.cer' {
                    if ([string]::IsNullOrWhiteSpace($file)) { throw 'Не найден portal.cer.' }
                    Invoke-B2NativeText @("certutil -verify `"$file`"")
                } -RelevantPattern 'Verified|verification|revocation|error|failed|ExitCode=' -ContextLines 1
                if ($r.Ok -and $r.Text -match 'ExitCode=0' -and $r.Text -notmatch '(?i)untrusted|revocation.*(offline|failed)|expired') { return New-B2Result PASS 'Внутренняя chain/revocation validation успешна.' }
                return New-B2Result FAIL 'Внутренняя chain/revocation validation завершилась ошибкой.'
            }
            $r = Invoke-B2Evidence 'Invoke-WebRequest portal.b2.lab; проверить CDP/AIA из server certificate' {
                Invoke-B2WebEvidence 'https://portal.b2.lab'
                $dump=Get-B2RemotePortalCertDump 'portal.b2.lab'
                Test-B2PublishedCertificateUrls -Dump $dump -HostPattern 'pki\.b2\.lab'
            } -RelevantTerms @('StatusCode=','URL=','ERROR=','PublishedUrls=')
            if ($r.Ok -and $r.Text -match 'Uri=https://portal\.b2\.lab; StatusCode=200' -and $r.Text -match 'URL=.*StatusCode=200' -and $r.Text -notmatch 'ERROR=') { return New-B2Result PASS 'Внешний trust и CDP/AIA validation подтверждены.' }
            return New-B2Result FAIL 'Внешний клиент обнаружил ошибку trust или недоступность CDP/AIA.'
        }
        'J1.05' {
            $files = @('B2-foundation-check.ps1','New-B2WebCertRequest.inf','Submit-B2WebCert.ps1','Configure-B2DNS.ps1','Configure-B2Firewall.ps1','B2-selfcheck.txt','portal.cer')
            $r = Invoke-B2Evidence 'Test-Path required files under C:\Skills\B2' {
                foreach ($name in $files) {
                    $path=Join-Path 'C:\Skills\B2' $name
                    "File=$name; Exists=$(Test-Path -LiteralPath $path); Path=$path"
                }
            } -RelevantTerms $files
            $ok = $r.Ok
            foreach ($name in $files) {
                if ($r.Text -notmatch ([regex]::Escape("File=$name") + '; Exists=True')) { $ok=$false }
            }
            if ($ok) { return New-B2Result PASS 'Все семь локальных материалов сдачи присутствуют.' }
            return New-B2Result FAIL 'В C:\Skills\B2 отсутствует один или несколько обязательных файлов.'
        }
    }
}

function Invoke-B2Aspect {
    param([string]$HostKey, [object]$Aspect)
    $group = ($Aspect.AspectID -split '\.')[0]
    switch ($group) {
        'A1' { return Test-B2AspectA $HostKey $Aspect.AspectID }
        'B1' { return Test-B2AspectB $Aspect.AspectID }
        'C1' { return Test-B2AspectC $Aspect.AspectID }
        'D1' { return Test-B2AspectD $HostKey $Aspect.AspectID }
        'E1' { return Test-B2AspectE $Aspect.AspectID }
        'F1' { return Test-B2AspectF $HostKey $Aspect.AspectID }
        'G1' { return Test-B2AspectG $HostKey $Aspect.AspectID }
        'H1' { return Test-B2AspectH $HostKey $Aspect.AspectID }
        'I1' { return Test-B2AspectI $HostKey $Aspect.AspectID }
        'J1' { return Test-B2AspectJ $HostKey $Aspect.AspectID }
    }
    return New-B2Result WARN "Для $($Aspect.AspectID) нет evaluator."
}

function Write-B2Summary {
    $total=0.0; $passed=0.0; $failed=0.0; $warn=0.0
    foreach ($row in @($script:B2Rows)) {
        $mark=[double]$row.MaxMark; $total += $mark
        switch ($row.Status) { 'PASS' {$passed += $mark}; 'FAIL' {$failed += $mark}; default {$warn += $mark} }
    }
    $lines = @(
        'B2 Local Evaluation Summary',
        '===========================',
        "Passed marks: $([Math]::Round($passed,2)) / $([Math]::Round($total,2))",
        "Failed marks: $([Math]::Round($failed,2))",
        "Warn marks:   $([Math]::Round($warn,2))",
        'Итог относится только к локальным аспектам этого хоста; повторные cross-host аспекты не суммируются между хостами.'
    )
    Write-Host ''
    Write-B2Log ($lines -join [Environment]::NewLine) DarkGray
    if ($script:B2ReportEnabled) { Set-Content -LiteralPath $script:B2SummaryPath -Value ($lines -join [Environment]::NewLine) -Encoding UTF8 }
}

function Invoke-B2HostChecks {
    param(
        [Parameter(Mandatory=$true)][string]$HostKey,
        [switch]$Report,
        [string]$ReportDir,
        [switch]$NoPause,
        [string]$StartFromAspect
    )
    $HostKey = $HostKey.ToUpperInvariant()
    $script:B2PauseBetweenChecks = -not $NoPause
    Initialize-B2Report -HostKey $HostKey -Report:$Report -ReportDir $ReportDir
    Write-B2Section "B2 local checks for $HostKey"
    Write-B2Log "B2 checker version: $script:B2Version" Green
    Write-B2Log "B2 common: $PSCommandPath" DarkGray
    Write-B2Log "B2 criteria: $script:B2CriteriaPath" DarkGray
    if ($script:B2ReportEnabled) { Write-B2Log "Каталог отчета: $script:B2ReportDir" DarkGray }
    else { Write-B2Log 'Отчет отключен. Для записи используйте -Report или -ReportDir <path>.' DarkGray }

    $criteria = @(Get-B2Criteria -HostKey $HostKey)
    if ($criteria.Count -eq 0) { throw "Для хоста $HostKey не найдены локальные критерии B2." }
    foreach ($aspect in $criteria) {
        if (-not [string]::IsNullOrWhiteSpace($StartFromAspect) -and [string]::Compare($aspect.AspectID,$StartFromAspect,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        Start-B2Aspect $aspect
        try {
            $result = Invoke-B2Aspect -HostKey $HostKey -Aspect $aspect
            if ($null -eq $result -or @($result).Count -lt 2) { throw "Evaluator $($aspect.AspectID) не вернул результат." }
            Complete-B2Aspect -Aspect $aspect -Status $result[0] -Message $result[1]
        } catch {
            $exceptionText = $_.Exception.ToString()
            $exceptionMessage = $_.Exception.Message
            Invoke-B2Evidence 'Unhandled checker exception' { $exceptionText } | Out-Null
            Complete-B2Aspect -Aspect $aspect -Status WARN -Message "Ошибка checker: $exceptionMessage"
        }
    }
    Write-B2Summary
}
