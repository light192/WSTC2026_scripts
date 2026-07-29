Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:B4Root = Split-Path -Parent $PSScriptRoot
$script:B4CriteriaPath = Join-Path $script:B4Root 'criteria\b4_device_criteria_map.tsv'
$script:B4Version = '2026-07-28.27'
$script:B4Pause = $true
$script:B4Report = $false
$script:B4Rows = @()

function ConvertTo-B4Text {
    param([object]$Value)
    if ($null -eq $Value) { return '' }
    $parts = foreach ($item in @($Value)) {
        if ($null -eq $item) { continue }
        if ($item.PSObject.BaseObject -is [string] -or $item.PSObject.BaseObject -is [ValueType]) {
            ([string]$item).TrimEnd()
        } else {
            ($item | Out-String -Width 4096).TrimEnd()
        }
    }
    return (($parts -join [Environment]::NewLine).TrimEnd())
}

function Write-B4Log {
    param([string]$Text,[ConsoleColor]$Color=[ConsoleColor]::Gray)
    Write-Host $Text -ForegroundColor $Color
    if ($script:B4Report) { Add-Content -LiteralPath $script:B4DetailPath -Value $Text -Encoding UTF8 }
}

function Write-B4Section {
    param([string]$Text)
    Write-Host ''
    Write-B4Log ('#' * 86) Magenta
    Write-B4Log $Text Magenta
    Write-B4Log ('#' * 86) Magenta
}

function Initialize-B4Report {
    param([string]$HostKey,[switch]$Report,[string]$ReportDir)
    $script:B4Rows=@(); $script:B4Report=$false
    if (-not $Report -and [string]::IsNullOrWhiteSpace($ReportDir)) { return }
    if ([string]::IsNullOrWhiteSpace($ReportDir)) { $ReportDir=Join-Path $script:B4Root "reports\$HostKey" }
    New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
    $script:B4ReportDir=$ReportDir
    $script:B4DetailPath=Join-Path $ReportDir 'b4-detail.log'
    $script:B4ResultsPath=Join-Path $ReportDir 'b4-results.tsv'
    $script:B4SummaryPath=Join-Path $ReportDir 'b4-summary.txt'
    Set-Content $script:B4DetailPath '' -Encoding UTF8
    Set-Content $script:B4ResultsPath "AspectID`tHostKey`tMaxMark`tAwarded`tStatus`tMessage" -Encoding UTF8
    $script:B4Report=$true
}

function Get-B4Criteria {
    param([string]$HostKey)
    if (-not (Test-Path $script:B4CriteriaPath)) { throw "Не найдена карта: $script:B4CriteriaPath" }
    return @(Import-Csv $script:B4CriteriaPath -Delimiter "`t" -Encoding UTF8 |
        Where-Object HostKey -eq $HostKey)
}

function Start-B4Aspect {
    param([object]$Aspect)
    Write-Host ''
    Write-B4Log "[$($Aspect.AspectID)] $($Aspect.Requirement)" Yellow
    Write-B4Log "Раздел: $($Aspect.TaskRef); максимум: $($Aspect.MaxMark)" DarkYellow
    Write-B4Log 'Полная команда из marking scheme (можно скопировать):' Green
    Write-B4Log $Aspect.VerificationCommands DarkGreen
    Write-B4Log 'Готовые команды для отдельной ручной проверки (можно скопировать):' Green
    Write-B4Log (Get-B4StandaloneCommands $Aspect) DarkGreen
    Write-B4Log "Ожидаемый результат: $($Aspect.ExpectedResult)" Cyan
    Write-B4Log "Точные проверяемые свойства: $($Aspect.Requirement)" DarkCyan
}

function Get-B4StandaloneCommands {
    param([object]$Aspect)
    switch([string]$Aspect.AspectID) {
        {$_ -in @('SHA-RTR01-04','BJ-RTR01-04')} {
            return @'
Get-NetIPAddress -AddressFamily IPv4 | Format-Table InterfaceAlias,IPAddress,PrefixLength,InterfaceIndex -AutoSize
Get-Service RemoteAccess | Format-List Name,Status,StartType
netsh.exe routing ip relay show global
netsh.exe routing ip relay show interface
reg.exe query "HKLM\SYSTEM\CurrentControlSet\Services\RemoteAccess" /s
'@
        }
        {$_ -in @('SHA-RTR01-05','BJ-RTR01-05')} {
            return @'
Get-WindowsFeature RemoteAccess,Routing | Format-Table Name,InstallState -AutoSize
Get-NetNat -ErrorAction SilentlyContinue | Format-List *
Get-Service RemoteAccess | Format-List Name,Status,StartType
reg.exe query "HKLM\SYSTEM\CurrentControlSet\Services\RemoteAccess" /s /f NAT
'@
        }
        'BJ-RTR01-02' {
            return "Get-NetIPInterface -AddressFamily IPv4 | Format-Table InterfaceAlias,ConnectionState,Forwarding -AutoSize`nGet-Service RemoteAccess | Format-List Name,Status,StartType"
        }
        'SHA-DC01-06' {
            return "Get-DnsServerZone -Name nb-b4.local | Format-List ZoneName,ZoneType,IsDsIntegrated,ReplicationScope,DynamicUpdate"
        }
        'SHA-DC01-12' {
            return "Get-ADOrganizationalUnit -Filter * | Sort-Object DistinguishedName | Format-Table Name,DistinguishedName -AutoSize"
        }
        'SHA-DC01-13' {
            return "Get-ADGroup -Filter `"Name -like 'GG_B4_*'`" -Properties GroupScope,GroupCategory,DistinguishedName | Sort-Object Name | Format-Table Name,GroupScope,GroupCategory,DistinguishedName -AutoSize"
        }
        'SHA-DC01-15' {
            return "foreach(`$u in 'sec.admin1','helpdesk.b4','auditor.b4','user.sh01','user.bj01','blocked.admin'){`"`n=== `$u ===`"; Get-ADPrincipalGroupMembership -Identity `$u | Sort-Object Name | Format-Table Name,GroupScope,GroupCategory -AutoSize}"
        }
        'SHA-DC01-20' {
            return "auditpol.exe /get /category:*`ngpresult.exe /r`nGet-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System\Audit' -Name ProcessCreationIncludeCmdLine_Enabled -ErrorAction SilentlyContinue"
        }
        'SHA-DC01-24' {
            return @'
Get-ADComputer -Filter "Name -in ('SHA-WEB01','SHA-APP01')" -Properties Enabled,DistinguishedName | Format-Table Name,Enabled,DistinguishedName -AutoSize
foreach($h in 'SHA-WEB01','SHA-APP01'){Invoke-Command -ComputerName $h -ScriptBlock { Get-CimInstance Win32_ComputerSystem | Select-Object Name,Domain,PartOfDomain }}
'@
        }
        {$_ -in @('SHA-DC01-22','BJ-DC02-08')} {
            return @'
Get-NetFirewallProfile | Format-Table Name,Enabled -AutoSize
Get-Service WinRM | Format-List Name,Status,StartType
winrm.exe enumerate winrm/config/listener
Get-NetFirewallRule -Enabled True -Direction Inbound | Where-Object {$_.DisplayGroup -match 'Windows Remote Management'} | ForEach-Object {$r=$_; $a=$_ | Get-NetFirewallAddressFilter; [pscustomobject]@{Rule=$r.DisplayName;RemoteAddress=($a.RemoteAddress -join ',')}}
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\EventLog\EventForwarding\SubscriptionManager' -ErrorAction SilentlyContinue
'@
        }
        'BJ-DC02-11' {
            return "Invoke-Command BJ-SRV01 { Get-WinEvent -LogName ForwardedEvents -MaxEvents 500 | Where-Object MachineName -match 'BJ-DC02' | Select-Object -First 20 Id,MachineName,TimeCreated }"
        }
        {$_ -in @('SHA-FS01-01','BJ-SRV01-01')} {
            return @'
hostname.exe
Get-NetIPAddress -AddressFamily IPv4 | Format-Table InterfaceAlias,IPAddress,PrefixLength -AutoSize
Get-NetRoute -AddressFamily IPv4 -DestinationPrefix 0.0.0.0/0 | Format-Table NextHop,InterfaceAlias,RouteMetric -AutoSize
Get-CimInstance Win32_ComputerSystem | Format-List Name,Domain,PartOfDomain
$root=[ADSI]'LDAP://RootDSE'; $s=New-Object DirectoryServices.DirectorySearcher([ADSI]("LDAP://"+$root.defaultNamingContext)); $s.Filter="(&(objectCategory=computer)(sAMAccountName=$env:COMPUTERNAME`$))"; $s.FindOne().Properties.distinguishedname
'@
        }
        {$_ -in @('SHA-FS01-05','BJ-SRV01-14')} {
            return @'
Get-NetFirewallRule -Enabled True -Direction Inbound | ForEach-Object {$r=$_; $p=$_|Get-NetFirewallPortFilter; $a=$_|Get-NetFirewallAddressFilter; if(($p.LocalPort -join ',') -match '135|445|5985|3389'){[pscustomobject]@{Rule=$r.DisplayName;Protocol=($p.Protocol -join ',');LocalPort=($p.LocalPort -join ',');RemoteAddress=($a.RemoteAddress -join ',')}}} | Format-Table -Wrap
'@
        }
        {$_ -in @('SHA-FS01-08','SHA-CL01-13','BJ-CL01-06')} {
            return @'
Get-Service WinRM | Format-List Name,Status,StartType
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\EventLog\EventForwarding\SubscriptionManager' -ErrorAction SilentlyContinue
gpresult.exe /r
Invoke-Command BJ-SRV01 { Get-WinEvent -LogName ForwardedEvents -MaxEvents 500 | Group-Object MachineName | Select-Object Name,Count }
'@
        }
        'BJ-SRV01-05' {
            return @'
Get-NetFirewallRule -Enabled True -Direction Inbound | ForEach-Object {$r=$_; $p=$_|Get-NetFirewallPortFilter; if($p.Protocol -eq 'TCP' -and ($p.LocalPort -contains 5985 -or "$($p.LocalPort)" -match '5985')){$a=$_|Get-NetFirewallAddressFilter; [pscustomobject]@{Rule=$r.DisplayName;LocalPort=($p.LocalPort -join ',');RemoteAddress=($a.RemoteAddress -join ',')}}} | Format-Table -Wrap
'@
        }
        'BJ-SRV01-06' {
            return "wecutil.exe qc /q`nGet-Service Wecsvc | Format-List Name,Status,StartType"
        }
        'BJ-SRV01-08' {
            return "wecutil.exe gr B4-Security-Events`nwecutil.exe gs B4-Security-Events /f:xml"
        }
        'BJ-SRV01-11' {
            return "Get-WinEvent -LogName ForwardedEvents -MaxEvents 1000 | Group-Object MachineName | Sort-Object Name | Format-Table Name,Count -AutoSize`nGet-LocalGroupMember 'Event Log Readers'"
        }
        'BJ-SRV01-15' {
            return "Get-LocalGroupMember Administrators | Format-Table Name,ObjectClass,PrincipalSource -AutoSize`nGet-LocalGroupMember 'Remote Management Users' | Format-Table Name,ObjectClass,PrincipalSource -AutoSize"
        }
        'BJ-SRV01-16' {
            return "Get-LocalGroupMember 'Event Log Readers' | Format-Table Name,ObjectClass,PrincipalSource -AutoSize`nGet-LocalGroupMember Administrators | Format-Table Name,ObjectClass,PrincipalSource -AutoSize"
        }
        {$_ -in @('SHA-CL01-02','BJ-CL01-02')} {
            return "hostname.exe`nsysteminfo.exe | findstr.exe /B /C:`"Domain`"`nwhoami.exe /fqdn"
        }
        'SHA-CL01-03' {
            return "Get-WindowsCapability -Online -Name 'Rsat*' | Sort-Object Name | Format-Table Name,State -AutoSize"
        }
        {$_ -in @('SHA-CL01-09','SHA-CL01-10')} {
            return "foreach(`$h in 'SHA-DC01','BJ-DC02','SHA-FS01','BJ-SRV01','SHA-CL01','BJ-CL01'){Invoke-Command `$h {Get-LocalGroupMember Administrators | Select-Object @{n='Computer';e={`$env:COMPUTERNAME}},Name,ObjectClass,PrincipalSource}} | Format-Table -AutoSize"
        }
        'SHA-CL01-15' {
            return "Get-ChildItem C:\Skills\B4 -File | Select-Object Name,Length,LastWriteTime | Format-Table -AutoSize"
        }
        default {
            $command=[string]$Aspect.VerificationCommands
            $command=$command -replace '^(?i)Run locally(?:/RSAT)?(?:\s+after validation actions)?:\s*',''
            return $command.Trim()
        }
    }
}

function Invoke-B4Evidence {
    param([string]$Command,[scriptblock]$ScriptBlock)
    Write-B4Log "Команда автоматической проверки: $Command" Cyan
    $items=New-Object System.Collections.Generic.List[object]
    $ok=$true
    try { & $ScriptBlock | ForEach-Object { [void]$items.Add($_) } }
    catch { $ok=$false; [void]$items.Add("[ERROR] $($_.Exception.Message)") }
    $text=ConvertTo-B4Text $items.ToArray()
    if ([string]::IsNullOrWhiteSpace($text)) { $text='(пустой вывод)' }
    Write-B4Log 'Фактический вывод (полный):' Blue
    Write-B4Log $text Gray
    return [pscustomobject]@{Ok=$ok;Text=$text;Value=$items.ToArray()}
}

function New-B4Check {
    param([string]$Label,[string]$Expected,[scriptblock]$Test)
    [pscustomobject]@{Label=$Label;Expected=$Expected;Test=$Test}
}

function Invoke-B4Checks {
    param([string]$Command,[scriptblock]$Collect,[object[]]$Checks)
    $e=Invoke-B4Evidence $Command $Collect
    $passed=0
    Write-B4Log 'Результаты по отдельным свойствам:' Blue
    foreach($check in $Checks) {
        $good=$false; $errorText=''
        try { $good=[bool](& $check.Test $e.Text $e.Value) } catch { $errorText=$_.Exception.Message }
        if($good) {
            $passed++
            Write-B4Log "[PASS] $($check.Label); ожидается: $($check.Expected)" Green
        } else {
            $suffix=if($errorText){"; ошибка анализа: $errorText"}else{''}
            Write-B4Log "[FAIL] $($check.Label); ожидается: $($check.Expected)$suffix" Red
        }
    }
    $total=$Checks.Count
    $status=if($passed -eq $total){'PASS'}elseif($passed -gt 0){'PART'}else{'FAIL'}
    return [pscustomobject]@{Status=$status;Passed=$passed;Total=$total;Message="$passed/$total свойств подтверждено"}
}

function Invoke-B4RegexChecks {
    param([string]$Command,[scriptblock]$Collect,[System.Collections.IDictionary]$Required,[string[]]$Forbidden=@())
    $checks=New-Object System.Collections.Generic.List[object]
    foreach($label in $Required.Keys) {
        $pattern=[string]$Required[$label]
        $checks.Add((New-B4Check $label $pattern {param($t,$v) $t -match $pattern}.GetNewClosure()))
    }
    foreach($pattern in $Forbidden) {
        $p=$pattern
        $checks.Add((New-B4Check "Отсутствует запрещённое: $p" "нет совпадения $p" {param($t,$v) $t -notmatch $p}.GetNewClosure()))
    }
    return Invoke-B4Checks $Command $Collect $checks.ToArray()
}

function Complete-B4Aspect {
    param([object]$Aspect,[object]$Result)
    $max=[double]$Aspect.MaxMark
    $award=if($Result.Total -gt 0){[Math]::Round($max*$Result.Passed/$Result.Total,3)}else{0}
    $row=[pscustomobject]@{AspectID=$Aspect.AspectID;HostKey=$Aspect.HostKey;MaxMark=$max;Awarded=$award;Status=$Result.Status;Message=$Result.Message}
    $script:B4Rows+=,$row
    if($script:B4Report) {
        $safe=$Result.Message -replace "`t",' ' -replace "`r?`n",' '
        Add-Content $script:B4ResultsPath "$($Aspect.AspectID)`t$($Aspect.HostKey)`t$max`t$award`t$($Result.Status)`t$safe" -Encoding UTF8
    }
    $color=if($Result.Status-eq'PASS'){'Green'}elseif($Result.Status-eq'PART'){'Magenta'}elseif($Result.Status-eq'WARN'){'Yellow'}else{'Red'}
    Write-B4Log "[$($Result.Status)] $($Aspect.AspectID) $award/$max ($($Result.Passed)/$($Result.Total)) — $($Result.Message)" $color
    if($script:B4Pause){[void](Read-Host 'Нажмите Enter, чтобы продолжить')}
}

function Test-B4Network {
    param([string]$HostName,[string[]]$IPs,[string]$Gateway,[string[]]$Dns=@())
    $checks=New-Object System.Collections.Generic.List[object]
    $checks.Add((New-B4Check 'Hostname' $HostName {param($t,$v) $env:COMPUTERNAME -ieq $HostName}.GetNewClosure()))
    foreach($ip in $IPs){$x=$ip;$checks.Add((New-B4Check "IPv4 $x" "$x/24" {param($t,$v) $t-match("IP="+[regex]::Escape($x)+";Prefix=24")}.GetNewClosure()))}
    if($Gateway){$x=$Gateway;$checks.Add((New-B4Check 'Default gateway' $x {param($t,$v)$t-match("Gateway="+[regex]::Escape($x))}.GetNewClosure()))}
    foreach($dns in $Dns){$x=$dns;$checks.Add((New-B4Check "DNS $x" $x {param($t,$v)$t-match("DNS=.*"+[regex]::Escape($x))}.GetNewClosure()))}
    return Invoke-B4Checks 'hostname; Get-NetIPAddress; Get-NetIPConfiguration; Get-DnsClientServerAddress' {
        "HOST=$env:COMPUTERNAME"
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {$_.IPAddress -notlike '169.254.*'} | ForEach-Object {"IP=$($_.IPAddress);Prefix=$($_.PrefixLength);Interface=$($_.InterfaceAlias)"}
        Get-NetIPConfiguration | ForEach-Object {if($_.IPv4DefaultGateway){"Gateway=$($_.IPv4DefaultGateway.NextHop);Interface=$($_.InterfaceAlias)"}}
        Get-DnsClientServerAddress -AddressFamily IPv4 | ForEach-Object {"DNS=$($_.ServerAddresses -join ',');Interface=$($_.InterfaceAlias)"}
    } $checks.ToArray()
}

function Test-B4Routes {
    param([string[]]$Prefixes,[string]$NextHop)
    $checks=foreach($prefix in $Prefixes){$p=$prefix;New-B4Check "Route $p" "$p via $NextHop" {param($t,$v)$t-match("ROUTE="+[regex]::Escape($p)+";NextHop="+[regex]::Escape($NextHop))}.GetNewClosure()}
    Invoke-B4Checks 'Get-NetRoute -AddressFamily IPv4' {
        Get-NetRoute -AddressFamily IPv4 | ForEach-Object {"ROUTE=$($_.DestinationPrefix);NextHop=$($_.NextHop);Interface=$($_.InterfaceAlias)"}
    } @($checks)
}

function Test-B4Forwarding {
    param([string[]]$IPs)
    $checks=New-Object System.Collections.Generic.List[object]
    foreach($ip in $IPs){
        $x=$ip
        $checks.Add((New-B4Check "IPv4 forwarding на интерфейсе $x" 'Forwarding=Enabled' {
            param($t,$v)
            $t-match("IP="+[regex]::Escape($x)+";[^\r\n]*Forwarding=Enabled")
        }.GetNewClosure()))
    }
    $checks.Add((New-B4Check 'Routing and Remote Access service' 'RemoteAccess=Running' {
        param($t,$v) $t-match'RemoteAccess=Running'
    }))
    Invoke-B4Checks 'Get-NetIPAddress; Get-NetIPInterface | Select InterfaceAlias,InterfaceIndex,Forwarding; Get-Service RemoteAccess' {
        $addresses=@(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)
        foreach($ip in $IPs){
            $address=$addresses|Where-Object IPAddress -eq $ip|Select-Object -First 1
            if($null-eq$address){"IP=$ip;Interface=<MISSING>;Forwarding=<UNKNOWN>";continue}
            $interface=Get-NetIPInterface -AddressFamily IPv4 -InterfaceIndex $address.InterfaceIndex -ErrorAction SilentlyContinue
            "IP=$ip;Interface=$($address.InterfaceAlias);Index=$($address.InterfaceIndex);Forwarding=$($interface.Forwarding)"
        }
        $service=Get-Service RemoteAccess -ErrorAction SilentlyContinue
        "RemoteAccess=$($service.Status)"
    } $checks.ToArray()
}

function Test-B4DhcpRelay {
    param([string]$ServerIP,[string]$ClientInterfaceIP)
    $checks=@(
        (New-B4Check 'DHCP relay target' $ServerIP {
            param($t,$v) $t-match'(?m)^RELAY_TARGET=FOUND\r?$'
        }),
        (New-B4Check 'DHCP relay client interface' "$ClientInterfaceIP interface is present in DHCP Relay Agent configuration" {
            param($t,$v) $t-match'(?m)^RELAY_INTERFACE=FOUND\r?$'
        })
    )
    Invoke-B4Checks 'Read-only: netsh routing ip relay show global/interface; Get-NetIPAddress/Get-NetAdapter; reg query RemoteAccess fallback' {
        $address=Get-NetIPAddress -AddressFamily IPv4 -IPAddress $ClientInterfaceIP -ErrorAction SilentlyContinue|Select-Object -First 1
        $alias=if($address){[string]$address.InterfaceAlias}else{''}
        $globalEvidence=@(& netsh.exe routing ip relay show global 2>&1 | ForEach-Object {[string]$_})
        $allInterfaceEvidence=@(& netsh.exe routing ip relay show interface 2>&1 | ForEach-Object {[string]$_})
        $namedInterfaceEvidence=@()
        if($alias){
            $namedInterfaceEvidence=@(& netsh.exe routing ip relay show interface "name=$alias" 2>&1 | ForEach-Object {[string]$_})
        }
        '--- NETSH: routing ip relay show global ---'
        $globalEvidence
        '--- NETSH: routing ip relay show interface ---'
        $allInterfaceEvidence
        if($alias){
            "--- NETSH: routing ip relay show interface name=$alias ---"
            $namedInterfaceEvidence
        }

        if($null-eq$address){
            "CLIENT_INTERFACE_IP=$ClientInterfaceIP;STATUS=MISSING"
            "RELAY_INTERFACE=NOT_FOUND"
        } else {
            $adapter=Get-NetAdapter -InterfaceIndex $address.InterfaceIndex -ErrorAction SilentlyContinue
            $guid=if($adapter){([string]$adapter.InterfaceGuid).Trim('{}')}else{''}
            "CLIENT_INTERFACE_IP=$ClientInterfaceIP;ALIAS=$($address.InterfaceAlias);INDEX=$($address.InterfaceIndex);GUID=$guid"
            if($guid){
                $interfaceEvidence=& reg.exe query 'HKLM\SYSTEM\CurrentControlSet\Services\RemoteAccess' /s /f $guid 2>&1
                $interfaceEvidence
                $netshInterfaces=(($allInterfaceEvidence+$namedInterfaceEvidence)-join"`n")
                $netshHasInterface=(
                    $netshInterfaces-match[regex]::Escape($alias) -or
                    $netshInterfaces-match[regex]::Escape($ClientInterfaceIP) -or
                    $netshInterfaces-match[regex]::Escape($guid)
                )
                if($netshHasInterface -or ($interfaceEvidence-join"`n")-match[regex]::Escape($guid)){
                    "RELAY_INTERFACE=FOUND"
                } else {
                    "RELAY_INTERFACE=NOT_FOUND"
                }
            } else {
                "RELAY_INTERFACE=NOT_FOUND;REASON=adapter-guid-unavailable"
            }
        }
        $targetEvidence=& reg.exe query 'HKLM\SYSTEM\CurrentControlSet\Services\RemoteAccess' /s /f $ServerIP /d 2>&1
        $targetEvidence
        if(
            ($globalEvidence-join"`n")-match[regex]::Escape($ServerIP) -or
            ($targetEvidence-join"`n")-match[regex]::Escape($ServerIP)
        ){
            "RELAY_TARGET=FOUND"
        } else {
            "RELAY_TARGET=NOT_FOUND"
        }
        $service=Get-Service RemoteAccess -ErrorAction SilentlyContinue
        if($service){
            "REMOTEACCESS_STATUS=$($service.Status)"
            if($service.Status-ne'Running'){"RELAY_INFO=RRAS service is not running"}
        } else {
            'REMOTEACCESS_STATUS=NOT_FOUND'
        }
    } $checks
}

function Test-B4ReplicationHealth {
    $checks=@(
        (New-B4Check 'AD replication' 'repadmin содержит строки DC, fails=0 и не содержит blocking replication errors' {
            param($t,$v)
            $hasSummaryRows=$t-match'(?m)^\s*(SHA-DC01|BJ-DC02)\s+\S+\s+\d+\s*/\s*\d+'
            $hasFailures=$t-match'(?m)^\s*(SHA-DC01|BJ-DC02)\s+\S+\s+[1-9]\d*\s*/\s*\d+'
            $hasSummaryRows-and-not$hasFailures
        }),
        (New-B4Check 'Domain time difference' 'оба DC показаны; абсолютный NTP offset каждого не более 300 секунд' {
            param($t,$v)
            if($t-notmatch'SHA-DC01' -or $t-notmatch'BJ-DC02'){return $false}
            $offsets=[regex]::Matches($t,'NTP:\s*([+-]?\d+(?:\.\d+)?)s\s+offset')
            if($offsets.Count-lt2){return $false}
            foreach($offset in $offsets){
                if([Math]::Abs([double]$offset.Groups[1].Value)-gt300){return $false}
            }
            return $true
        })
    )
    Invoke-B4Checks 'repadmin /replsummary; w32tm /monitor' {
        repadmin /replsummary
        w32tm /monitor
    } $checks
}

function Test-B4TcpSet {
    param([string[]]$Targets,[int[]]$Ports,[bool]$Expected)
    $checks=New-Object System.Collections.Generic.List[object]
    foreach($target in $Targets){foreach($port in $Ports){$t=$target;$p=$port;$checks.Add((New-B4Check "$t TCP/$p" "TcpTestSucceeded=$Expected" {param($text,$v)$text-match("TARGET="+[regex]::Escape($t)+";PORT=$p;OK=$Expected")}.GetNewClosure()))}}
    Invoke-B4Checks 'Test-NetConnection по каждому target/port' {
        foreach($target in $Targets){foreach($port in $Ports){$ok=Test-NetConnection $target -Port $port -InformationLevel Quiet -WarningAction SilentlyContinue;"TARGET=$target;PORT=$port;OK=$ok"}}
    } $checks.ToArray()
}

function Test-B4PingSet {
    param([string[]]$Targets)
    $checks=foreach($target in $Targets){$x=$target;New-B4Check "ICMP $x" 'at least one reply from four attempts' {param($t,$v)$t-match("TARGET="+[regex]::Escape($x)+";SENT=4;RECEIVED=[1-4];[^\r\n]*PING=True")}.GetNewClosure()}
    Invoke-B4Checks 'Test-Connection -Count 4 for each target; success requires at least one reply' {
        foreach($target in $Targets) {
            $replies=@(Test-Connection -ComputerName $target -Count 4 -Delay 1 -ErrorAction SilentlyContinue)
            $received=$replies.Count
            $loss=[Math]::Round((4-$received)*100/4)
            $success=$received -gt 0
            $latencies=@($replies | ForEach-Object {
                if($_.PSObject.Properties['ResponseTime']){$_.ResponseTime}
                elseif($_.PSObject.Properties['Latency']){$_.Latency}
            })
            $average=if($latencies.Count -gt 0){[Math]::Round(($latencies | Measure-Object -Average).Average,1)}else{'NA'}
            "TARGET=$target;SENT=4;RECEIVED=$received;LOSS_PERCENT=$loss;AVERAGE_MS=$average;PING=$success"
        }
    } @($checks)
}

function Test-B4Defender {
    param([switch]$Baseline)
    $required=[ordered]@{
        'Defender present/enabled'='STATUS;[^\r\n]*(?:AntivirusEnabled=True|AMServiceEnabled=True)'
        'Real-time protection enabled'='(?:RealTimeProtectionEnabled=True|DisableRealtimeMonitoring=False)'
    }
    $forbidden=@()
    if($Baseline) {
        $required['Daily quick scan at 12:30']='QuickScanTime=12:30(?::00)?'
        $forbidden=@(
            'EXCLUSION_PATH=C:\\Users(?:\\|\r?$)'
            'EXCLUSION_PATH=C:\\Windows(?:\\|\r?$)'
            'EXCLUSION_PATH=C:\\Program Files(?:\\|\r?$)'
            'EXCLUSION_PATH=C:\\(?:\r?$)'
        )
    }
    Invoke-B4RegexChecks 'Get-MpComputerStatus; selected Get-MpPreference properties and exclusions' {
        $status=$null
        try {
            $status=Get-MpComputerStatus -ErrorAction Stop
            'STATUS_SOURCE=Get-MpComputerStatus'
        } catch {
            "STATUS_PRIMARY_ERROR=$($_.Exception.Message)"
            try {
                $status=Get-CimInstance -Namespace 'root/Microsoft/Windows/Defender' -ClassName MSFT_MpComputerStatus -ErrorAction Stop
                'STATUS_SOURCE=CIM_MSFT_MpComputerStatus'
            } catch {
                "STATUS_FALLBACK_ERROR=$($_.Exception.Message)"
            }
        }
        if($null -ne $status) {
            "STATUS;AntivirusEnabled=$($status.AntivirusEnabled);AMServiceEnabled=$($status.AMServiceEnabled);RealTimeProtectionEnabled=$($status.RealTimeProtectionEnabled)"
        } else {
            'STATUS;AntivirusEnabled=<UNKNOWN>;AMServiceEnabled=<UNKNOWN>;RealTimeProtectionEnabled=<UNKNOWN>'
        }

        $preference=$null
        try {
            $preference=Get-MpPreference -ErrorAction Stop
            'PREFERENCE_SOURCE=Get-MpPreference'
        } catch {
            "PREFERENCE_PRIMARY_ERROR=$($_.Exception.Message)"
            try {
                $preference=Get-CimInstance -Namespace 'root/Microsoft/Windows/Defender' -ClassName MSFT_MpPreference -ErrorAction Stop
                'PREFERENCE_SOURCE=CIM_MSFT_MpPreference'
            } catch {
                "PREFERENCE_FALLBACK_ERROR=$($_.Exception.Message)"
            }
        }
        if($null -ne $preference) {
            "PREFERENCE;DisableRealtimeMonitoring=$($preference.DisableRealtimeMonitoring);QuickScanTime=$($preference.ScanScheduleQuickScanTime)"
            $paths=@($preference.ExclusionPath)
            if($paths.Count -eq 0) {
                'EXCLUSION_PATH=<NONE>'
            } else {
                foreach($path in $paths){"EXCLUSION_PATH=$path"}
            }
        } else {
            'PREFERENCE;DisableRealtimeMonitoring=<UNKNOWN>;QuickScanTime=<UNKNOWN>'
            'EXCLUSION_PATH=<UNKNOWN>'
        }
    } $required $forbidden
}

function Test-B4Audit {
    param([int64]$MinBytes=0,[switch]$AuditPolicyOnly)
    $checks=New-Object System.Collections.Generic.List[object]
    $required=[ordered]@{
        'Credential Validation'       = 'Success and Failure'
        'Logon'                       = 'Success and Failure'
        'User Account Management'     = 'Success'
        'Security Group Management'   = 'Success'
        'Audit Policy Change'         = 'Success'
        'Process Creation'            = 'Success'
        'File Share'                  = 'Success and Failure'
    }
    foreach($name in $required.Keys){
        $x=$name; $setting=$required[$name]
        $checks.Add((New-B4Check "Audit: $x" $setting {
            param($t,$v)
            $t -match ("(?m)^AUDIT="+[regex]::Escape($x)+";SETTING="+[regex]::Escape($setting)+"\r?$")
        }.GetNewClosure()))
    }
    $checks.Add((New-B4Check 'Force audit subcategory override' 'SCENoApplyLegacyAuditPolicy=1' {
        param($t,$v) $t -match '(?m)^SCENoApplyLegacyAuditPolicy=1\r?$'
    }))
    $checks.Add((New-B4Check 'Include command line in process creation events' 'ProcessCreationIncludeCmdLine_Enabled=1' {
        param($t,$v) $t -match '(?m)^ProcessCreationIncludeCmdLine_Enabled=1\r?$'
    }))
    if(-not $AuditPolicyOnly){
        $limit=$MinBytes
        $checks.Add((New-B4Check 'Security log size' "не менее $limit bytes" {
            param($t,$v)
            $m=[regex]::Match($t,'SECURITY_LOG_MAX_SIZE=(\d+)')
            $m.Success-and[int64]$m.Groups[1].Value-ge$limit
        }.GetNewClosure()))
        $checks.Add((New-B4Check 'Security log retention' 'Overwrite events as needed (retention=false)' {
            param($t,$v) $t-match'SECURITY_LOG_RETENTION=false'
        }))
    }
    Invoke-B4Checks 'auditpol /get /subcategory:<name>; registry audit-policy settings; wevtutil gl Security when required' {
        foreach($name in $required.Keys){
            $raw=@(& auditpol.exe /get "/subcategory:$name" 2>&1)
            $line=@($raw | Where-Object {$_ -match ('^\s*'+[regex]::Escape($name)+'\s{2,}(.+?)\s*$')} | Select-Object -First 1)
            if($line.Count){
                $m=[regex]::Match([string]$line[0],('^\s*'+[regex]::Escape($name)+'\s{2,}(.+?)\s*$'))
                "AUDIT=$name;SETTING=$($m.Groups[1].Value.Trim())"
            } else {
                "AUDIT=$name;SETTING=<NOT_FOUND>;RAW=$($raw -join ' ')"
            }
        }
        $lsa=Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -ErrorAction SilentlyContinue
        $override=if($null -ne $lsa -and $null -ne $lsa.PSObject.Properties['SCENoApplyLegacyAuditPolicy']){
            $lsa.SCENoApplyLegacyAuditPolicy
        } else {
            '<NOT_SET>'
        }
        "SCENoApplyLegacyAuditPolicy=$override"
        $auditKey=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit' -ErrorAction SilentlyContinue
        $cmdLine=if($null -ne $auditKey -and $null -ne $auditKey.PSObject.Properties['ProcessCreationIncludeCmdLine_Enabled']){
            $auditKey.ProcessCreationIncludeCmdLine_Enabled
        } else {
            '<NOT_SET>'
        }
        "ProcessCreationIncludeCmdLine_Enabled=$cmdLine"
        if(-not $AuditPolicyOnly){
            $security=@(& wevtutil.exe gl Security 2>&1)
            $max=[regex]::Match(($security -join "`n"),'(?im)^\s*maxSize:\s*(\d+)').Groups[1].Value
            $retention=[regex]::Match(($security -join "`n"),'(?im)^\s*retention:\s*(\S+)').Groups[1].Value
            "SECURITY_LOG_MAX_SIZE=$max"
            "SECURITY_LOG_RETENTION=$retention"
        }
    } $checks.ToArray()
}

function Test-B4LocalAdmins {
    param([string]$AllowedGroup)
    $required=[ordered]@{'Domain Admins присутствует'='Domain Admins';"$AllowedGroup присутствует"=[regex]::Escape($AllowedGroup)}
    $forbidden='helpdesk\.b4','user\.sh01','user\.bj01','blocked\.admin','GG_B4_Standard_Users','GG_B4_No_Admin_Test'
    Invoke-B4RegexChecks "Get-LocalGroupMember Administrators; gpresult /r" {Get-LocalGroupMember Administrators;gpresult /r} $required $forbidden
}

function Test-B4UserGroupMemberships {
    $expected=[ordered]@{
        'sec.admin1'   = @('Domain Admins','GG_B4_Server_Admins')
        'helpdesk.b4'  = @('GG_B4_Workstation_Admins')
        'auditor.b4'   = @('GG_B4_Auditors')
        'user.sh01'    = @('GG_B4_Standard_Users')
        'user.bj01'    = @('GG_B4_Standard_Users')
        'blocked.admin'= @('GG_B4_No_Admin_Test')
    }
    $checks=New-Object System.Collections.Generic.List[object]
    foreach($user in $expected.Keys) {
        foreach($group in $expected[$user]) {
            $u=$user; $g=$group
            $checks.Add((New-B4Check "$u -> $g" "учётная запись существует и входит в $g" {
                param($text,$values)
                $text -match ("USER="+[regex]::Escape($u)+";STATUS=FOUND;GROUPS=[^\r\n]*"+[regex]::Escape($g))
            }.GetNewClosure()))
        }
    }
    # У blocked.admin допустима встроенная Domain Users, но не другие GG_B4_* группы.
    $checks.Add((New-B4Check 'blocked.admin не получает другие GG_B4_* группы' 'из GG_B4_* только GG_B4_No_Admin_Test' {
        param($text,$values)
        $m=[regex]::Match($text,'USER=blocked\.admin;STATUS=FOUND;GROUPS=([^\r\n]*)')
        if(-not $m.Success){return $false}
        $b4=@($m.Groups[1].Value -split ',' | Where-Object {$_ -like 'GG_B4_*'})
        return ($b4.Count -eq 1 -and $b4[0] -eq 'GG_B4_No_Admin_Test')
    }))
    Invoke-B4Checks 'For each required user: Get-ADUser; Get-ADPrincipalGroupMembership (errors isolated per user)' {
        foreach($user in $expected.Keys) {
            try {
                $account=Get-ADUser -Identity $user -ErrorAction Stop
                $groups=@(Get-ADPrincipalGroupMembership -Identity $account -ErrorAction Stop |
                    Select-Object -ExpandProperty Name | Sort-Object)
                "USER=$user;STATUS=FOUND;GROUPS=$($groups -join ',')"
            } catch {
                "USER=$user;STATUS=NOT_FOUND;ERROR=$($_.Exception.Message)"
            }
        }
    } $checks.ToArray()
}

function Test-B4Submission {
    param([string[]]$Files,[string[]]$Terms=@())
    $checks=New-Object System.Collections.Generic.List[object]
    foreach($file in $Files){$f=$file;$checks.Add((New-B4Check "Файл $f" 'существует и не пустой' {param($t,$v)$t-match("FILE_OK="+[regex]::Escape($f))}.GetNewClosure()))}
    foreach($term in $Terms){$x=$term;$checks.Add((New-B4Check "Содержимое: $x" $x {param($t,$v)$t-match("TERM_OK="+[regex]::Escape($x))}.GetNewClosure()))}
    Invoke-B4Checks 'Проверить C:\Skills\B4 и содержимое submission' {
        foreach($file in $Files){$p=Join-Path 'C:\Skills\B4' $file;if((Test-Path $p)-and(Get-Item $p).Length-gt0){"FILE_OK=$file"}else{"FILE_FAIL=$file"}}
        $all=foreach($file in $Files){$p=Join-Path 'C:\Skills\B4' $file;if(Test-Path $p){Get-Content $p -Raw -ErrorAction SilentlyContinue}}
        $joined=$all-join"`n";foreach($term in $Terms){if($joined-match[regex]::Escape($term)){"TERM_OK=$term"}else{"TERM_FAIL=$term"}}
    } $checks.ToArray()
}

function Test-B4Firewall {
    param([switch]$WinRM,[switch]$WefCollector)
    $required=[ordered]@{
        'Domain firewall enabled'='PROFILE=Domain;Enabled=True'
        'Private firewall enabled'='PROFILE=Private;Enabled=True'
        'Public firewall enabled'='PROFILE=Public;Enabled=True'
    }
    if($WinRM){$required['WinRM listener/service']='WINRM=(Running|Listener)'}
    if($WefCollector){$required['WEF collector internal scope']='10\.24\.20\.10|10\.34\.20\.10|10\.24\.30\.0/24|10\.34\.30\.0/24'}
    Invoke-B4RegexChecks 'Get-NetFirewallProfile; WinRM; active firewall address filters' {
        Get-NetFirewallProfile | ForEach-Object {"PROFILE=$($_.Name);Enabled=$($_.Enabled)"}
        $svc=Get-Service WinRM -ErrorAction SilentlyContinue;if($svc){"WINRM=$($svc.Status)"}
        Get-NetFirewallRule -Enabled True -Direction Inbound -ErrorAction SilentlyContinue | ForEach-Object {
            $rule=$_;$addr=$rule|Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue
            if($rule.DisplayGroup-match'Windows Remote Management|Remote Service Management|Remote Desktop|File and Printer Sharing' -or $rule.DisplayName-match'WEF|WinRM'){
                "RULE=$($rule.DisplayName);RemoteAddress=$($addr.RemoteAddress -join ',')"
            }
        }
    } $required @('198\.18\.201\.0/24','198\.18\.201\.10','RemoteAddress=Any')
}

function Test-B4DcFirewallWefSource {
    param([string]$ComputerName)
    $checks=New-Object System.Collections.Generic.List[object]
    foreach($profile in @('Domain','Private','Public')) {
        $p=$profile
        $checks.Add((New-B4Check "$p firewall enabled" "PROFILE=$p;Enabled=True" {
            param($t,$v) $t -match "(?m)^PROFILE=$p;Enabled=True\r?$"
        }.GetNewClosure()))
    }
    $checks.Add((New-B4Check 'WinRM service' 'WINRM=Running' {
        param($t,$v) $t -match '(?m)^WINRM=Running\r?$'
    }))
    $checks.Add((New-B4Check 'WinRM internal management scope' 'active inbound WinRM rule allows SHA-CL01 network 10.24.30.0/24' {
        param($t,$v) $t -match '(?m)^WINRM_RULE=[^\r\n]+;REMOTE=[^\r\n]*10\.24\.30\.0/24'
    }))
    $checks.Add((New-B4Check 'WinRM is not broadly exposed' 'no active inbound WinRM rule with RemoteAddress=Any' {
        param($t,$v) $t -notmatch '(?m)^WINRM_RULE=[^\r\n]+;REMOTE=(?:[^,\r\n]*,)*Any(?:,|\r?$)'
    }))
    $checks.Add((New-B4Check 'WEF Subscription Manager policy' 'source points to BJ-SRV01.nb-b4.local:5985/wsman/SubscriptionManager/WEC' {
        param($t,$v) $t -match 'BJ-SRV01\.nb-b4\.local:5985/wsman/SubscriptionManager/WEC'
    }))
    Invoke-B4Checks 'Get-NetFirewallProfile; Get-Service WinRM; active inbound WinRM rules; SubscriptionManager policy' {
        "COMPUTER=$env:COMPUTERNAME;EXPECTED=$ComputerName"
        Get-NetFirewallProfile | ForEach-Object {"PROFILE=$($_.Name);Enabled=$($_.Enabled)"}
        $svc=Get-Service WinRM -ErrorAction SilentlyContinue
        if($svc){"WINRM=$($svc.Status)"}else{'WINRM=NOT_FOUND'}
        Get-NetFirewallRule -Enabled True -Direction Inbound -ErrorAction SilentlyContinue |
            Where-Object {$_.DisplayGroup -match 'Windows Remote Management' -or $_.DisplayName -match 'WinRM|Windows Remote Management'} |
            ForEach-Object {
                $rule=$_
                $addresses=@($rule | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue |
                    ForEach-Object {$_.RemoteAddress}) -join ','
                "WINRM_RULE=$($rule.DisplayName);REMOTE=$addresses"
            }
        $subscriptionPath='HKLM:\SOFTWARE\Policies\Microsoft\Windows\EventLog\EventForwarding\SubscriptionManager'
        $subscription=Get-ItemProperty -LiteralPath $subscriptionPath -ErrorAction SilentlyContinue
        if($subscription) {
            $subscription.PSObject.Properties |
                Where-Object {$_.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$'} |
                ForEach-Object {"SUBSCRIPTION_MANAGER=$($_.Value)"}
        } else {
            'SUBSCRIPTION_MANAGER=NOT_CONFIGURED'
        }
    } $checks.ToArray()
}

function Test-B4WefCollectorFirewall {
    $allowed=@(
        '10.24.20.10',
        '10.34.20.10',
        '10.24.20.20',
        '10.24.30.0/24',
        '10.34.30.0/24',
        '10.34.20.20'
    )
    $checks=New-Object System.Collections.Generic.List[object]
    foreach($source in $allowed) {
        $s=$source
        $label=if($s -eq '10.34.20.20'){'Local collector host 10.34.20.20'}else{"WEF source $s"}
        $checks.Add((New-B4Check $label "TCP/5985 REMOTE contains $s" {
            param($t,$v)
            $t -match "(?im)^TCP5985_RULE=[^\r\n]+;REMOTE=(?:[^,\r\n]+,)*"+[regex]::Escape($s)+"(?:,|\r?$)"
        }.GetNewClosure()))
    }
    $checks.Add((New-B4Check 'TCP/5985 is not open to Any' 'no active inbound TCP/5985 rule with REMOTE=Any' {
        param($t,$v) $t -notmatch '(?im)^TCP5985_RULE=[^\r\n]+;REMOTE=(?:[^,\r\n]+,)*Any(?:,|\r?$)'
    }))
    $checks.Add((New-B4Check 'Only the listed WEF source scopes are allowed' 'no external, LocalSubnet or other remote scopes on active inbound TCP/5985 rules' {
        param($t,$v)
        $remoteValues=New-Object System.Collections.Generic.List[string]
        foreach($line in @($t -split '\r?\n')) {
            if($line -match '^TCP5985_RULE=[^;]+;REMOTE=(.*)$') {
                foreach($item in @($Matches[1] -split ',')) {
                    $trimmed=$item.Trim()
                    if($trimmed){[void]$remoteValues.Add($trimmed)}
                }
            }
        }
        if($remoteValues.Count -eq 0){return $false}
        foreach($item in $remoteValues) {
            if($allowed -notcontains $item){return $false}
        }
        return $true
    }.GetNewClosure()))
    Invoke-B4Checks 'Active inbound firewall rules whose protocol is TCP and local port includes 5985; explicit RemoteAddress list' {
        $matched=0
        Get-NetFirewallRule -Enabled True -Direction Inbound -ErrorAction SilentlyContinue |
            ForEach-Object {
                $rule=$_
                $ports=@($rule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue)
                $is5985=$false
                foreach($port in $ports) {
                    if($port.Protocol -eq 'TCP' -and (@($port.LocalPort) -contains '5985' -or [string]$port.LocalPort -match '(^|,)5985(,|$)')) {
                        $is5985=$true
                    }
                }
                if($is5985) {
                    $addresses=@($rule | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue |
                        ForEach-Object {$_.RemoteAddress}) -join ','
                    "TCP5985_RULE=$($rule.DisplayName);REMOTE=$addresses"
                    $matched++
                }
            }
        if($matched -eq 0){'TCP5985_RULE=<NONE>;REMOTE=<NONE>'}
    } $checks.ToArray()
}

function Test-B4WefSubscriptionSources {
    $sources=@('SHA-DC01','BJ-DC02','SHA-FS01','SHA-CL01','BJ-CL01')
    $checks=New-Object System.Collections.Generic.List[object]
    foreach($source in $sources) {
        $s=$source
        $checks.Add((New-B4Check "$s accepted as WEF source" "resolved SDDL account or runtime source $s" {
            param($t,$v)
            $escaped=[regex]::Escape($s)
            $t -match "(?im)^(?:ALLOWED_SOURCE;SID=[^;]+;ACCOUNT=[^\r\n]*\\${escaped}\$|RUNTIME_SOURCE=${escaped}(?:;|\r?$))"
        }.GetNewClosure()))
    }
    Invoke-B4Checks 'wecutil gs/gr B4-Security-Events; decode AllowedSourceDomainComputers SDDL SIDs to NT accounts (compact output)' {
        $settings=@(& wecutil gs B4-Security-Events 2>&1 | ForEach-Object {[string]$_})
        "SUBSCRIPTION=B4-Security-Events"
        $joined=$settings -join "`n"
        $sids=@([regex]::Matches($joined,'S-1-\d+(?:-\d+)+') |
            ForEach-Object {$_.Value} | Sort-Object -Unique)
        if($sids.Count -eq 0) {
            'ALLOWED_SOURCE=<NO_SIDS_FOUND>'
        } else {
            foreach($sidText in $sids) {
                try {
                    $sid=New-Object System.Security.Principal.SecurityIdentifier($sidText)
                    $account=$sid.Translate([System.Security.Principal.NTAccount]).Value
                    "ALLOWED_SOURCE;SID=$sidText;ACCOUNT=$account"
                } catch {
                    "ALLOWED_SOURCE;SID=$sidText;ACCOUNT=<UNRESOLVED>;ERROR=$($_.Exception.Message)"
                }
            }
        }
        $runtime=@(& wecutil gr B4-Security-Events 2>&1 | ForEach-Object {[string]$_})
        foreach($source in $sources) {
            if(($runtime -join "`n") -match "(?i)(?:^|[\\.\s])"+[regex]::Escape($source)+"(?:\$|[\\.\s])") {
                "RUNTIME_SOURCE=$source"
            }
        }
    } $checks.ToArray()
}

function Test-B4ForwardedEventClasses {
    $checks=@(
        (New-B4Check 'Domain controller events' 'at least one event from SHA-DC01 or BJ-DC02' {
            param($t,$v) $t -match '(?im)^SOURCE=(?:SHA-DC01|BJ-DC02)(?:\.nb-b4\.local)?;COUNT=[1-9]\d*'
        }),
        (New-B4Check 'Remote member server events' 'at least one event from SHA-FS01; local BJ-SRV01 events alone are insufficient' {
            param($t,$v) $t -match '(?im)^SOURCE=SHA-FS01(?:\.nb-b4\.local)?;COUNT=[1-9]\d*'
        }),
        (New-B4Check 'Workstation events' 'at least one event from SHA-CL01 or BJ-CL01' {
            param($t,$v) $t -match '(?im)^SOURCE=(?:SHA-CL01|BJ-CL01)(?:\.nb-b4\.local)?;COUNT=[1-9]\d*'
        })
    )
    Invoke-B4Checks 'Get-WinEvent -LogName ForwardedEvents -MaxEvents 300; compact journal and source summary' {
        try {
            $log=Get-WinEvent -ListLog ForwardedEvents -ErrorAction Stop
            "LOG=ForwardedEvents;ENABLED=$($log.IsEnabled);RECORD_COUNT=$($log.RecordCount);MAX_SIZE=$($log.MaximumSizeInBytes)"
        } catch {
            "LOG=ForwardedEvents;STATUS=LOOKUP_ERROR;ERROR=$($_.Exception.Message)"
        }
        $eventBuffer=New-Object System.Collections.Generic.List[object]
        $readError=''
        try {
            Get-WinEvent -LogName ForwardedEvents -MaxEvents 300 -ErrorAction SilentlyContinue |
                ForEach-Object {[void]$eventBuffer.Add($_)}
        } catch {
            $readError=$_.Exception.Message
        }
        $events=$eventBuffer.ToArray()
        "EVENTS_READ=$($events.Count)"
        if($readError){"EVENT_READ_WARNING=$readError"}
        if($events.Count -gt 0) {
                $newest=($events | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated
                $oldest=($events | Sort-Object TimeCreated | Select-Object -First 1).TimeCreated
                "TIME_RANGE;OLDEST=$oldest;NEWEST=$newest"
                $events | Group-Object MachineName | Sort-Object Name | ForEach-Object {
                    $latest=($_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated
                    "SOURCE=$($_.Name);COUNT=$($_.Count);LATEST=$latest"
                }
        } else {
            if(-not $readError){'EVENT_READ_WARNING=no readable records returned'}
            'SOURCE=<NONE>;COUNT=0'
        }
    } $checks
}

function Test-B4ForwardedEventIds {
    $definitions=[ordered]@{
        '4624'='successful logon'
        '4625'='failed logon'
        '4688'='process creation'
        '4720'='user created'
        '4728'='member added to security-enabled global group'
        '4729'='member removed from security-enabled global group'
    }
    $checks=New-Object System.Collections.Generic.List[object]
    foreach($eventId in $definitions.Keys) {
        $id=[int]$eventId
        $description=[string]$definitions[$eventId]
        $checks.Add((New-B4Check "Event ID $id — $description" "EVENT_ID=$id;COUNT >= 1" {
            param($t,$v) $t -match "(?im)^EVENT_ID=$id;COUNT=[1-9]\d*;"
        }.GetNewClosure()))
    }
    Invoke-B4Checks 'Get-WinEvent ForwardedEvents filtered to IDs 4624,4625,4688,4720,4728,4729; compact count/source summary' {
        $ids=@(4624,4625,4688,4720,4728,4729)
        $events=@()
        try {
            $events=@(Get-WinEvent -FilterHashtable @{LogName='ForwardedEvents';Id=$ids} -MaxEvents 5000 -ErrorAction Stop)
            "QUERY_METHOD=FilterHashtable;MATCHED_EVENTS=$($events.Count)"
        } catch {
            "PRIMARY_QUERY_ERROR=$($_.Exception.Message)"
            try {
                $eventBuffer=New-Object System.Collections.Generic.List[object]
                Get-WinEvent -LogName ForwardedEvents -MaxEvents 5000 -ErrorAction SilentlyContinue |
                    Where-Object {$_.Id -in $ids} |
                    ForEach-Object {[void]$eventBuffer.Add($_)}
                $events=$eventBuffer.ToArray()
                "QUERY_METHOD=SequentialReadWithPowerShellFilter;MATCHED_EVENTS=$($events.Count)"
            } catch {
                if($eventBuffer.Count -gt 0) {
                    $events=$eventBuffer.ToArray()
                    "QUERY_METHOD=SequentialPartialRead;MATCHED_EVENTS=$($events.Count);WARNING=$($_.Exception.Message)"
                } else {
                    $events=@()
                    "QUERY_METHOD=FAILED;MATCHED_EVENTS=0;STATUS=NO_EVENTS_OR_QUERY_ERROR;ERROR=$($_.Exception.Message)"
                }
            }
        }
        foreach($id in $ids) {
            $matching=@($events | Where-Object Id -eq $id)
            if($matching.Count -eq 0) {
                "EVENT_ID=$id;COUNT=0;SOURCES=<NONE>;LATEST=<NONE>"
            } else {
                $sources=@($matching | Select-Object -ExpandProperty MachineName -Unique | Sort-Object)
                $latest=($matching | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated
                "EVENT_ID=$id;COUNT=$($matching.Count);SOURCES=$($sources -join ',');LATEST=$latest"
            }
        }
    } $checks.ToArray()
}

function Test-B4WefSource {
    param([string]$Computer)
    $required=[ordered]@{
        'WinRM running'='WINRM=Running'
        'Subscription Manager points to BJ-SRV01'='BJ-SRV01\.nb-b4\.local:5985/wsman/SubscriptionManager/WEC'
    }
    Invoke-B4RegexChecks 'Get-Service WinRM; SubscriptionManager policy; recent local Security events' {
        "COMPUTER=$env:COMPUTERNAME"
        $s=Get-Service WinRM -ErrorAction SilentlyContinue;"WINRM=$($s.Status)"
        Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\EventLog\EventForwarding\SubscriptionManager' -ErrorAction SilentlyContinue
        Get-WinEvent -FilterHashtable @{LogName='Security';StartTime=(Get-Date).AddHours(-2)} -MaxEvents 5 -ErrorAction SilentlyContinue | Select-Object Id,TimeCreated,MachineName
    } $required
}

function Test-B4DhcpScope {
    param([string]$ScopeId,[string]$Name,[string]$Start,[string]$End,[string]$ExStart,[string]$ExEnd,[string]$Gateway,[string[]]$Dns)
    $required=[ordered]@{
        'Scope ID'=[regex]::Escape($ScopeId)
        'Scope name'=[regex]::Escape($Name)
        'Range start'=[regex]::Escape($Start)
        'Range end'=[regex]::Escape($End)
        'Exclusion start'=[regex]::Escape($ExStart)
        'Exclusion end'=[regex]::Escape($ExEnd)
        'Gateway'=[regex]::Escape($Gateway)
        'DNS suffix'='nb-b4\.local'
    }
    foreach($d in $Dns){$required["DNS $d"]=[regex]::Escape($d)}
    Invoke-B4RegexChecks 'Get-DhcpServerv4Scope/OptionValue/ExclusionRange' {
        Get-DhcpServerv4Scope -ScopeId $ScopeId | ForEach-Object {
            "SCOPEID=$($_.ScopeId);NAME=$($_.Name);STATE=$($_.State);START=$($_.StartRange);END=$($_.EndRange);MASK=$($_.SubnetMask);LEASE=$($_.LeaseDuration)"
        }
        Get-DhcpServerv4OptionValue -ScopeId $ScopeId | ForEach-Object {
            "OPTIONID=$($_.OptionId);NAME=$($_.Name);VALUE=$($_.Value -join ',')"
        }
        Get-DhcpServerv4ExclusionRange -ScopeId $ScopeId | ForEach-Object {
            "EXCLUSION_START=$($_.StartRange);EXCLUSION_END=$($_.EndRange)"
        }
    } $required
}

function Test-B4DhcpServerAndScope {
    param([string]$ComputerName,[string]$ServerIp,[string]$ScopeId,[string]$ScopeName)
    $required=[ordered]@{
        "$ComputerName authorized"="AUTHORIZED_IP=$([regex]::Escape($ServerIp));AUTHORIZED_NAME=.*$([regex]::Escape($ComputerName))"
        "Scope $ScopeId"="SCOPEID=$([regex]::Escape($ScopeId))"
        "Scope name $ScopeName"="NAME=$([regex]::Escape($ScopeName))(?:;|$)"
    }
    Invoke-B4RegexChecks 'Get-DhcpServerInDC; Get-DhcpServerv4Scope (explicit properties, no table truncation)' {
        Get-DhcpServerInDC | ForEach-Object {
            "AUTHORIZED_IP=$($_.IPAddress);AUTHORIZED_NAME=$($_.DnsName)"
        }
        Get-DhcpServerv4Scope -ComputerName $ComputerName | ForEach-Object {
            "SCOPEID=$($_.ScopeId);NAME=$($_.Name);STATE=$($_.State);START=$($_.StartRange);END=$($_.EndRange);MASK=$($_.SubnetMask)"
        }
    } $required
}

function Test-B4ClientDhcp {
    param([string]$Prefix,[int]$Min,[int]$Max,[string]$Gateway,[string[]]$Dns)
    $checks=New-Object System.Collections.Generic.List[object]
    $checks.Add((New-B4Check 'DHCP IPv4 range' "$Prefix.$Min-$Max" {param($t,$v)
        $m=[regex]::Match($t,"IP="+[regex]::Escape($Prefix)+"\.(\d+);")
        $m.Success-and[int]$m.Groups[1].Value-ge$Min-and[int]$m.Groups[1].Value-le$Max
    }.GetNewClosure()))
    $g=$Gateway;$checks.Add((New-B4Check 'Gateway' $g {param($t,$v)$t-match[regex]::Escape($g)}.GetNewClosure()))
    foreach($dns in $Dns){$d=$dns;$checks.Add((New-B4Check "DNS $d" $d {param($t,$v)$t-match[regex]::Escape($d)}.GetNewClosure()))}
    $checks.Add((New-B4Check 'DNS suffix' 'nb-b4.local' {param($t,$v)$t-match'nb-b4\.local'}))
    Invoke-B4Checks 'Get-NetIPConfiguration; Get-NetIPAddress; Get-DnsClientServerAddress; ipconfig /all' {
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue|Where-Object {$_.PrefixOrigin-eq'Dhcp'}|ForEach-Object{"IP=$($_.IPAddress);Prefix=$($_.PrefixLength);Origin=$($_.PrefixOrigin)"}
        Get-NetIPConfiguration|ForEach-Object{if($_.IPv4DefaultGateway){"GATEWAY=$($_.IPv4DefaultGateway.NextHop)"}}
        Get-DnsClientServerAddress -AddressFamily IPv4|ForEach-Object{"DNS=$($_.ServerAddresses-join',')"}
        ipconfig /all
    } $checks.ToArray()
}

function Test-B4RequiredAdUsers {
    $users=@('sec.admin1','helpdesk.b4','auditor.b4','user.sh01','user.bj01','blocked.admin')
    $checks=New-Object System.Collections.Generic.List[object]
    foreach($userName in $users) {
        $u=$userName
        $prefix="USER=$([regex]::Escape($u));"
        $checks.Add((New-B4Check "$u exists" 'учётная запись существует' {
            param($t,$v) $t -match "(?m)^$prefix"
        }.GetNewClosure()))
        $checks.Add((New-B4Check "$u OU" 'OU=30-B4-TestUsers' {
            param($t,$v) $t -match "(?m)^$prefix[^\r\n]*;DN=CN=[^,\r\n]+,OU=30-B4-TestUsers,DC=nb-b4,DC=local\r?$"
        }.GetNewClosure()))
        $checks.Add((New-B4Check "$u enabled" 'Enabled=True' {
            param($t,$v) $t -match "(?m)^${prefix}Enabled=True;"
        }.GetNewClosure()))
        $checks.Add((New-B4Check "$u password change at first logon" 'PwdLastSet > 0 (смена при первом входе не требуется)' {
            param($t,$v)
            $m=[regex]::Match($t,"(?m)^${prefix}Enabled=[^;]+;Never=[^;]+;PwdLastSet=(\d+);")
            $m.Success -and [int64]$m.Groups[1].Value -gt 0
        }.GetNewClosure()))
        $checks.Add((New-B4Check "$u PasswordNeverExpires" 'Never=False' {
            param($t,$v) $t -match "(?m)^${prefix}Enabled=[^;]+;Never=False;"
        }.GetNewClosure()))
    }
    Invoke-B4Checks 'Get-ADUser for each required user: Enabled, PasswordNeverExpires, pwdLastSet, DistinguishedName' {
        foreach($u in $users) {
            try {
                $account=Get-ADUser -Identity $u -Properties Enabled,PasswordNeverExpires,pwdLastSet -ErrorAction Stop
                "USER=$u;Enabled=$($account.Enabled);Never=$($account.PasswordNeverExpires);PwdLastSet=$($account.pwdLastSet);DN=$($account.DistinguishedName)"
            } catch {
                "MISSING=$u;ERROR=$($_.Exception.Message)"
            }
        }
    } $checks.ToArray()
}

function Test-B4DomainPasswordPolicy {
    $required=[ordered]@{
        'Minimum password length'='MinPasswordLength=10(?:;|\r?\n|$)'
        'Password complexity'='ComplexityEnabled=True(?:;|\r?\n|$)'
        'Maximum password age'='MaxPasswordAgeDays=60(?:;|\r?\n|$)'
        'Minimum password age'='MinPasswordAgeDays=0(?:;|\r?\n|$)'
        'Fine-Grained Password Policies are not used'='FGPP_COUNT=0(?:;|\r?\n|$)'
    }
    Invoke-B4RegexChecks 'Get-ADDefaultDomainPasswordPolicy; Get-ADFineGrainedPasswordPolicy -Filter * (explicit properties)' {
        $p=Get-ADDefaultDomainPasswordPolicy -ErrorAction Stop
        "POLICY=Default;MinPasswordLength=$($p.MinPasswordLength);ComplexityEnabled=$($p.ComplexityEnabled);MaxPasswordAgeDays=$($p.MaxPasswordAge.TotalDays);MinPasswordAgeDays=$($p.MinPasswordAge.TotalDays)"
        $fgpp=@(Get-ADFineGrainedPasswordPolicy -Filter * -ErrorAction Stop)
        "FGPP_COUNT=$($fgpp.Count)"
        foreach($item in $fgpp) {
            "FGPP_NAME=$($item.Name);PRECEDENCE=$($item.Precedence);APPLIES_TO=$($item.AppliesTo -join ',')"
        }
    } $required
}

function Test-B4DomainLockoutPolicy {
    $required=[ordered]@{
        'Lockout threshold'='LockoutThreshold=5(?:;|\r?\n|$)'
        'Lockout duration'='LockoutDurationMinutes=15(?:;|\r?\n|$)'
        'Observation window'='LockoutObservationWindowMinutes=15(?:;|\r?\n|$)'
    }
    Invoke-B4RegexChecks 'Get-ADDefaultDomainPasswordPolicy (explicit lockout properties)' {
        $p=Get-ADDefaultDomainPasswordPolicy -ErrorAction Stop
        "POLICY=Default;LockoutThreshold=$($p.LockoutThreshold);LockoutDurationMinutes=$($p.LockoutDuration.TotalMinutes);LockoutObservationWindowMinutes=$($p.LockoutObservationWindow.TotalMinutes)"
    } $required
}

function Test-B4RequiredDnsHostRecords {
    $records=[ordered]@{
        'sha-rtr01.nb-b4.local'='10.24.20.1'
        'sha-dc01.nb-b4.local'='10.24.20.10'
        'sha-fs01.nb-b4.local'='10.24.20.20'
        'bj-rtr01.nb-b4.local'='10.34.20.1'
        'bj-dc02.nb-b4.local'='10.34.20.10'
        'bj-srv01.nb-b4.local'='10.34.20.20'
    }
    $checks=New-Object System.Collections.Generic.List[object]
    foreach($name in $records.Keys) {
        $fqdn=[string]$name
        $ip=[string]$records[$name]
        $checks.Add((New-B4Check "A $fqdn" "$fqdn -> $ip" {
            param($t,$v)
            $t -match "(?im)^A;NAME=$([regex]::Escape($fqdn));EXPECTED=$([regex]::Escape($ip));ACTUAL=$([regex]::Escape($ip));STATUS=PASS\r?$"
        }.GetNewClosure()))
        $checks.Add((New-B4Check "PTR $ip" "$ip -> $fqdn" {
            param($t,$v)
            $t -match "(?im)^PTR;IP=$([regex]::Escape($ip));EXPECTED=$([regex]::Escape($fqdn));ACTUAL=$([regex]::Escape($fqdn))\.?;STATUS=PASS\r?$"
        }.GetNewClosure()))
    }
    Invoke-B4Checks 'Resolve-DnsName -Type A for each required host; Resolve-DnsName -Type PTR for each required IP (errors isolated)' {
        foreach($name in $records.Keys) {
            $fqdn=[string]$name
            $expectedIp=[string]$records[$name]
            try {
                $answer=@(Resolve-DnsName -Name $fqdn -Type A -ErrorAction Stop |
                    Where-Object {$_.Type -eq 'A'} | Select-Object -ExpandProperty IPAddress -Unique)
                $actual=$answer -join ','
                $status=if($answer -contains $expectedIp){'PASS'}else{'FAIL'}
                "A;NAME=$fqdn;EXPECTED=$expectedIp;ACTUAL=$(if($actual){$actual}else{'<EMPTY>'});STATUS=$status"
            } catch {
                "A;NAME=$fqdn;EXPECTED=$expectedIp;ACTUAL=<ERROR>;STATUS=FAIL;ERROR=$($_.Exception.Message)"
            }
            try {
                $answer=@(Resolve-DnsName -Name $expectedIp -Type PTR -ErrorAction Stop |
                    Where-Object {$_.Type -eq 'PTR'} | Select-Object -ExpandProperty NameHost -Unique)
                $normalized=@($answer | ForEach-Object {$_.TrimEnd('.').ToLowerInvariant()})
                $actual=$answer -join ','
                $status=if($normalized -contains $fqdn.ToLowerInvariant()){'PASS'}else{'FAIL'}
                "PTR;IP=$expectedIp;EXPECTED=$fqdn;ACTUAL=$(if($actual){$actual}else{'<EMPTY>'});STATUS=$status"
            } catch {
                "PTR;IP=$expectedIp;EXPECTED=$fqdn;ACTUAL=<ERROR>;STATUS=FAIL;ERROR=$($_.Exception.Message)"
            }
        }
    } $checks.ToArray()
}

function Test-B4ComputerDomain {
    param([string]$OuPattern)
    $required=[ordered]@{
        'Domain joined'='(?m)^COMPUTER=[^;]+;DOMAIN=nb-b4\.local;PART_OF_DOMAIN=True\r?$'
        'Domain'='(?m)^COMPUTER=[^;]+;DOMAIN=nb-b4\.local;'
    }
    if($OuPattern){$required['Correct OU']="(?m)^DN=CN=[^,]+,$([regex]::Escape($OuPattern)),DC=nb-b4,DC=local\r?$"}
    Invoke-B4RegexChecks 'Read-only: Get-CimInstance Win32_ComputerSystem; LDAP lookup of the local computer distinguishedName' {
        $computer=Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        "COMPUTER=$($computer.Name);DOMAIN=$($computer.Domain);PART_OF_DOMAIN=$($computer.PartOfDomain)"
        try {
            $root=[ADSI]'LDAP://RootDSE'
            $base=[string]$root.defaultNamingContext
            $searcher=New-Object System.DirectoryServices.DirectorySearcher([ADSI]("LDAP://"+$base))
            $escapedName=([string]$env:COMPUTERNAME).Replace('\','\5c').Replace('*','\2a').Replace('(','\28').Replace(')','\29')
            $searcher.Filter="(&(objectCategory=computer)(sAMAccountName=$escapedName`$))"
            [void]$searcher.PropertiesToLoad.Add('distinguishedName')
            $found=$searcher.FindOne()
            if($found){"DN=$($found.Properties['distinguishedname'][0])"}else{"DN=NOT_FOUND;COMPUTER=$env:COMPUTERNAME"}
        } catch {
            "DN=LOOKUP_ERROR;ERROR=$($_.Exception.Message)"
        }
    } $required
}

function Test-B4ServerIdentity {
    param(
        [string]$ExpectedHost,
        [string]$ExpectedIp,
        [string]$ExpectedGateway,
        [string]$ExpectedSite
    )
    $required=[ordered]@{
        'Hostname'="HOST=$([regex]::Escape($ExpectedHost))(?:\r?\n|$)"
        'IPv4 /24'="IP=$([regex]::Escape($ExpectedIp));PREFIX=24;"
        'Gateway'="GATEWAY=$([regex]::Escape($ExpectedGateway));"
        'Domain membership'='DOMAIN=nb-b4\.local;PART_OF_DOMAIN=True'
        'Correct OU'="DN=CN=$([regex]::Escape($ExpectedHost)),OU=$([regex]::Escape($ExpectedSite)),OU=00-Servers,DC=nb-b4,DC=local"
    }
    Invoke-B4RegexChecks 'hostname; explicit network properties; Win32_ComputerSystem; LDAP lookup of computer DN' {
        "HOST=$env:COMPUTERNAME"
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object {$_.IPAddress -notlike '127.*' -and $_.AddressState -ne 'Deprecated'} |
            ForEach-Object {"IP=$($_.IPAddress);PREFIX=$($_.PrefixLength);INTERFACE=$($_.InterfaceAlias)"}
        Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Sort-Object RouteMetric |
            ForEach-Object {"GATEWAY=$($_.NextHop);INTERFACE_INDEX=$($_.InterfaceIndex);METRIC=$($_.RouteMetric)"}
        $computer=Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        "COMPUTER=$($computer.Name);DOMAIN=$($computer.Domain);PART_OF_DOMAIN=$($computer.PartOfDomain)"
        try {
            $root=[ADSI]'LDAP://RootDSE'
            $base=[string]$root.defaultNamingContext
            $searcher=New-Object System.DirectoryServices.DirectorySearcher([ADSI]("LDAP://"+$base))
            $escapedName=([string]$env:COMPUTERNAME).Replace('\','\5c').Replace('*','\2a').Replace('(','\28').Replace(')','\29')
            $searcher.Filter="(&(objectCategory=computer)(sAMAccountName=$escapedName`$))"
            [void]$searcher.PropertiesToLoad.Add('distinguishedName')
            $found=$searcher.FindOne()
            if($found){"DN=$($found.Properties['distinguishedname'][0])"}else{"DN=NOT_FOUND;COMPUTER=$env:COMPUTERNAME"}
        } catch {
            "DN=LOOKUP_ERROR;ERROR=$($_.Exception.Message)"
        }
    } $required
}

function Test-B4RemoteManagementMembership {
    $target='GG_B4_Remote_Management'
    $checks=@(
        (New-B4Check "$target in Remote Management Users" 'LOCAL_GROUP=Remote Management Users;MEMBER=NB-B4\GG_B4_Remote_Management' {
            param($t,$v)
            $t -match '(?im)^LOCAL_GROUP=Remote Management Users;MEMBER=[^\\;\r\n]+\\GG_B4_Remote_Management(?:;|\r?$)'
        }),
        (New-B4Check "$target is not a local administrator" 'no matching member in LOCAL_GROUP=Administrators' {
            param($t,$v)
            $t -notmatch '(?im)^LOCAL_GROUP=Administrators;MEMBER=[^\\;\r\n]+\\GG_B4_Remote_Management(?:;|\r?$)'
        })
    )
    Invoke-B4Checks "Get-LocalGroupMember 'Remote Management Users'; Get-LocalGroupMember Administrators (explicit group labels)" {
        foreach($groupName in @('Remote Management Users','Administrators')) {
            try {
                $members=@(Get-LocalGroupMember -Group $groupName -ErrorAction Stop)
                if($members.Count -eq 0) {
                    "LOCAL_GROUP=$groupName;MEMBER=<EMPTY>"
                } else {
                    foreach($member in $members) {
                        "LOCAL_GROUP=$groupName;MEMBER=$($member.Name);OBJECT_CLASS=$($member.ObjectClass);SOURCE=$($member.PrincipalSource)"
                    }
                }
            } catch {
                "LOCAL_GROUP=$groupName;ERROR=$($_.Exception.Message)"
            }
        }
    } $checks
}

function Test-B4AuditorLogReaderRights {
    $checks=@(
        (New-B4Check 'Auditor log-reader role' 'auditor.b4 or GG_B4_Auditors is a member of Event Log Readers' {
            param($t,$v)
            $t -match '(?im)^LOCAL_GROUP=Event Log Readers;MEMBER=[^;\r\n]*(?:\\auditor\.b4|\\GG_B4_Auditors)(?:;|\r?$)'
        }),
        (New-B4Check 'auditor.b4 is not a local administrator' 'no auditor.b4 member in Administrators' {
            param($t,$v)
            $t -notmatch '(?im)^LOCAL_GROUP=Administrators;MEMBER=[^;\r\n]*\\auditor\.b4(?:;|\r?$)'
        }),
        (New-B4Check 'GG_B4_Auditors is not a local administrator' 'no GG_B4_Auditors member in Administrators' {
            param($t,$v)
            $t -notmatch '(?im)^LOCAL_GROUP=Administrators;MEMBER=[^;\r\n]*\\GG_B4_Auditors(?:;|\r?$)'
        })
    )
    Invoke-B4Checks "Get-LocalGroupMember 'Event Log Readers'; Get-LocalGroupMember Administrators (explicit group labels)" {
        foreach($groupName in @('Event Log Readers','Administrators')) {
            try {
                $members=@(Get-LocalGroupMember -Group $groupName -ErrorAction Stop)
                if($members.Count -eq 0) {
                    "LOCAL_GROUP=$groupName;MEMBER=<EMPTY>"
                } else {
                    foreach($member in $members) {
                        "LOCAL_GROUP=$groupName;MEMBER=$($member.Name);OBJECT_CLASS=$($member.ObjectClass);SOURCE=$($member.PrincipalSource)"
                    }
                }
            } catch {
                "LOCAL_GROUP=$groupName;STATUS=LOOKUP_ERROR;ERROR=$($_.Exception.Message)"
            }
        }
    } $checks
}

function Test-B4WefNoAdminBypass {
    $sources=@('SHA-DC01','BJ-DC02','SHA-FS01','SHA-CL01','BJ-CL01')
    $checks=New-Object System.Collections.Generic.List[object]
    $checks.Add((New-B4Check 'Разрешённая серверная группа присутствует в Administrators' 'ADMINISTRATORS_MEMBER=NBB4\GG_B4_Server_Admins' {
        param($t,$v) $t -match '(?im)^ADMINISTRATORS_MEMBER=[^\\;\r\n]+\\GG_B4_Server_Admins(?:;|\r?$)'
    }))
    foreach($source in $sources){
        $s=$source
        $checks.Add((New-B4Check "WEF source $s не является локальным администратором" "нет ADMINISTRATORS_MEMBER=...\$s или ...\$s`$" {
            param($t,$v)
            $t -notmatch ("(?im)^ADMINISTRATORS_MEMBER=(?:[^\\;\r\n]+\\)?"+[regex]::Escape($s)+"(?:\\\$)?(?:;|\r?$)")
        }.GetNewClosure()))
    }
    Invoke-B4Checks "Get-LocalGroupMember Administrators; Get-LocalGroupMember 'Remote Management Users' (explicit group labels)" {
        foreach($groupName in @('Administrators','Remote Management Users')){
            try {
                $members=@(Get-LocalGroupMember -Group $groupName -ErrorAction Stop)
                if($members.Count -eq 0){"$($groupName.ToUpper().Replace(' ','_'))_MEMBER=<EMPTY>"}
                else {
                    foreach($member in $members){
                        "$($groupName.ToUpper().Replace(' ','_'))_MEMBER=$($member.Name);OBJECT_CLASS=$($member.ObjectClass);SOURCE=$($member.PrincipalSource)"
                    }
                }
            } catch {
                "$($groupName.ToUpper().Replace(' ','_'))_ERROR=$($_.Exception.Message)"
            }
        }
    } $checks.ToArray()
}

function New-B4ManualResult {
    param([string]$Message)
    Write-B4Log "[WARN] Требуется экспертное подтверждение: $Message" Yellow
    [pscustomobject]@{Status='WARN';Passed=0;Total=0;Message=$Message}
}

function Invoke-B4Aspect {
    param([string]$HostKey,[object]$Aspect)
    $id=$Aspect.AspectID
    switch($id) {
        'SHA-RTR01-01' {return Test-B4Network SHA-RTR01 @('198.18.140.10','10.24.10.1','10.24.20.1','10.24.30.1') '' }
        'SHA-RTR01-02' {return Test-B4Forwarding @('198.18.140.10','10.24.10.1','10.24.20.1','10.24.30.1')}
        'SHA-RTR01-03' {return Test-B4Routes @('10.34.20.0/24','10.34.30.0/24','198.18.201.0/24') '198.18.140.1'}
        'SHA-RTR01-04' {return Test-B4DhcpRelay '10.24.20.10' '10.24.30.1'}
        'SHA-RTR01-05' {return Invoke-B4RegexChecks 'Get-WindowsFeature RemoteAccess*; netsh routing ip nat show interface' {Get-WindowsFeature RemoteAccess*;netsh routing ip nat show interface 2>&1} ([ordered]@{'Routing role available'='RemoteAccess|Routing'}) @('NAT.*Enabled','VPN.*Enabled','Proxy.*Enabled')}
        'SHA-RTR01-06' {return Test-B4PingSet @('10.34.20.10','10.34.30.1')}
        'BJ-RTR01-01' {return Test-B4Network BJ-RTR01 @('198.18.141.10','10.34.20.1','10.34.30.1') '' }
        'BJ-RTR01-02' {return Test-B4Forwarding @('198.18.141.10','10.34.20.1','10.34.30.1')}
        'BJ-RTR01-03' {return Test-B4Routes @('10.24.10.0/24','10.24.20.0/24','10.24.30.0/24','198.18.200.0/24') '198.18.141.1'}
        'BJ-RTR01-04' {return Test-B4DhcpRelay '10.34.20.10' '10.34.30.1'}
        'BJ-RTR01-05' {return Invoke-B4RegexChecks 'Get-WindowsFeature RemoteAccess*; netsh routing ip nat show interface' {Get-WindowsFeature RemoteAccess*;netsh routing ip nat show interface 2>&1} ([ordered]@{'Routing role available'='RemoteAccess|Routing'}) @('NAT.*Enabled','VPN.*Enabled','Proxy.*Enabled')}
        'BJ-RTR01-06' {return Test-B4PingSet @('10.24.20.10','10.24.30.1')}

        'SHA-DC01-01' {return Test-B4Network SHA-DC01 @('10.24.20.10') '10.24.20.1' @('10.24.20.10','10.34.20.10')}
        'SHA-DC01-02' {return Invoke-B4RegexChecks 'Get-ADDomain; Get-ADForest' {Get-ADDomain;Get-ADForest} ([ordered]@{'DNS domain'='nb-b4\.local';'NetBIOS name'='NBB4';'Forest root'='RootDomain\s*:\s*nb-b4\.local'})}
        'SHA-DC01-03' {return Invoke-B4RegexChecks 'Get-ADDomainController SHA-DC01; dcdiag /test:Advertising' {Get-ADDomainController SHA-DC01;dcdiag /test:Advertising} ([ordered]@{'Global Catalog'='IsGlobalCatalog\s*:\s*True';'Advertising passed'='passed test Advertising'})}
        'SHA-DC01-04' {return Invoke-B4RegexChecks 'Get-SmbShare SYSVOL,NETLOGON' {Get-SmbShare -Name SYSVOL,NETLOGON} ([ordered]@{'SYSVOL'='SYSVOL';'NETLOGON'='NETLOGON'})}
        'SHA-DC01-05' {return Test-B4ReplicationHealth}
        'SHA-DC01-06' {return Invoke-B4RegexChecks 'Get-DnsServerZone nb-b4.local on both DCs' {foreach($dc in 'SHA-DC01','BJ-DC02'){Get-DnsServerZone -ComputerName $dc -Name nb-b4.local|ForEach-Object{"DC=$dc;Zone=$($_.ZoneName);Integrated=$($_.IsDsIntegrated);Scope=$($_.ReplicationScope)"}}} ([ordered]@{'SHA-DC01 zone'='DC=SHA-DC01;Zone=nb-b4\.local;Integrated=True';'BJ-DC02 zone'='DC=BJ-DC02;Zone=nb-b4\.local;Integrated=True'})}
        'SHA-DC01-07' {return Invoke-B4RegexChecks 'Get-DnsServerZone reverse zones' {Get-DnsServerZone} ([ordered]@{'10.24.10 reverse'='10\.24\.10\.in-addr\.arpa';'10.24.20 reverse'='20\.24\.10\.in-addr\.arpa';'10.24.30 reverse'='30\.24\.10\.in-addr\.arpa';'10.34.20 reverse'='20\.34\.10\.in-addr\.arpa';'10.34.30 reverse'='30\.34\.10\.in-addr\.arpa'})}
        'SHA-DC01-08' {return Test-B4RequiredDnsHostRecords}
        'SHA-DC01-09' {return Invoke-B4RegexChecks 'Resolve-DnsName sec-mgmt,eventlog' {Resolve-DnsName sec-mgmt.nb-b4.local;Resolve-DnsName eventlog.nb-b4.local} ([ordered]@{'sec-mgmt CNAME'='sha-cl01\.nb-b4\.local';'eventlog CNAME'='bj-srv01\.nb-b4\.local'})}
        'SHA-DC01-10' {return Test-B4DhcpServerAndScope 'SHA-DC01' '10.24.20.10' '10.24.30.0' 'Shanghai-ClientNet'}
        'SHA-DC01-11' {return Test-B4DhcpScope '10.24.30.0' 'Shanghai-ClientNet' '10.24.30.100' '10.24.30.200' '10.24.30.100' '10.24.30.119' '10.24.30.1' @('10.24.20.10','10.34.20.10')}
        'SHA-DC01-12' {return Invoke-B4RegexChecks 'Get-ADOrganizationalUnit -Filter *' {Get-ADOrganizationalUnit -Filter *|Select Name,DistinguishedName} ([ordered]@{'00-Servers'='OU=00-Servers';'Servers Shanghai'='OU=Shanghai,OU=00-Servers';'Servers Beijing'='OU=Beijing,OU=00-Servers';'10-Workstations'='OU=10-Workstations';'Workstations Shanghai'='OU=Shanghai,OU=10-Workstations';'Workstations Beijing'='OU=Beijing,OU=10-Workstations';'20-B4-Groups'='OU=20-B4-Groups';'30-B4-TestUsers'='OU=30-B4-TestUsers';'40-B4-ServiceAccounts'='OU=40-B4-ServiceAccounts'})}
        'SHA-DC01-13' {return Invoke-B4RegexChecks 'Get-ADGroup GG_B4_*' {Get-ADGroup -Filter "Name -like 'GG_B4_*'" -Properties GroupScope,GroupCategory,DistinguishedName} ([ordered]@{'Workstation Admins'='GG_B4_Workstation_Admins';'Server Admins'='GG_B4_Server_Admins';'Remote Management'='GG_B4_Remote_Management';'Auditors'='GG_B4_Auditors';'Standard Users'='GG_B4_Standard_Users';'No Admin Test'='GG_B4_No_Admin_Test';'Global scope'='GroupScope\s*:\s*Global';'Security category'='GroupCategory\s*:\s*Security'})}
        'SHA-DC01-14' {return Test-B4RequiredAdUsers}
        'SHA-DC01-15' {return Test-B4UserGroupMemberships}
        'SHA-DC01-16' {return Test-B4DomainPasswordPolicy}
        'SHA-DC01-17' {return Test-B4DomainLockoutPolicy}
        'SHA-DC01-18' {return Invoke-B4RegexChecks 'Get-GPO; Get-GPInheritance target OUs/DC OU' {Get-GPO -All;Get-GPInheritance 'OU=10-Workstations,DC=nb-b4,DC=local';Get-GPInheritance 'OU=00-Servers,DC=nb-b4,DC=local';Get-GPInheritance 'OU=Domain Controllers,DC=nb-b4,DC=local'} ([ordered]@{'Workstation GPO'='B4-Workstation-Local-Admins';'Server GPO'='B4-Server-Local-Admins';'Workstation OU link'='10-Workstations';'Server OU link'='00-Servers'})}
        'SHA-DC01-19' {return Invoke-B4RegexChecks 'Get-GPO B4-Advanced-Audit-Policy; Get-GPInheritance' {Get-GPO B4-Advanced-Audit-Policy;Get-GPInheritance 'OU=00-Servers,DC=nb-b4,DC=local';Get-GPInheritance 'OU=10-Workstations,DC=nb-b4,DC=local';Get-GPInheritance 'OU=Domain Controllers,DC=nb-b4,DC=local'} ([ordered]@{'Audit GPO exists'='B4-Advanced-Audit-Policy';'Servers targeted'='00-Servers';'Workstations targeted'='10-Workstations';'DC targeted'='Domain Controllers'})}
        'SHA-DC01-20' {return Test-B4Audit -AuditPolicyOnly}
        'SHA-DC01-21' {return Invoke-B4RegexChecks 'wevtutil gl Security' {wevtutil gl Security} ([ordered]@{'Security log >=256MB'='maxSize:\s*([3-9][0-9]{8,}|[1-9][0-9]{9,})';'Overwrite mode'='retention:\s*false'})}
        'SHA-DC01-22' {return Test-B4DcFirewallWefSource 'SHA-DC01'}
        'SHA-DC01-23' {return Test-B4Defender}
        'SHA-DC01-24' {return Invoke-B4RegexChecks 'Get-ADComputer out-of-scope names' {foreach($n in 'SHA-WEB01','SHA-APP01'){if(Get-ADComputer -Filter "Name -eq '$n'" -ErrorAction SilentlyContinue){"FORBIDDEN=$n"}else{"ABSENT=$n"}}} ([ordered]@{'SHA-WEB01 absent'='ABSENT=SHA-WEB01';'SHA-APP01 absent'='ABSENT=SHA-APP01'})}

        'BJ-DC02-01' {return Test-B4Network BJ-DC02 @('10.34.20.10') '10.34.20.1' @('10.34.20.10','10.24.20.10')}
        'BJ-DC02-02' {return Invoke-B4RegexChecks 'Get-ADDomainController BJ-DC02; dcdiag /test:Advertising' {Get-ADDomainController BJ-DC02;dcdiag /test:Advertising} ([ordered]@{'DC identity'='BJ-DC02';'Domain'='nb-b4\.local';'Advertising'='passed test Advertising'})}
        'BJ-DC02-03' {return Invoke-B4RegexChecks 'Get-ADDomainController; Get-SmbShare' {Get-ADDomainController BJ-DC02;Get-SmbShare -Name SYSVOL,NETLOGON} ([ordered]@{'Global Catalog'='IsGlobalCatalog\s*:\s*True';'SYSVOL'='SYSVOL';'NETLOGON'='NETLOGON'})}
        'BJ-DC02-04' {return Test-B4ReplicationHealth}
        'BJ-DC02-05' {return Invoke-B4RegexChecks 'Get-DnsServerZone; Resolve required records locally' {Get-DnsServerZone;foreach($n in 'sha-dc01.nb-b4.local','eventlog.nb-b4.local','10.24.20.20','10.34.20.20'){Resolve-DnsName $n -Server 127.0.0.1 -ErrorAction Continue}} ([ordered]@{'Forward zone'='nb-b4\.local';'Reverse zones'='in-addr\.arpa';'SHA DC record'='10\.24\.20\.10';'eventlog CNAME'='bj-srv01\.nb-b4\.local';'PTR response'='NameHost'})}
        'BJ-DC02-06' {return Test-B4DhcpServerAndScope 'BJ-DC02' '10.34.20.10' '10.34.30.0' 'Beijing-ClientNet'}
        'BJ-DC02-07' {return Test-B4DhcpScope '10.34.30.0' 'Beijing-ClientNet' '10.34.30.100' '10.34.30.200' '10.34.30.100' '10.34.30.119' '10.34.30.1' @('10.34.20.10','10.24.20.10')}
        'BJ-DC02-08' {return Test-B4DcFirewallWefSource 'BJ-DC02'}
        'BJ-DC02-09' {return Test-B4Defender}
        'BJ-DC02-10' {return Test-B4Audit 268435456}
        'BJ-DC02-11' {return Invoke-B4RegexChecks 'Query BJ-SRV01 ForwardedEvents for BJ-DC02' {Invoke-Command BJ-SRV01 {Get-WinEvent -LogName ForwardedEvents -MaxEvents 200|Where-Object MachineName -match'BJ-DC02'|Select-Object -First 5 Id,MachineName,TimeCreated}} ([ordered]@{'BJ-DC02 source events'='BJ-DC02'})}

        'SHA-FS01-01' {return Test-B4ServerIdentity 'SHA-FS01' '10.24.20.20' '10.24.20.1' 'Shanghai'}
        'SHA-FS01-02' {return Test-B4LocalAdmins 'GG_B4_Server_Admins'}
        'SHA-FS01-03' {return Test-B4RemoteManagementMembership}
        'SHA-FS01-04' {return Test-B4Firewall -WinRM}
        'SHA-FS01-05' {return Test-B4Firewall -WinRM}
        'SHA-FS01-06' {return Test-B4Defender -Baseline}
        'SHA-FS01-07' {return Test-B4Audit 134217728}
        'SHA-FS01-08' {return Test-B4WefSource SHA-FS01}

        'BJ-SRV01-01' {return Test-B4ServerIdentity 'BJ-SRV01' '10.34.20.20' '10.34.20.1' 'Beijing'}
        'BJ-SRV01-02' {return Test-B4LocalAdmins 'GG_B4_Server_Admins'}
        'BJ-SRV01-03' {return Test-B4RemoteManagementMembership}
        'BJ-SRV01-04' {return Test-B4Firewall -WinRM}
        'BJ-SRV01-05' {return Test-B4WefCollectorFirewall}
        'BJ-SRV01-06' {return Invoke-B4RegexChecks 'Get-CimInstance Win32_Service Wecsvc (explicit properties, no table parsing)' {
            $service=Get-CimInstance Win32_Service -Filter "Name='Wecsvc'" -ErrorAction Stop
            "SERVICE=$($service.Name);STATE=$($service.State);START_MODE=$($service.StartMode)"
        } ([ordered]@{
            'Wecsvc running'='SERVICE=Wecsvc;STATE=Running;'
            'Wecsvc automatic'='SERVICE=Wecsvc;[^\r\n]*START_MODE=Auto(?:;|$)'
        })}
        'BJ-SRV01-07' {return Invoke-B4RegexChecks 'wecutil es; wecutil gs B4-Security-Events' {wecutil es;wecutil gs B4-Security-Events} ([ordered]@{'Subscription exists'='B4-Security-Events';'Source initiated'='SourceInitiated|Source-initiated';'Forwarded Events destination'='ForwardedEvents|Forwarded Events'})}
        'BJ-SRV01-08' {return Test-B4WefSubscriptionSources}
        'BJ-SRV01-09' {return Test-B4ForwardedEventClasses}
        'BJ-SRV01-10' {return Test-B4ForwardedEventIds}
        'BJ-SRV01-11' {return Invoke-B4RegexChecks 'ForwardedEvents required source hosts' {Get-WinEvent -LogName ForwardedEvents -MaxEvents 1000|Select Id,MachineName,ProviderName} ([ordered]@{'SHA-DC01'='SHA-DC01';'BJ-DC02'='BJ-DC02';'SHA-FS01'='SHA-FS01';'SHA-CL01'='SHA-CL01';'BJ-CL01'='BJ-CL01'})}
        'BJ-SRV01-12' {return Test-B4Defender -Baseline}
        'BJ-SRV01-13' {return Test-B4Audit 134217728}
        'BJ-SRV01-14' {return Test-B4Firewall -WinRM -WefCollector}
        'BJ-SRV01-15' {return Test-B4WefNoAdminBypass}
        'BJ-SRV01-16' {return Test-B4AuditorLogReaderRights}

        'SHA-CL01-01' {return Test-B4ClientDhcp '10.24.30' 120 200 '10.24.30.1' @('10.24.20.10','10.34.20.10')}
        'SHA-CL01-02' {return Test-B4ComputerDomain 'OU=Shanghai,OU=10-Workstations'}
        'SHA-CL01-03' {return Invoke-B4RegexChecks 'Get-WindowsCapability -Online -Name Rsat*' {Get-WindowsCapability -Online -Name Rsat*|Where-Object State -eq Installed} ([ordered]@{'AD tools'='Rsat.ActiveDirectory';'DNS tools'='Rsat.Dns';'DHCP tools'='Rsat.DHCP';'Group Policy tools'='Rsat.GroupPolicy';'Server Manager tools'='Rsat.ServerManager'})}
        'SHA-CL01-04' {return Invoke-B4RegexChecks 'Resolve required names/CNAMEs' {foreach($n in 'sha-dc01.nb-b4.local','bj-srv01.nb-b4.local','sec-mgmt.nb-b4.local','eventlog.nb-b4.local'){Resolve-DnsName $n -ErrorAction Continue}} ([ordered]@{'SHA DC'='10\.24\.20\.10';'BJ SRV'='10\.34\.20\.20';'sec-mgmt'='sha-cl01\.nb-b4\.local';'eventlog'='bj-srv01\.nb-b4\.local'})}
        'SHA-CL01-05' {return Test-B4TcpSet @('SHA-DC01','BJ-DC02','SHA-FS01','BJ-SRV01') @(5985) $true}
        'SHA-CL01-06' {return Test-B4LocalAdmins 'GG_B4_Workstation_Admins'}
        'SHA-CL01-07' {return Invoke-B4RegexChecks "Get-LocalGroupMember 'Remote Management Users'" {Get-LocalGroupMember 'Remote Management Users'} ([ordered]@{'Remote management group'='GG_B4_Remote_Management'})}
        'SHA-CL01-08' {return Invoke-B4RegexChecks 'gpresult /r; verify gpresult.html' {gpresult /r;"HTML_EXISTS=$(Test-Path C:\Skills\B4\gpresult.html)"} ([ordered]@{'Workstation GPO applies'='B4-Workstation-Local-Admins';'Audit GPO applies'='B4-Advanced-Audit-Policy';'gpresult evidence'='HTML_EXISTS=True'})}
        'SHA-CL01-09' {return Invoke-B4RegexChecks 'Read validation evidence for allowed administrators' {Get-Content C:\Skills\B4\B4-validation.txt -Raw -ErrorAction SilentlyContinue;Get-LocalGroupMember Administrators} ([ordered]@{'sec.admin1 admin evidence'='sec\.admin1';'helpdesk workstation evidence'='helpdesk\.b4';'Workstation admin group'='GG_B4_Workstation_Admins'})}
        'SHA-CL01-10' {return Invoke-B4RegexChecks 'Read validation evidence for denied administrators' {Get-Content C:\Skills\B4\B4-validation.txt -Raw -ErrorAction SilentlyContinue} ([ordered]@{'helpdesk server denied'='helpdesk\.b4.*(DENY|not.*admin|FAIL)';'user.sh01 denied'='user\.sh01.*(DENY|not.*admin|FAIL)';'blocked.admin denied'='blocked\.admin.*(DENY|not.*admin|FAIL)'})}
        'SHA-CL01-11' {return Test-B4Defender -Baseline}
        'SHA-CL01-12' {return Test-B4Audit 67108864}
        'SHA-CL01-13' {return Test-B4WefSource SHA-CL01}
        'SHA-CL01-14' {return Invoke-B4RegexChecks 'Validation evidence and local Security events' {Get-Content C:\Skills\B4\B4-validation.txt -Raw -ErrorAction SilentlyContinue;Get-WinEvent -LogName Security -MaxEvents 3000|Where-Object Id -in 4624,4625,4720,4728,4729|Select Id,TimeCreated} ([ordered]@{'Successful logon 4624'='4624';'Failed logon 4625'='4625';'User creation 4720'='4720';'Group add 4728'='4728';'Group remove 4729'='4729'})}
        'SHA-CL01-15' {return Test-B4Submission @('gpresult.html','B4-validation.txt') @('DNS','DHCP','WEF')}

        'BJ-CL01-01' {return Test-B4ClientDhcp '10.34.30' 120 200 '10.34.30.1' @('10.34.20.10','10.24.20.10')}
        'BJ-CL01-02' {return Test-B4ComputerDomain 'OU=Beijing,OU=10-Workstations'}
        'BJ-CL01-03' {return Test-B4LocalAdmins 'GG_B4_Workstation_Admins'}
        'BJ-CL01-04' {return Test-B4Defender -Baseline}
        'BJ-CL01-05' {return Test-B4Audit 67108864}
        'BJ-CL01-06' {return Test-B4WefSource BJ-CL01}

        'INET-CL01-01' {return Test-B4TcpSet @('10.24.20.10') @(135,445,5985,3389) $false}
        'INET-CL01-02' {return Test-B4TcpSet @('10.34.20.10') @(135,445,5985,3389) $false}
        'INET-CL01-03' {return Test-B4TcpSet @('10.24.20.20') @(135,445,5985,3389) $false}
        'INET-CL01-04' {return Test-B4TcpSet @('10.34.20.20') @(135,445,5985,3389) $false}
        'INET-CL01-05' {return Invoke-B4RegexChecks 'Show IP-based external validation targets' {@('10.24.20.10','10.34.20.10','10.24.20.20','10.34.20.20')} ([ordered]@{'SHA DC IP'='10\.24\.20\.10';'BJ DC IP'='10\.34\.20\.10';'SHA FS IP'='10\.24\.20\.20';'BJ SRV IP'='10\.34\.20\.20'})}

        'SUB-01' {return Invoke-B4RegexChecks 'Test-Path C:\Skills\B4' {"EXISTS=$(Test-Path C:\Skills\B4)"} ([ordered]@{'Submission folder'='EXISTS=True'})}
        'SUB-02' {return Test-B4Submission @('B4-foundation.ps1') @('Get-NetIP','ADDomain','Dns','Dhcp')}
        'SUB-03' {return Test-B4Submission @('B4-ad-objects.ps1') @('OrganizationalUnit','ADGroup','ADUser')}
        'SUB-04' {return Test-B4Submission @('B4-gpo-account-policy.ps1','B4-gpo-local-admins.ps1') @('GPO')}
        'SUB-05' {return Test-B4Submission @('B4-firewall-remoting.ps1') @('Firewall','WinRM','5985')}
        'SUB-06' {return Test-B4Submission @('B4-defender-baseline.ps1') @('MpPreference','Scan')}
        'SUB-07' {return Test-B4Submission @('B4-audit-policy.ps1') @('auditpol','Security')}
        'SUB-08' {return Test-B4Submission @('B4-wef.ps1') @('wecutil','B4-Security-Events')}
        'SUB-09' {return Test-B4Submission @('B4-validation.txt') @('domain','DNS','DHCP','GPO','firewall','Defender','audit','WEF','INET')}
    }
    return New-B4ManualResult "Для аспекта $id автоматический evaluator не определён; используйте показанную полную команду."
}

function Write-B4Summary {
    $max=(@($script:B4Rows|Measure-Object MaxMark -Sum).Sum)
    $award=(@($script:B4Rows|Measure-Object Awarded -Sum).Sum)
    $counts=@{}
    foreach($s in 'PASS','PART','FAIL','WARN'){$counts[$s]=@($script:B4Rows|Where-Object Status -eq $s).Count}
    $lines=@(
        'B4 Local Evaluation Summary',
        '===========================',
        "Awarded: $([Math]::Round($award,3)) / $([Math]::Round($max,3))",
        "PASS=$($counts.PASS); PART=$($counts.PART); FAIL=$($counts.FAIL); WARN=$($counts.WARN)",
        'Итог относится к критериям текущей точки проверки.'
    )
    Write-Host ''
    Write-B4Log ($lines-join[Environment]::NewLine) DarkGray
    if($script:B4Report){Set-Content $script:B4SummaryPath ($lines-join[Environment]::NewLine) -Encoding UTF8}
}

function Invoke-B4HostChecks {
    param(
        [Parameter(Mandatory=$true)][string]$HostKey,
        [switch]$Report,
        [string]$ReportDir,
        [switch]$NoPause,
        [string]$StartFromAspect
    )
    $HostKey=$HostKey.ToUpperInvariant()
    $script:B4Pause=-not$NoPause
    Initialize-B4Report $HostKey -Report:$Report -ReportDir $ReportDir
    Write-B4Section "B4 local checks for $HostKey"
    Write-B4Log "B4 checker version: $script:B4Version" Green
    Write-B4Log "Common: $PSCommandPath" DarkGray
    Write-B4Log "Criteria: $script:B4CriteriaPath" DarkGray
    $criteria=@(Get-B4Criteria $HostKey)
    if($criteria.Count-eq0){throw "Для $HostKey нет критериев B4."}
    foreach($aspect in $criteria){
        if($StartFromAspect-and[string]::Compare($aspect.AspectID,$StartFromAspect,$true)-lt0){continue}
        Start-B4Aspect $aspect
        try{$result=Invoke-B4Aspect $HostKey $aspect}
        catch{
            Invoke-B4Evidence 'Unhandled checker exception' {$_.Exception.ToString()}|Out-Null
            $result=New-B4ManualResult "Ошибка evaluator: $($_.Exception.Message)"
        }
        Complete-B4Aspect $aspect $result
    }
    Write-B4Summary
}
