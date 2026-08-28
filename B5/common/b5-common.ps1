Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:B5Root = Split-Path -Parent $PSScriptRoot
$script:B5CriteriaPath = Join-Path $script:B5Root 'criteria\b5_device_criteria_map.tsv'
$script:B5Version = '2026-08-26.4'
$script:B5Pause = $true
$script:B5Report = $false
$script:B5Rows = @()

function ConvertTo-B5Text {
    param([object]$Value)
    $parts = foreach ($item in @($Value)) {
        if ($null -eq $item) { continue }
        if ($item.PSObject.BaseObject -is [string] -or $item.PSObject.BaseObject -is [ValueType]) {
            ([string]$item).TrimEnd()
        } else { ($item | Out-String -Width 4096).TrimEnd() }
    }
    return (($parts -join [Environment]::NewLine).TrimEnd())
}

function Write-B5Log {
    param([string]$Text,[ConsoleColor]$Color=[ConsoleColor]::Gray)
    Write-Host $Text -ForegroundColor $Color
    if ($script:B5Report) { Add-Content -LiteralPath $script:B5DetailPath -Value $Text -Encoding UTF8 }
}

function Initialize-B5Report {
    param([string]$HostKey,[switch]$Report,[string]$ReportDir)
    $script:B5Rows=@(); $script:B5Report=$false
    if (-not $Report -and [string]::IsNullOrWhiteSpace($ReportDir)) { return }
    if ([string]::IsNullOrWhiteSpace($ReportDir)) { $ReportDir=Join-Path $script:B5Root "reports\$HostKey" }
    New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
    $script:B5DetailPath=Join-Path $ReportDir 'b5-detail.log'
    $script:B5ResultsPath=Join-Path $ReportDir 'b5-results.tsv'
    $script:B5SummaryPath=Join-Path $ReportDir 'b5-summary.txt'
    Set-Content $script:B5DetailPath '' -Encoding UTF8
    Set-Content $script:B5ResultsPath "AspectID`tHostKey`tMaxMark`tAwarded`tStatus`tMessage" -Encoding UTF8
    $script:B5Report=$true
}

function Get-B5Criteria {
    param([string]$HostKey)
    if (-not (Test-Path $script:B5CriteriaPath)) { throw "Не найдена карта: $script:B5CriteriaPath" }
    return @(Import-Csv $script:B5CriteriaPath -Delimiter "`t" -Encoding UTF8 | Where-Object HostKey -eq $HostKey)
}

function Start-B5Aspect {
    param([object]$Aspect)
    Write-Host ''
    Write-B5Log ('#' * 86) Magenta
    Write-B5Log "[$($Aspect.AspectID)] $($Aspect.Requirement)" Yellow
    Write-B5Log "Раздел: $($Aspect.TaskRef); максимум: $($Aspect.MaxMark)" DarkYellow
    Write-B5Log 'Команда из marking scheme (для ручной проверки):' Green
    Write-B5Log $Aspect.VerificationCommands DarkGreen
    Write-B5Log "Ожидаемый результат: $($Aspect.ExpectedResult)" Cyan
    if ($Aspect.AwardGuidance) { Write-B5Log "Правило оценки: $($Aspect.AwardGuidance)" DarkCyan }
}

function Invoke-B5Evidence {
    param([string]$Command,[scriptblock]$ScriptBlock)
    Write-B5Log "Команда автоматической read-only проверки: $Command" Cyan
    $items=New-Object System.Collections.Generic.List[object]; $ok=$true
    try { & $ScriptBlock | ForEach-Object { [void]$items.Add($_) } }
    catch { $ok=$false; [void]$items.Add("[ERROR] $($_.Exception.Message)") }
    $text=ConvertTo-B5Text $items.ToArray()
    if ([string]::IsNullOrWhiteSpace($text)) { $text='(пустой вывод)' }
    Write-B5Log 'Фактический вывод (полный):' Blue; Write-B5Log $text Gray
    [pscustomobject]@{Ok=$ok;Text=$text;Value=$items.ToArray()}
}

function New-B5Check { param([string]$Label,[string]$Expected,[scriptblock]$Test)
    [pscustomobject]@{Label=$Label;Expected=$Expected;Test=$Test}
}

function Invoke-B5Checks {
    param([string]$Command,[scriptblock]$Collect,[object[]]$Checks)
    $e=Invoke-B5Evidence $Command $Collect; $passed=0
    Write-B5Log 'Результаты по отдельным свойствам:' Blue
    foreach($check in $Checks) {
        $good=$false; $errorText=''
        try { $good=[bool](& $check.Test $e.Text $e.Value) } catch { $errorText=$_.Exception.Message }
        if($good) { $passed++; Write-B5Log "[PASS] $($check.Label); ожидается: $($check.Expected)" Green }
        else { Write-B5Log "[FAIL] $($check.Label); ожидается: $($check.Expected) $errorText" Red }
    }
    $total=$Checks.Count
    $status=if($passed-eq$total -and $e.Ok){'PASS'}elseif($passed-gt 0){'PART'}else{'FAIL'}
    $suffix=if($e.Ok){''}else{'; сбор evidence завершился с ошибкой'}
    [pscustomobject]@{Status=$status;Passed=$passed;Total=$total;Message="$passed/$total свойств подтверждено$suffix"}
}

function Invoke-B5RegexChecks {
    param([string]$Command,[scriptblock]$Collect,[System.Collections.IDictionary]$Required,[string[]]$Forbidden=@())
    $checks=New-Object System.Collections.Generic.List[object]
    foreach($label in $Required.Keys) { $p=[string]$Required[$label]; $checks.Add((New-B5Check $label $p {param($t,$v)$t-match$p}.GetNewClosure())) }
    foreach($pattern in $Forbidden) { $p=$pattern; $checks.Add((New-B5Check "Отсутствует: $p" "нет совпадения $p" {param($t,$v)$t-notmatch$p}.GetNewClosure())) }
    Invoke-B5Checks $Command $Collect $checks.ToArray()
}

function Complete-B5Aspect {
    param([object]$Aspect,[object]$Result)
    $max=[double]$Aspect.MaxMark
    $allOrNothing=@('A-ISP-SHA01-01','A-ISP-SHA01-02','A-ISP-BJ01-01','A-ISP-BJ01-02','A-SHA-RTR01-01','A-BJ-RTR01-01','D-SHA-CL01-04','E-SHA-DC01-06','H-BJ-SRV01-02','J-SHA-CL01-02')
    $award=if($Result.Total-le0){0}elseif($Aspect.AspectID-in$allOrNothing-and$Result.Status-ne'PASS'){0}else{[Math]::Round($max*$Result.Passed/$Result.Total,3)}
    if($Aspect.AspectID-in$allOrNothing-and$Result.Status-ne'PASS'){$Result.Message="$($Result.Message); по Award Guidance аспект оценивается только целиком"}
    $row=[pscustomobject]@{AspectID=$Aspect.AspectID;HostKey=$Aspect.HostKey;MaxMark=$max;Awarded=$award;Status=$Result.Status;Message=$Result.Message}
    $script:B5Rows+=,$row
    if($script:B5Report) { $safe=$Result.Message-replace"`t",' '-replace"`r?`n",' '; Add-Content $script:B5ResultsPath "$($Aspect.AspectID)`t$($Aspect.HostKey)`t$max`t$award`t$($Result.Status)`t$safe" -Encoding UTF8 }
    $color=if($Result.Status-eq'PASS'){'Green'}elseif($Result.Status-eq'PART'){'Magenta'}elseif($Result.Status-eq'WARN'){'Yellow'}else{'Red'}
    Write-B5Log "[$($Result.Status)] $($Aspect.AspectID) $award/$max ($($Result.Passed)/$($Result.Total)) — $($Result.Message)" $color
    if($script:B5Pause){[void](Read-Host 'Нажмите Enter, чтобы продолжить')}
}

function Test-B5Network {
    param([string]$HostName,[string[]]$IPs,[string]$Gateway,[switch]$Workgroup,[switch]$Forwarding)
    $checks=New-Object System.Collections.Generic.List[object]
    $checks.Add((New-B5Check 'Hostname' $HostName {param($t,$v)$env:COMPUTERNAME-ieq$HostName}.GetNewClosure()))
    foreach($spec in $IPs){
        $parts=$spec.Split('/');$ip=$parts[0];$prefix=if($parts.Count-gt1){[int]$parts[1]}else{24};$x=$ip;$plen=$prefix
        $checks.Add((New-B5Check "IPv4 $x/$plen" "$x/$plen" {param($t,$v)$t-match("IP="+[regex]::Escape($x)+";PREFIX=$plen;")}.GetNewClosure()))
        if($Forwarding){$checks.Add((New-B5Check "Forwarding on $x interface" 'Enabled' {param($t,$v)$t-match("IP="+[regex]::Escape($x)+";PREFIX=\d+;INDEX=(\d+);(?s).*FWD_INDEX=\1;STATE=Enabled")}.GetNewClosure()))}
    }
    if($Gateway){$x=$Gateway;$checks.Add((New-B5Check 'Default gateway' $x {param($t,$v)$t-match("GW="+[regex]::Escape($x)+";")}.GetNewClosure()))}
    if($Workgroup){$checks.Add((New-B5Check 'Workgroup boundary' 'PartOfDomain=False' {param($t,$v)$t-match'DOMAIN=False'}))}
    Invoke-B5Checks 'Get-NetIPAddress; Get-NetIPConfiguration; Win32_ComputerSystem; Get-NetIPInterface' {
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue|Where-Object IPAddress -notlike '169.254.*'|ForEach-Object{"IP=$($_.IPAddress);PREFIX=$($_.PrefixLength);INDEX=$($_.InterfaceIndex);IF=$($_.InterfaceAlias)"}
        Get-NetIPConfiguration|Where-Object IPv4DefaultGateway|ForEach-Object{"GW=$($_.IPv4DefaultGateway.NextHop);IF=$($_.InterfaceAlias)"}
        $cs=Get-CimInstance Win32_ComputerSystem; "DOMAIN=$($cs.PartOfDomain);NAME=$($cs.Name)"
        Get-NetIPInterface -AddressFamily IPv4|ForEach-Object{"FWD_INDEX=$($_.InterfaceIndex);STATE=$($_.Forwarding);IF=$($_.InterfaceAlias)"}
    } $checks.ToArray()
}

function Test-B5Routes { param([System.Collections.IDictionary]$Routes)
    $checks=foreach($prefix in $Routes.Keys){$p=[string]$prefix;$hop=[string]$Routes[$prefix];New-B5Check "Route $p" "next hop $hop" {param($t,$v)@($v|Where-Object{$_.DestinationPrefix-eq$p-and$_.NextHop-eq$hop}).Count-gt0}.GetNewClosure()}
    Invoke-B5Checks 'Get-NetRoute -AddressFamily IPv4' {Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue} @($checks)
}

function Test-B5DnsClient { param([string[]]$Servers)
    $expected=($Servers-join',');$checks=@(
        (New-B5Check 'Preferred/alternate DNS order' $expected {param($t,$v)$t-match("DNS_ORDER="+[regex]::Escape($expected)+"(?:;|$)")}.GetNewClosure())
    )
    Invoke-B5Checks 'Get-DnsClientServerAddress on active IPv4 interface' {
        $defaultRoute=Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0'|Sort-Object RouteMetric|Select-Object -First 1
        $active=Get-NetIPConfiguration -InterfaceIndex $defaultRoute.InterfaceIndex
        $dns=Get-DnsClientServerAddress -InterfaceIndex $active.InterfaceIndex -AddressFamily IPv4
        "INTERFACE=$($active.InterfaceAlias);DNS_ORDER=$($dns.ServerAddresses-join',');"
    } $checks
}

function Test-B5Firewall {
    $checks=foreach($name in 'Domain','Private','Public'){$x=$name;New-B5Check "$x firewall" 'Enabled=True' {param($t,$v)@($v|Where-Object{$_.Name-eq$x-and$_.Enabled}).Count-gt0}.GetNewClosure()}
    Invoke-B5Checks 'Get-NetFirewallProfile' {Get-NetFirewallProfile} @($checks)
}

function Test-B5WinRM {
    $checks=@(
        (New-B5Check 'WinRM service' 'Running' {param($t,$v)$t-match'SERVICE=Running'}),
        (New-B5Check 'HTTP listener' '5985' {param($t,$v)$t-match'5985|Transport\s*=\s*HTTP'}),
        (New-B5Check 'Scoped firewall source' '10.25.30.0/24' {param($t,$v)$t-match'10\.25\.30\.0/255\.255\.255\.0|10\.25\.30\.0/24'}),
        (New-B5Check 'No Any source on WinRM rule' 'RemoteAddress is not Any' {param($t,$v)$t-notmatch'WINRM_RULE=.*REMOTE=(Any|\*)'})
    )
    Invoke-B5Checks 'Get-Service WinRM; winrm enumerate listener; WinRM firewall address filters' {
        "SERVICE=$((Get-Service WinRM).Status)"; winrm.exe enumerate winrm/config/listener 2>&1
        Get-NetFirewallRule -Enabled True -Direction Inbound|Where-Object DisplayGroup -match 'Windows Remote Management'|ForEach-Object{$a=$_|Get-NetFirewallAddressFilter;"WINRM_RULE=$($_.DisplayName);REMOTE=$($a.RemoteAddress-join',')"}
    } $checks
}

function Test-B5TcpSet { param([string[]]$Targets,[int[]]$Ports,[bool]$Expected)
    $checks=foreach($target in $Targets){foreach($port in $Ports){$h=$target;$p=$port;New-B5Check "$h TCP/$p" "TcpTestSucceeded=$Expected" {param($t,$v)@($v|Where-Object{$_.ComputerName-eq$h-and$_.RemotePort-eq$p-and$_.TcpTestSucceeded-eq$Expected}).Count-gt0}.GetNewClosure()}}
    Invoke-B5Checks 'Test-NetConnection for each IP/port' {foreach($h in $Targets){foreach($p in $Ports){Test-NetConnection $h -Port $p -WarningAction SilentlyContinue}}} @($checks)
}

function Test-B5PingSet { param([string[]]$Targets)
    $checks=foreach($target in $Targets){$x=$target;New-B5Check "Reachability $x" 'ICMP reply' {param($t,$v)@($v|Where-Object{$_.Target-eq$x-and$_.Success}).Count-gt0}.GetNewClosure()}
    Invoke-B5Checks 'Test-Connection for each target' {foreach($target in $Targets){[pscustomobject]@{Target=$target;Success=[bool](Test-Connection $target -Count 2 -Quiet -ErrorAction SilentlyContinue)}}} @($checks)
}

function Test-B5ReachabilityOrRoute { param([string[]]$Targets,[string]$ExpectedNextHop)
    $checks=foreach($target in $Targets){$x=$target;$hop=$ExpectedNextHop;New-B5Check "Reachability or correct route $x" "ICMP reply or route via $hop" {param($t,$v)@($v|Where-Object{$_.Target-eq$x-and($_.Ping-or($_.RouteFound-and$_.NextHop-eq$hop))}).Count-gt0}.GetNewClosure()}
    Invoke-B5Checks 'Test-Connection and Find-NetRoute for each target' {
        foreach($target in $Targets){
            $route=Find-NetRoute -RemoteIPAddress $target -ErrorAction SilentlyContinue|Select-Object -First 1
            [pscustomobject]@{Target=$target;Ping=[bool](Test-Connection $target -Count 2 -Quiet -ErrorAction SilentlyContinue);RouteFound=[bool]$route;NextHop=if($route){$route.NextHop}else{''};Interface=if($route){$route.InterfaceAlias}else{''}}
        }
    } @($checks)
}

function Test-B5WsManSet { param([string[]]$Targets)
    $checks=foreach($target in $Targets){$x=$target;New-B5Check "WSMan $x" 'Test-WSMan succeeds' {param($t,$v)@($v|Where-Object{$_.Target-eq$x-and$_.Success}).Count-gt0}.GetNewClosure()}
    Invoke-B5Checks 'Test-WSMan for every managed host' {foreach($target in $Targets){try{Test-WSMan $target -ErrorAction Stop|Out-Null;$ok=$true}catch{$ok=$false};[pscustomobject]@{Target=$target;Success=$ok}}} @($checks)
}

function Test-B5WorkgroupBaseline { param([string[]]$ForbiddenFeatures)
    $checks=@(
        (New-B5Check 'Domain firewall' 'Enabled' {param($t,$v)(@($v.Firewall|Where-Object Name -eq 'Domain')).Enabled-eq$true}),
        (New-B5Check 'Private firewall' 'Enabled' {param($t,$v)(@($v.Firewall|Where-Object Name -eq 'Private')).Enabled-eq$true}),
        (New-B5Check 'Public firewall' 'Enabled' {param($t,$v)(@($v.Firewall|Where-Object Name -eq 'Public')).Enabled-eq$true}),
        (New-B5Check 'Workgroup boundary' 'PartOfDomain=False' {param($t,$v)-not$v.ComputerSystem.PartOfDomain})
    )
    foreach($feature in $ForbiddenFeatures){$x=$feature;$checks+=New-B5Check "Feature $x absent" 'Available/Removed' {param($t,$v)(@($v.Features|Where-Object Name -eq $x)).InstallState-ne'Installed'}.GetNewClosure()}
    $evidence={
        $firewall=@(Get-NetFirewallProfile);$computer=Get-CimInstance Win32_ComputerSystem
        $features=if($ForbiddenFeatures.Count){@(Get-WindowsFeature -Name $ForbiddenFeatures)}else{@()}
        [pscustomobject]@{Firewall=$firewall;ComputerSystem=$computer;Features=$features}
    }.GetNewClosure()
    Invoke-B5Checks 'Firewall profiles, domain boundary and prohibited server roles' $evidence $checks
}

function Test-B5AdGroups {
    $names=@('GG_B5_Workstation_Admins','GG_B5_Server_Admins','GG_B5_LAPS_Readers','GG_B5_AppLocker_TestUsers','GG_B5_Ansible_Operators','GG_B5_GMSA_Hosts')
    $checks=foreach($name in $names){$x=$name;New-B5Check "$x Global Security" 'exists; Global; Security' {param($t,$v)$g=@($v|Where-Object Name -eq $x);$g.Count-eq1-and$g[0].GroupScope-eq'Global'-and$g[0].GroupCategory-eq'Security'}.GetNewClosure()}
    Invoke-B5Checks 'Get-ADGroup for each required group' {foreach($name in $names){Get-ADGroup $name -Properties GroupScope,GroupCategory}} @($checks)
}

function Test-B5AdUsers {
    $membership=[ordered]@{
        'sec.admin1'=@('Domain Admins','GG_B5_Server_Admins','GG_B5_Workstation_Admins','GG_B5_LAPS_Readers','GG_B5_Ansible_Operators')
        'laps.reader1'=@('GG_B5_LAPS_Readers');'ansible.op1'=@('GG_B5_Ansible_Operators')
        'user.sh01'=@('GG_B5_AppLocker_TestUsers');'user.bj01'=@('GG_B5_AppLocker_TestUsers')
    }
    $checks=New-Object System.Collections.Generic.List[object]
    foreach($name in $membership.Keys){
        $x=$name;$checks.Add((New-B5Check "$x enabled/password flags" 'Enabled; PasswordNeverExpires=False; no forced change' {param($t,$v)$u=@($v|Where-Object User -eq $x)[0];$u-and$u.Enabled-and-not$u.PasswordNeverExpires-and$u.PasswordLastSet}.GetNewClosure()))
        foreach($group in $membership[$name]){$uName=$name;$gName=$group;$checks.Add((New-B5Check "$uName member of $gName" $gName {param($t,$v)$u=@($v|Where-Object User -eq $uName)[0];$u.Groups-contains$gName}.GetNewClosure()))}
    }
    Invoke-B5Checks 'Get-ADUser and effective group memberships' {foreach($name in $membership.Keys){$u=Get-ADUser $name -Properties Enabled,PasswordNeverExpires,PasswordLastSet;[pscustomobject]@{User=$name;Enabled=$u.Enabled;PasswordNeverExpires=$u.PasswordNeverExpires;PasswordLastSet=$u.PasswordLastSet;Groups=@(Get-ADPrincipalGroupMembership $name|Select-Object -Expand Name)}}} $checks.ToArray()
}

function Test-B5DnsRecords {
    $records=[ordered]@{
        'sha-rtr01.nb-b5.local'='10.25.20.1';'sha-web01.nb-b5.local'='10.25.10.11';'sha-app01.nb-b5.local'='10.25.10.12'
        'sha-dc01.nb-b5.local'='10.25.20.10';'sha-fs01.nb-b5.local'='10.25.20.20';'bj-rtr01.nb-b5.local'='10.35.20.1'
        'bj-dc02.nb-b5.local'='10.35.20.10';'bj-srv01.nb-b5.local'='10.35.20.20';'inet-srv01.nb-b5.local'='198.18.200.10';'inet-cl01.nb-b5.local'='198.18.201.10'
    }
    $checks=New-Object System.Collections.Generic.List[object]
    foreach($name in $records.Keys){
        $n=$name;$ip=$records[$name]
        $checks.Add((New-B5Check "A $n" $ip {param($t,$v)@($v|Where-Object{$_.Kind-eq'A'-and$_.Query-eq$n-and$_.Value-eq$ip}).Count-gt0}.GetNewClosure()))
        $checks.Add((New-B5Check "PTR $ip" $n {param($t,$v)@($v|Where-Object{$_.Kind-eq'PTR'-and$_.Query-eq$ip-and$_.Value.TrimEnd('.')-ieq$n}).Count-gt0}.GetNewClosure()))
    }
    Invoke-B5Checks 'Resolve all required A and PTR records' {
        foreach($name in $records.Keys){
            $ip=$records[$name]
            Resolve-DnsName $name -Type A -ErrorAction SilentlyContinue|ForEach-Object{if($_.IPAddress){[pscustomobject]@{Kind='A';Query=$name;Value=$_.IPAddress}}}
            Resolve-DnsName $ip -Type PTR -ErrorAction SilentlyContinue|ForEach-Object{if($_.NameHost){[pscustomobject]@{Kind='PTR';Query=$ip;Value=$_.NameHost}}}
        }
    } $checks.ToArray()
}

function Test-B5DhcpScope {
    param([string]$Server,[string]$ScopeId,[string]$ScopeName,[string]$Gateway,[string[]]$Dns)
    $start=$ScopeId-replace'0$','100';$end=$ScopeId-replace'0$','200';$exEnd=$ScopeId-replace'0$','119';$dnsOrder=$Dns-join','
    $checks=@(
        (New-B5Check 'DHCP server authorized' $Server {param($t,$v)@($v.Auth|Where-Object{$_.DnsName-ieq("$Server.nb-b5.local")-or$_.DnsName-ieq$Server}).Count-gt0}.GetNewClosure()),
        (New-B5Check 'Scope ID/name/mask' "$ScopeId $ScopeName /24" {param($t,$v)$v.Scope.ScopeId.IPAddressToString-eq$ScopeId-and$v.Scope.Name-eq$ScopeName-and$v.Scope.SubnetMask.IPAddressToString-eq'255.255.255.0'}.GetNewClosure()),
        (New-B5Check 'Scope range' "$start-$end" {param($t,$v)$v.Scope.StartRange.IPAddressToString-eq$start-and$v.Scope.EndRange.IPAddressToString-eq$end}.GetNewClosure()),
        (New-B5Check 'Exclusion range' "$start-$exEnd" {param($t,$v)@($v.Exclusions|Where-Object{$_.StartRange.IPAddressToString-eq$start-and$_.EndRange.IPAddressToString-eq$exEnd}).Count-gt0}.GetNewClosure()),
        (New-B5Check 'Router option' $Gateway {param($t,$v)(@($v.Options|Where-Object OptionId -eq 3)[0].Value-join',')-eq$Gateway}.GetNewClosure()),
        (New-B5Check 'Ordered DNS option' $dnsOrder {param($t,$v)(@($v.Options|Where-Object OptionId -eq 6)[0].Value-join',')-eq$dnsOrder}.GetNewClosure()),
        (New-B5Check 'DNS suffix option' 'nb-b5.local' {param($t,$v)(@($v.Options|Where-Object OptionId -eq 15)[0].Value-join',')-eq'nb-b5.local'})
    )
    $collect={
        [pscustomobject]@{
            Auth=@(Get-DhcpServerInDC);Scope=Get-DhcpServerv4Scope -ComputerName $Server -ScopeId $ScopeId
            Exclusions=@(Get-DhcpServerv4ExclusionRange -ComputerName $Server -ScopeId $ScopeId)
            Options=@(Get-DhcpServerv4OptionValue -ComputerName $Server -ScopeId $ScopeId)
        }
    }.GetNewClosure()
    Invoke-B5Checks 'Typed DHCP authorization, scope, exclusion and options' $collect $checks
}

function Test-B5DcRole { param([string]$Name)
    $checks=@(
        (New-B5Check 'Exact DC identity' $Name {param($t,$v)$v.DC.HostName-split'\.'|Select-Object -First 1|Where-Object{$_-ieq$Name}}.GetNewClosure()),
        (New-B5Check 'Correct domain' 'nb-b5.local' {param($t,$v)$v.DC.Domain-eq'nb-b5.local'}),
        (New-B5Check 'Global Catalog' 'True' {param($t,$v)$v.DC.IsGlobalCatalog}),
        (New-B5Check 'AD DS installed' 'Installed' {param($t,$v)(@($v.Features|Where-Object Name -eq 'AD-Domain-Services')).InstallState-eq'Installed'}),
        (New-B5Check 'DNS installed' 'Installed' {param($t,$v)(@($v.Features|Where-Object Name -eq 'DNS')).InstallState-eq'Installed'})
    )
    $collect={$dc=Get-ADDomainController $Name;$features=@(Get-WindowsFeature AD-Domain-Services,DNS);[pscustomobject]@{DC=$dc;Features=$features}}.GetNewClosure()
    Invoke-B5Checks 'Typed domain controller identity and role features' $collect $checks
}

function Test-B5ReplicationAndTime {
    $checks=@(
        (New-B5Check 'Replication partners present' 'at least two inbound partner records' {param($t,$v)@($v.Metadata).Count-ge2}),
        (New-B5Check 'No replication failures' 'LastReplicationResult=0 for every partner' {param($t,$v)@($v.Metadata|Where-Object LastReplicationResult -ne 0).Count-eq0}),
        (New-B5Check 'Recent successful replication' 'LastReplicationSuccess is populated' {param($t,$v)@($v.Metadata|Where-Object{-not$_.LastReplicationSuccess}).Count-eq0}),
        (New-B5Check 'Time offset within five minutes' '|offset| <= 300 seconds' {param($t,$v)$v.TimeParsed-and[Math]::Abs($v.OffsetSeconds)-le300})
    )
    Invoke-B5Checks 'Get-ADReplicationPartnerMetadata and w32tm stripchart' {
        $metadata=@(Get-ADReplicationPartnerMetadata -Target * -Scope Server)
        $raw=(w32tm.exe /stripchart /computer:BJ-DC02 /samples:1 /dataonly 2>&1|Out-String)
        $match=[regex]::Match($raw,'(?<offset>[+-]?\d+(?:[\.,]\d+)?)s')
        $offset=if($match.Success){[double]::Parse(($match.Groups['offset'].Value-replace',','.'),[Globalization.CultureInfo]::InvariantCulture)}else{0}
        [pscustomobject]@{Metadata=$metadata;TimeRaw=$raw;TimeParsed=$match.Success;OffsetSeconds=$offset}
    } $checks
}

function Get-B5VisibleWslDistros {
    $oldPreference=$ErrorActionPreference
    try{
        $ErrorActionPreference='Continue'
        $output=@(wsl.exe --list --quiet 2>$null)
        $exitCode=$LASTEXITCODE
    }finally{$ErrorActionPreference=$oldPreference}
    if($exitCode-ne0){return @()}
    return @($output|ForEach-Object{($_-replace"`0",'').Trim()}|Where-Object{-not[string]::IsNullOrWhiteSpace($_)})
}

function Get-B5RegisteredWslDistros {
    $items=New-Object System.Collections.Generic.List[object]
    foreach($sidKey in @(Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue)){
        $lxss=Join-Path $sidKey.PSPath 'Software\Microsoft\Windows\CurrentVersion\Lxss'
        foreach($distroKey in @(Get-ChildItem $lxss -ErrorAction SilentlyContinue)){
            $p=Get-ItemProperty $distroKey.PSPath -ErrorAction SilentlyContinue
            if($p.DistributionName){$items.Add([pscustomobject]@{Sid=$sidKey.PSChildName;DistributionName=[string]$p.DistributionName})}
        }
    }
    return $items.ToArray()
}

function Get-B5ProjectFileText { param([string]$RelativePath)
    if(@(Get-B5VisibleWslDistros).Count-gt0){
        return ConvertTo-B5Text @(wsl.exe -e sh -lc ("cat ~/ansible-b5/"+$RelativePath.Replace('\','/')) 2>&1)
    }
    $path=Join-Path 'C:\Skills\B5\ansible-b5-export' $RelativePath
    if(Test-Path $path -PathType Leaf){return Get-Content $path -Raw -ErrorAction Stop}
    throw "Проект Ansible недоступен текущей учётной записи WSL и отсутствует export-файл: $path"
}

function Get-B5ReportText { param([string]$HostName)
    return Get-B5ProjectFileText "reports\$HostName\b5-evidence.txt"
}

function Get-B5ProjectListing {
    if(@(Get-B5VisibleWslDistros).Count-gt0){return @(wsl.exe -e sh -lc "find ~/ansible-b5 -maxdepth 3 -printf '%P\n' | sort" 2>&1)}
    $root='C:\Skills\B5\ansible-b5-export'
    if(-not(Test-Path $root -PathType Container)){throw "Не найден $root"}
    return @(Get-ChildItem $root -Recurse -Force|ForEach-Object{$_.FullName.Substring($root.Length+1).Replace('\','/')})
}

function Test-B5AnsibleConnectivity {
    $targets=@('SHA-DC01','BJ-DC02','SHA-FS01','BJ-SRV01','BJ-CL01')
    $checks=@((New-B5Check 'Connectivity playbook uses win_ping' 'ansible.windows.win_ping or win_ping' {param($t,$v)$t-match'(?m)^PLAYBOOK=.*(?:ansible\.windows\.)?win_ping'}))
    foreach($target in $targets){$x=$target;$checks+=New-B5Check "Direct WSMan validation $x" 'Test-WSMan succeeds' {param($t,$v)$t-match("WSMAN="+[regex]::Escape($x)+";SUCCESS=True")}.GetNewClosure()}
    Invoke-B5Checks 'Read 01-connectivity.yml and independently Test-WSMan all targets' {
        "PLAYBOOK=$(Get-B5ProjectFileText 'playbooks\01-connectivity.yml')"
        foreach($target in $targets){try{Test-WSMan $target -ErrorAction Stop|Out-Null;$ok=$true}catch{$ok=$false};"WSMAN=$target;SUCCESS=$ok"}
    } $checks
}

function Test-B5AnsibleReports {
    $hosts=@('SHA-DC01','BJ-DC02','SHA-FS01','BJ-SRV01','BJ-CL01')
    $checks=New-Object System.Collections.Generic.List[object]
    foreach($hostName in $hosts){$x=$hostName;$checks.Add((New-B5Check "$x report exists/non-empty" 'at least 100 bytes' {param($t,$v)$t-match("REPORT="+[regex]::Escape($x)+";SIZE=([1-9][0-9]{2,});")}.GetNewClosure()))}
    $checks.Add((New-B5Check 'Reports differ by host' 'five distinct SHA-256 hashes' {param($t,$v)$hashes=[regex]::Matches($t,'HASH=([0-9a-f]{64})')|ForEach-Object{$_.Groups[1].Value}|Sort-Object -Unique;@($hashes).Count-eq5}))
    $checks.Add((New-B5Check 'Evidence playbook generates/fetches reports' '07 playbook contains evidence generation and fetch' {param($t,$v)$t-match'(?s)PLAYBOOK07=.*(win_shell|win_command|win_copy|template).*fetch'}))
    Invoke-B5Checks 'Report sizes/timestamps/hashes and playbook 07 content' {
        foreach($hostName in $hosts){try{$content=Get-B5ReportText $hostName;$bytes=[Text.Encoding]::UTF8.GetBytes($content);$sha=[Security.Cryptography.SHA256]::Create();$hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant();"REPORT=$hostName;SIZE=$($bytes.Length);HASH=$hash"}catch{"REPORT=$hostName;SIZE=0;MISSING=True"}}
        "PLAYBOOK07=$(Get-B5ProjectFileText 'playbooks\07-collect-evidence.yml')"
    } $checks.ToArray()
}

function Test-B5RoleReports {
    $required=[ordered]@{
        'SHA-DC01'=@('AD DS|Get-AD|Domain','DNS','Site','LAPS');'BJ-DC02'=@('AD DS|Get-AD|Domain','DNS','LAPS')
        'SHA-FS01'=@('local admin|Administrators','WinRM','firewall','LAPS','gMSA|ServiceAccount')
        'BJ-SRV01'=@('local admin|Administrators','WinRM','firewall','LAPS','gMSA|ServiceAccount','BitLocker')
        'BJ-CL01'=@('AppLocker','LAPS','WinRM')
    }
    $checks=New-Object System.Collections.Generic.List[object]
    foreach($hostName in $required.Keys){foreach($term in $required[$hostName]){$h=$hostName;$x=$term;$checks.Add((New-B5Check "$h evidence: $x" $x {param($t,$v)$t-match("(?im)^HOST="+[regex]::Escape($h)+";.*(?:"+$x+")")}.GetNewClosure()))}}
    Invoke-B5Checks 'Prefix every host report line and verify role-specific evidence' {
        foreach($hostName in $required.Keys){try{$content=Get-B5ReportText $hostName;($content-split"`r?`n")|ForEach-Object{"HOST=$hostName;$_"}}catch{"HOST=$hostName;MISSING"}}
    } $checks.ToArray()
}

function Test-B5Submission {
    $files=@('B5-foundation.ps1','B5-transport-dmz.ps1','B5-ad-sites.ps1','B5-ad-objects.ps1','B5-gpo-baseline.ps1','B5-laps.ps1','B5-applocker.ps1','B5-bitlocker.ps1','B5-gmsa.ps1')
    $checks=foreach($name in $files){$x=$name;New-B5Check "$x exists/non-empty" 'non-empty file' {param($t,$v)@($v|Where-Object{$_.Name-eq$x-and-not$_.IsDirectory-and$_.Length-gt0}).Count-eq1}.GetNewClosure()}
    $checks+=@(
        (New-B5Check 'Ansible export directory' 'ansible-b5-export directory exists' {param($t,$v)@($v|Where-Object{$_.Name-eq'ansible-b5-export'-and$_.IsDirectory}).Count-eq1}),
        (New-B5Check 'Exported ansible.cfg' 'non-empty' {param($t,$v)@($v|Where-Object{$_.RelativePath-eq'ansible-b5-export\ansible.cfg'-and$_.Length-gt0}).Count-eq1}),
        (New-B5Check 'Exported inventory.yml' 'non-empty' {param($t,$v)@($v|Where-Object{$_.RelativePath-eq'ansible-b5-export\inventory.yml'-and$_.Length-gt0}).Count-eq1}),
        (New-B5Check 'Exported playbooks' 'at least seven YAML files' {param($t,$v)@($v|Where-Object{$_.RelativePath-like'ansible-b5-export\playbooks\*.yml'-and$_.Length-gt0}).Count-ge7})
    )
    Invoke-B5Checks 'Required local scripts and non-empty Ansible export' {
        $root='C:\Skills\B5'
        Get-ChildItem $root -Recurse -Force|ForEach-Object{[pscustomobject]@{Name=$_.Name;IsDirectory=$_.PSIsContainer;Length=if($_.PSIsContainer){0}else{$_.Length};RelativePath=$_.FullName.Substring($root.Length+1)}}
    } @($checks)
}

function Test-B5AppLockerGpo {
    $group=Get-ADGroup GG_B5_AppLocker_TestUsers
    $sid=[regex]::Escape([string]$group.SID)
    $denyRule=('(?s)UserOrGroupSid="{0}"[^>]+Action="Deny".*?B5Blocked' -f $sid)
    $checks=@(
        (New-B5Check 'Default Windows allow rule' '%WINDIR%\*' {param($t,$v)$t-match'(?i)%WINDIR%\\\*|%OSDRIVE%\\Windows\\\*'}),
        (New-B5Check 'Default Program Files allow rule' '%PROGRAMFILES%\*' {param($t,$v)$t-match'(?i)%PROGRAMFILES%\\\*'}),
        (New-B5Check 'Local Administrators allow rule' 'S-1-5-32-544 Allow' {param($t,$v)$t-match'(?s)UserOrGroupSid="S-1-5-32-544"[^>]+Action="Allow"'}),
        (New-B5Check 'Executable deny rule for test group/path' 'Exe + group SID + C:\B5Blocked\* + Deny' {param($t,$v)$segment=[regex]::Match($t,'(?s)<RuleCollection[^>]+Type="Exe".*?</RuleCollection>').Value;$segment-match$denyRule}.GetNewClosure()),
        (New-B5Check 'Script deny rule for test group/path' 'Script + group SID + C:\B5Blocked\* + Deny' {param($t,$v)$segment=[regex]::Match($t,'(?s)<RuleCollection[^>]+Type="Script".*?</RuleCollection>').Value;$segment-match$denyRule}.GetNewClosure())
    )
    Invoke-B5Checks 'Resolve test-group SID and inspect AppLocker GPO XML' {Get-GPOReport B5-AppLocker-Workstations -ReportType Xml} $checks
}

function Test-B5DhcpRelay { param([string]$ClientGateway,[string]$Server)
    $checks=@(
        (New-B5Check 'RemoteAccess feature installed' 'Installed' {param($t,$v)(@($v.Features|Where-Object Name -eq 'RemoteAccess')).InstallState-eq'Installed'}),
        (New-B5Check 'Routing feature installed' 'Installed' {param($t,$v)(@($v.Features|Where-Object Name -eq 'Routing')).InstallState-eq'Installed'}),
        (New-B5Check 'RemoteAccess service running' 'Running' {param($t,$v)$v.Service.Status-eq'Running'}),
        (New-B5Check 'Client relay interface identified' $ClientGateway {param($t,$v)$v.ClientInterface}),
        (New-B5Check 'Relay interface configured' 'client interface appears in relay configuration' {param($t,$v)$v.Netsh-match[regex]::Escape([string]$v.ClientInterface)}),
        (New-B5Check 'Relay server configured' $Server {param($t,$v)$v.Netsh-match[regex]::Escape($Server)}.GetNewClosure())
    )
    $collect={
        $address=Get-NetIPAddress -AddressFamily IPv4 -IPAddress $ClientGateway -ErrorAction Stop|Select-Object -First 1
        $netsh=@(netsh.exe routing ip relay show global 2>&1;netsh.exe routing ip relay show interface 2>&1)|Out-String
        [pscustomobject]@{Features=@(Get-WindowsFeature RemoteAccess,Routing);Service=Get-Service RemoteAccess;ClientInterface=$address.InterfaceAlias;Netsh=$netsh}
    }.GetNewClosure()
    Invoke-B5Checks 'Typed RRAS feature/service/interface/server validation' $collect $checks
}

function Test-B5DomainMembers {
    $hosts=@('SHA-FS01','BJ-SRV01','SHA-CL01','BJ-CL01')
    $checks=New-Object System.Collections.Generic.List[object]
    foreach($hostName in $hosts){$x=$hostName;$checks.Add((New-B5Check "$x enabled AD computer" 'Enabled=True' {param($t,$v)$h=@($v|Where-Object Host -eq $x)[0];$h-and$h.AdEnabled}.GetNewClosure()));$checks.Add((New-B5Check "$x secure channel" 'nltest status 0' {param($t,$v)$h=@($v|Where-Object Host -eq $x)[0];$h-and$h.SecureChannel}.GetNewClosure()))}
    Invoke-B5Checks 'AD computer state and remote nltest secure-channel query' {
        foreach($hostName in $hosts){$ad=Get-ADComputer $hostName -Properties Enabled;nltest.exe "/server:$hostName" /sc_query:nb-b5.local 2>&1|Out-Null;$code=$LASTEXITCODE;[pscustomobject]@{Host=$hostName;AdEnabled=$ad.Enabled;SecureChannel=($code-eq0);NltestExitCode=$code}}
    } $checks.ToArray()
}

function Test-B5LocalAdmins { param([string]$RequiredGroup)
    $required=@('Domain Admins',$RequiredGroup); $forbidden=@('user.sh01','user.bj01','laps.reader1','ansible.op1')
    $checks=@(foreach($name in $required){$x=$name;New-B5Check "Member $x" $x {param($t,$v)$t-match[regex]::Escape($x)}.GetNewClosure()})
    $checks+=@(foreach($name in $forbidden){$x=$name;New-B5Check "Not administrator: $x" 'absent' {param($t,$v)$t-notmatch[regex]::Escape($x)}.GetNewClosure()})
    Invoke-B5Checks 'Get-LocalGroupMember Administrators' {Get-LocalGroupMember Administrators|Select Name,ObjectClass,PrincipalSource} @($checks)
}

function Test-B5DhcpClient { param([string]$Prefix,[int]$Min,[int]$Max,[string]$Gateway,[string[]]$Dns)
    $dnsOrder=$Dns-join','
    $checks=@(
        (New-B5Check 'DHCP enabled' 'DHCP=True' {param($t,$v)$t-match'DHCP=True'}),
        (New-B5Check 'Lease address' "$Prefix.$Min-$Max" {param($t,$v)$m=[regex]::Match($t,'IP='+[regex]::Escape($Prefix)+'\.(\d+);');$m.Success-and[int]$m.Groups[1].Value-ge$Min-and[int]$m.Groups[1].Value-le$Max}.GetNewClosure()),
        (New-B5Check 'Prefix length' '/24' {param($t,$v)$t-match'PREFIX=24'}),
        (New-B5Check 'Gateway' $Gateway {param($t,$v)$t-match('GW='+[regex]::Escape($Gateway)+';')}.GetNewClosure()),
        (New-B5Check 'DNS order' $dnsOrder {param($t,$v)$t-match('DNS_ORDER='+[regex]::Escape($dnsOrder)+';')}.GetNewClosure()),
        (New-B5Check 'DNS suffix' 'nb-b5.local' {param($t,$v)$t-match'DNS_SUFFIX=nb-b5\.local;'})
    )
    Invoke-B5Checks 'Active adapter DHCP lease, gateway, ordered DNS and suffix' {
        $defaultRoute=Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0'|Sort-Object RouteMetric|Select-Object -First 1
        $active=Get-NetIPConfiguration -InterfaceIndex $defaultRoute.InterfaceIndex
        $nic=Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "InterfaceIndex=$($active.InterfaceIndex)"
        $dns=Get-DnsClientServerAddress -InterfaceIndex $active.InterfaceIndex -AddressFamily IPv4
        "DHCP=$($nic.DHCPEnabled);IP=$($active.IPv4Address.IPAddress);PREFIX=$($active.IPv4Address.PrefixLength);GW=$($active.IPv4DefaultGateway.NextHop);DNS_ORDER=$($dns.ServerAddresses-join',');DNS_SUFFIX=$($nic.DNSDomain);"
    } $checks
}

function Test-B5FileTerms { param([string[]]$Paths,[string[]]$Terms)
    $checks=@(foreach($path in $Paths){$x=$path;New-B5Check "File $x" 'exists and non-empty' {param($t,$v)(Test-Path $x)-and(Get-Item $x).Length-gt0}.GetNewClosure()})
    foreach($term in $Terms){$x=$term;$checks+=@(New-B5Check "Evidence term: $x" $x {param($t,$v)$t-match[regex]::Escape($x)}.GetNewClosure())}
    Invoke-B5Checks ('Get-Content '+($Paths-join',')) {foreach($p in $Paths){if(Test-Path $p){"FILE=$p";Get-Content $p -Raw}}} $checks
}

function Test-B5AnsibleEvidence { param([string[]]$Paths,[string[]]$Terms)
    Test-B5FileTerms $Paths $Terms
}

function New-B5ManualResult { param([string]$Message)
    Write-B5Log "[WARN] Требуется экспертное подтверждение: $Message" Yellow
    [pscustomobject]@{Status='WARN';Passed=0;Total=0;Message=$Message}
}

function Invoke-B5Aspect {
    param([string]$HostKey,[object]$Aspect)
    $id=[string]$Aspect.AspectID
    switch($id) {
        'A-ISP-SHA01-01' {return Test-B5Network ISP-SHA01 @('198.18.200.1/24','198.18.150.1/24','203.0.113.18/30') '' -Workgroup -Forwarding}
        'A-ISP-SHA01-02' {return Test-B5Routes ([ordered]@{'10.25.10.0/24'='198.18.150.10';'10.25.20.0/24'='198.18.150.10';'10.25.30.0/24'='198.18.150.10';'10.35.20.0/24'='203.0.113.17';'10.35.30.0/24'='203.0.113.17';'198.18.201.0/24'='203.0.113.17'})}
        'A-ISP-BJ01-01' {return Test-B5Network ISP-BJ01 @('198.18.201.1/24','198.18.151.1/24','203.0.113.17/30') '' -Workgroup -Forwarding}
        'A-ISP-BJ01-02' {return Test-B5Routes ([ordered]@{'10.35.20.0/24'='198.18.151.10';'10.35.30.0/24'='198.18.151.10';'10.25.10.0/24'='203.0.113.18';'10.25.20.0/24'='203.0.113.18';'10.25.30.0/24'='203.0.113.18';'198.18.200.0/24'='203.0.113.18'})}
        'A-INET-SRV01-01' {return Test-B5Network INET-SRV01 @('198.18.200.10/24') '198.18.200.1' -Workgroup}
        'A-INET-CL01-01' {return Test-B5Network INET-CL01 @('198.18.201.10/24') '198.18.201.1' -Workgroup}
        'A-SHA-WEB01-01' {return Test-B5Network SHA-WEB01 @('10.25.10.11/24') '10.25.10.1' -Workgroup}
        'A-SHA-APP01-01' {return Test-B5Network SHA-APP01 @('10.25.10.12/24') '10.25.10.1' -Workgroup}
        'A-SHA-RTR01-01' {return Test-B5Network SHA-RTR01 @('198.18.150.10/24','10.25.10.1/24','10.25.20.1/24','10.25.30.1/24') '' -Forwarding}
        'A-SHA-RTR01-02' {return Test-B5Routes ([ordered]@{'10.35.20.0/24'='198.18.150.1';'10.35.30.0/24'='198.18.150.1';'198.18.200.0/24'='198.18.150.1';'198.18.201.0/24'='198.18.150.1'})}
        'A-BJ-RTR01-01' {return Test-B5Network BJ-RTR01 @('198.18.151.10/24','10.35.20.1/24','10.35.30.1/24') '' -Forwarding}
        'A-BJ-RTR01-02' {return Test-B5Routes ([ordered]@{'10.25.10.0/24'='198.18.151.1';'10.25.20.0/24'='198.18.151.1';'10.25.30.0/24'='198.18.151.1';'198.18.200.0/24'='198.18.151.1';'198.18.201.0/24'='198.18.151.1'})}
        {$_-in@('A-INET-SRV01-02','A-SHA-WEB01-02','A-SHA-APP01-02')} {return Test-B5WorkgroupBaseline @('AD-Domain-Services','DNS','DHCP','Web-Server')}
        'A-INET-CL01-02' {return Test-B5WorkgroupBaseline @()}
        'A-SHA-DC01-01' {return Test-B5ReachabilityOrRoute @('10.35.20.10','10.35.30.1','198.18.200.10') '10.25.20.1'}
        'A-BJ-DC02-01' {return Invoke-B5RegexChecks 'Route and first-hop evidence for Shanghai DMZ' {$r=Find-NetRoute -RemoteIPAddress 10.25.10.11 -ErrorAction SilentlyContinue|Select-Object -First 1;"ROUTE=$($r.DestinationPrefix);NEXTHOP=$($r.NextHop)";tracert.exe -d -h 4 -w 500 10.25.10.11 2>&1} ([ordered]@{'Route exists'='ROUTE=.+;NEXTHOP=10\.35\.20\.1';'Path starts through BJ-RTR01'='(?m)^\s*1\s+.*10\.35\.20\.1'})}

        'B-SHA-DC01-01' {return Invoke-B5RegexChecks 'Get-ADDomain; Get-ADForest' {Get-ADDomain;Get-ADForest} ([ordered]@{'DNS domain'='nb-b5\.local';'NetBIOS'='NBB5';'Forest root'='RootDomain\s*:\s*nb-b5\.local'})}
        {$_-in@('B-SHA-DC01-02','B-BJ-DC02-01')} {return Test-B5DcRole $env:COMPUTERNAME}
        'B-SHA-DC01-03' {return Invoke-B5RegexChecks 'Test exact SYSVOL and NETLOGON UNC shares on both DCs' {foreach($dc in 'SHA-DC01','BJ-DC02'){foreach($share in 'SYSVOL','NETLOGON'){"DC=$dc;SHARE=$share;AVAILABLE=$(Test-Path "\\$dc\$share")"}}} ([ordered]@{'SHA SYSVOL'='DC=SHA-DC01;SHARE=SYSVOL;AVAILABLE=True';'SHA NETLOGON'='DC=SHA-DC01;SHARE=NETLOGON;AVAILABLE=True';'BJ SYSVOL'='DC=BJ-DC02;SHARE=SYSVOL;AVAILABLE=True';'BJ NETLOGON'='DC=BJ-DC02;SHARE=NETLOGON;AVAILABLE=True'})}
        'B-SHA-DC01-04' {return Test-B5ReplicationAndTime}
        'B-SHA-DC01-05' {return Invoke-B5RegexChecks 'Get-DnsServerZone nb-b5.local on both DCs' {foreach($dc in 'SHA-DC01','BJ-DC02'){Get-DnsServerZone -ComputerName $dc -Name nb-b5.local|ForEach-Object{"DC=$dc;ZONE=$($_.ZoneName);AD=$($_.IsDsIntegrated)"}}} ([ordered]@{'SHA zone'='DC=SHA-DC01;ZONE=nb-b5.local;AD=True';'BJ zone'='DC=BJ-DC02;ZONE=nb-b5.local;AD=True'})}
        'B-SHA-DC01-06' {return Invoke-B5RegexChecks 'Get-DnsServerZone reverse zones' {Get-DnsServerZone|Select ZoneName,IsReverseLookupZone} ([ordered]@{'10.25.10'='10\.25\.10\.in-addr\.arpa';'10.25.20'='20\.25\.10\.in-addr\.arpa';'10.25.30'='30\.25\.10\.in-addr\.arpa';'10.35.20'='20\.35\.10\.in-addr\.arpa';'10.35.30'='30\.35\.10\.in-addr\.arpa';'198.18.200'='200\.18\.198\.in-addr\.arpa';'198.18.201'='201\.18\.198\.in-addr\.arpa'})}
        'B-SHA-DC01-07' {return Test-B5DnsRecords}
        'B-SHA-DC01-08' {return Invoke-B5RegexChecks 'Resolve CNAMEs and their final targets' {$a=Resolve-DnsName ansible.nb-b5.local;"ANSIBLE_CNAME=$(@($a|Where-Object Type -eq CNAME).NameHost)";"ANSIBLE_IP=$(@($a|Where-Object Type -eq A).IPAddress)";$s=Resolve-DnsName securedata.nb-b5.local;"SECUREDATA_CNAME=$(@($s|Where-Object Type -eq CNAME).NameHost)";"SECUREDATA_IP=$(@($s|Where-Object Type -eq A).IPAddress)"} ([ordered]@{'ansible CNAME'='ANSIBLE_CNAME=sha-cl01\.nb-b5\.local\.?';'ansible target resolves'='ANSIBLE_IP=10\.25\.30\.(12[0-9]|1[3-9][0-9]|200)';'securedata CNAME'='SECUREDATA_CNAME=bj-srv01\.nb-b5\.local\.?';'securedata target resolves'='SECUREDATA_IP=10\.35\.20\.20'})}
        'B-SHA-DC01-09' {return Invoke-B5RegexChecks 'Exact forward and reverse resolution' {$f=Resolve-DnsName bj-dc02.nb-b5.local -Type A;"FORWARD=$($f.IPAddress)";$r=Resolve-DnsName 10.35.20.20 -Type PTR;"REVERSE=$($r.NameHost)"} ([ordered]@{'Forward'='FORWARD=10\.35\.20\.10';'Reverse'='REVERSE=bj-srv01\.nb-b5\.local\.?'})}
        'B-SHA-DC01-10' {return Test-B5DhcpScope SHA-DC01 '10.25.30.0' 'Shanghai-ClientNet' '10.25.30.1' @('10.25.20.10','10.35.20.10')}
        'B-BJ-DC02-02' {return Test-B5DhcpScope BJ-DC02 '10.35.30.0' 'Beijing-ClientNet' '10.35.30.1' @('10.35.20.10','10.25.20.10')}
        'B-SHA-RTR01-01' {return Test-B5DhcpRelay '10.25.30.1' '10.25.20.10'}
        'B-BJ-RTR01-01' {return Test-B5DhcpRelay '10.35.30.1' '10.35.20.10'}
        'B-SHA-CL01-01' {return Test-B5DhcpClient '10.25.30' 120 200 '10.25.30.1' @('10.25.20.10','10.35.20.10')}
        'B-BJ-CL01-01' {return Test-B5DhcpClient '10.35.30' 120 200 '10.35.30.1' @('10.35.20.10','10.25.20.10')}
        {$_-match'^B-(SHA-DC01|SHA-FS01|BJ-DC02|BJ-SRV01)-DNSCLIENT$'} {$servers=if($id-match'B-(SHA-)'){@('10.25.20.10','10.35.20.10')}else{@('10.35.20.10','10.25.20.10')};return Test-B5DnsClient $servers}
        'B-SHA-DC01-11' {return Test-B5DomainMembers}
        'B-SHA-DC01-12' {return Invoke-B5RegexChecks 'Get-ADComputer required members with DN' {foreach($n in 'SHA-FS01','BJ-SRV01','SHA-CL01','BJ-CL01'){Get-ADComputer $n|ForEach-Object{"$n=$($_.DistinguishedName)"}}} ([ordered]@{'SHA server OU'='SHA-FS01=.*OU=Shanghai,OU=00-Servers';'BJ server OU'='BJ-SRV01=.*OU=Beijing,OU=00-Servers';'SHA client OU'='SHA-CL01=.*OU=Shanghai,OU=10-Workstations';'BJ client OU'='BJ-CL01=.*OU=Beijing,OU=10-Workstations'})}
        'B-SHA-DC01-13' {return Invoke-B5RegexChecks 'Search forbidden AD computer objects' {foreach($n in 'ISP-SHA01','ISP-BJ01','INET-SRV01','INET-CL01','SHA-WEB01','SHA-APP01'){if(Get-ADComputer -Filter "Name -eq '$n'" -ErrorAction SilentlyContinue){"FOUND=$n"}else{"ABSENT=$n"}}} ([ordered]@{'All six absent'='(?s)ABSENT=ISP-SHA01.*ABSENT=ISP-BJ01.*ABSENT=INET-SRV01.*ABSENT=INET-CL01.*ABSENT=SHA-WEB01.*ABSENT=SHA-APP01'}) @('FOUND=')}

        'C-SHA-DC01-01' {return Invoke-B5RegexChecks 'Required AD sites and effective DC placement' {Get-ADReplicationSite -Filter *|ForEach-Object{"SITE=$($_.Name)"};Get-ADDomainController -Filter *|ForEach-Object{"DC=$($_.HostName);SITE=$($_.Site)"}} ([ordered]@{'Shanghai site'='SITE=Shanghai-Site';'Beijing site'='SITE=Beijing-Site';'SHA DC not in default site'='DC=SHA-DC01[^\r\n]*SITE=Shanghai-Site';'BJ DC not in default site'='DC=BJ-DC02[^\r\n]*SITE=Beijing-Site'})}
        'C-SHA-DC01-02' {return Invoke-B5RegexChecks 'Get-ADReplicationSubnet with sites' {Get-ADReplicationSubnet -Filter * -Properties Site|ForEach-Object{"$($_.Name)=$($_.Site)"}} ([ordered]@{'SHA internal'='10\.25\.20\.0/24=.*Shanghai-Site';'SHA client'='10\.25\.30\.0/24=.*Shanghai-Site';'BJ internal'='10\.35\.20\.0/24=.*Beijing-Site';'BJ client'='10\.35\.30\.0/24=.*Beijing-Site'})}
        'C-SHA-DC01-03' {return Invoke-B5RegexChecks 'Exact DC sites and B5 site-link properties' {Get-ADDomainController -Filter *|ForEach-Object{"DC=$($_.HostName);SITE=$($_.Site)"};$link=Get-ADReplicationSiteLink B5-SHA-BJ-Link -Properties Cost,ReplicationFrequencyInMinutes;"LINK=$($link.Name);COST=$($link.Cost);INTERVAL=$($link.ReplicationFrequencyInMinutes);SITES=$($link.SitesIncluded-join',')"} ([ordered]@{'SHA DC site'='DC=SHA-DC01[^\r\n]*SITE=Shanghai-Site';'BJ DC site'='DC=BJ-DC02[^\r\n]*SITE=Beijing-Site';'Exact link settings'='LINK=B5-SHA-BJ-Link;COST=100;INTERVAL=15';'Both sites included'='(?m)^LINK=.*SITES=.*Shanghai-Site.*Beijing-Site|(?m)^LINK=.*SITES=.*Beijing-Site.*Shanghai-Site'})}
        {$_-in@('C-SHA-CL01-01','C-BJ-CL01-01')} {$site=if($id-match'SHA'){'Shanghai-Site'}else{'Beijing-Site'};return Invoke-B5RegexChecks 'nltest /dsgetsite' {nltest.exe /dsgetsite} ([ordered]@{'AD site'=[regex]::Escape($site)})}
        'C-SHA-DC01-04' {return Invoke-B5RegexChecks 'Get exact required OU distinguished names' {Get-ADOrganizationalUnit -Filter *|Select DistinguishedName} ([ordered]@{'Servers'='OU=00-Servers,DC=nb-b5,DC=local';'SHA servers'='OU=Shanghai,OU=00-Servers,DC=nb-b5,DC=local';'BJ servers'='OU=Beijing,OU=00-Servers,DC=nb-b5,DC=local';'Workstations'='OU=10-Workstations,DC=nb-b5,DC=local';'SHA workstations'='OU=Shanghai,OU=10-Workstations,DC=nb-b5,DC=local';'BJ workstations'='OU=Beijing,OU=10-Workstations,DC=nb-b5,DC=local';'Groups'='OU=20-B5-Groups,DC=nb-b5,DC=local';'Users'='OU=30-B5-Users,DC=nb-b5,DC=local';'Service accounts'='OU=40-B5-ServiceAccounts,DC=nb-b5,DC=local';'Automation'='OU=50-B5-Automation,DC=nb-b5,DC=local'})}
        'C-SHA-DC01-05' {return Test-B5AdGroups}
        'C-SHA-DC01-06' {return Test-B5AdUsers}
        {$_-in@('C-SHA-DC01-07','H-SHA-DC01-03')} {return Invoke-B5RegexChecks 'Get-ADGroupMember GG_B5_GMSA_Hosts' {Get-ADGroupMember GG_B5_GMSA_Hosts|ForEach-Object{"NAME=$($_.Name);CLASS=$($_.ObjectClass)"}} ([ordered]@{'SHA-FS01 computer'='NAME=SHA-FS01;CLASS=computer';'BJ-SRV01 computer'='NAME=BJ-SRV01;CLASS=computer'})}
        'C-SHA-DC01-08' {return Invoke-B5RegexChecks 'Get-ADDefaultDomainPasswordPolicy' {Get-ADDefaultDomainPasswordPolicy} ([ordered]@{'Minimum length 10'='MinPasswordLength\s*:\s*10';'Complexity'='ComplexityEnabled\s*:\s*True';'Max age 60'='MaxPasswordAge\s*:\s*60\.00:00:00';'Min age zero'='MinPasswordAge\s*:\s*00:00:00';'Threshold 5'='LockoutThreshold\s*:\s*5';'Duration 15'='LockoutDuration\s*:\s*00:15:00';'Reset 15'='LockoutObservationWindow\s*:\s*00:15:00'})}
        'C-SHA-DC01-09' {return Invoke-B5RegexChecks 'Exact local-admin GPO links and XML settings' {$w='B5-Workstation-Local-Admins';$s='B5-Server-Local-Admins';"WORKSTATION_LINK=$((Get-GPInheritance 'OU=10-Workstations,DC=nb-b5,DC=local').GpoLinks.DisplayName-contains$w)";"SERVER_LINK=$((Get-GPInheritance 'OU=00-Servers,DC=nb-b5,DC=local').GpoLinks.DisplayName-contains$s)";"===WORKSTATION_XML===";Get-GPOReport $w -ReportType Xml;"===SERVER_XML===";Get-GPOReport $s -ReportType Xml} ([ordered]@{'Workstation exact link'='WORKSTATION_LINK=True';'Server exact link'='SERVER_LINK=True';'Workstation group setting'='(?s)===WORKSTATION_XML===.*GG_B5_Workstation_Admins';'Server group setting'='(?s)===SERVER_XML===.*GG_B5_Server_Admins';'Domain Admins setting'='Domain Admins'})}
        'C-BJ-CL01-02' {return Test-B5LocalAdmins GG_B5_Workstation_Admins}
        {$_-in@('C-SHA-FS01-01','C-BJ-SRV01-01')} {return Test-B5LocalAdmins GG_B5_Server_Admins}

        {$_-match'^D-(SHA-DC01|BJ-DC02|SHA-FS01|BJ-SRV01|BJ-CL01)-01$'} {return Test-B5WinRM}
        {$_-match'^D-(SHA-DC01|BJ-DC02|SHA-FS01|BJ-SRV01|BJ-CL01)-02$'} {return Test-B5Firewall}
        'D-SHA-CL01-01' {return Invoke-B5RegexChecks 'Current-context and all-loaded-profile WSL discovery' {$visible=@(Get-B5VisibleWslDistros);$registered=@(Get-B5RegisteredWslDistros);"VISIBLE_COUNT=$($visible.Count);VISIBLE=$($visible-join',');REGISTERED_COUNT=$($registered.Count);REGISTERED=$($registered.DistributionName-join',')";if($visible.Count){wsl.exe -e sh -lc 'ansible --version && python3 --version'}else{"CONTEXT_WARNING=Дистрибутив WSL зарегистрирован у другой Windows-учётной записи; запустите checker из её сеанса."}} ([ordered]@{'Linux WSL distribution registered'='REGISTERED_COUNT=[1-9]|VISIBLE_COUNT=[1-9]';'Distro visible to current checker account'='VISIBLE_COUNT=[1-9]';'Ansible'='ansible.*core';'Python'='Python 3'})}
        'D-SHA-CL01-02' {return Invoke-B5RegexChecks 'List WSL project or mandatory local Ansible export' {Get-B5ProjectListing} ([ordered]@{'ansible.cfg'='ansible.cfg';'inventory'='inventory.yml';'group vars'='group_vars/windows.yml';'playbooks 01-07'='(?s)playbooks/01-.*playbooks/02-.*playbooks/03-.*playbooks/04-.*playbooks/05-.*playbooks/06-.*playbooks/07-';'reports'='reports'})}
        'D-SHA-CL01-03' {return Invoke-B5RegexChecks 'Inventory and sanitized Windows variables from WSL or local export' {$inventory=if(@(Get-B5VisibleWslDistros).Count){ConvertTo-B5Text @(wsl.exe -e sh -lc 'cd ~/ansible-b5 && ansible-inventory --graph' 2>&1)}else{Get-B5ProjectFileText 'inventory.yml'};$vars=Get-B5ProjectFileText 'group_vars\windows.yml';$vars=$vars-replace'(?m)^(\s*ansible_password:).*$','$1 <redacted>';"$inventory`n===VARS===`n$vars"} ([ordered]@{'DC group and members'='(?s)(@domain_controllers|domain_controllers:).*SHA-DC01.*BJ-DC02';'Server group and members'='(?s)(@member_servers|member_servers:).*SHA-FS01.*BJ-SRV01';'Workstations group'='@workstations|workstations:';'BitLocker target'='(?s)(@bitlocker_targets|bitlocker_targets:).*BJ-SRV01';'gMSA targets'='(?s)(@gmsa_targets|gmsa_targets:).*SHA-FS01.*BJ-SRV01';'All Windows group'='@b5_windows|b5_windows:';'NTLM transport'='ansible_winrm_transport:\s*["'']?ntlm';'Port 5985'='ansible_port:\s*5985';'WinRM connection'='ansible_connection:\s*["'']?winrm'})}
        'D-SHA-CL01-04' {return Test-B5AnsibleConnectivity}
        'D-SHA-CL01-05' {return Test-B5AnsibleReports}

        'E-SHA-DC01-01' {return Invoke-B5RegexChecks 'Windows LAPS schema attributes and cmdlets' {$schema=(Get-ADRootDSE).schemaNamingContext;Get-ADObject -SearchBase $schema -LDAPFilter '(|(lDAPDisplayName=msLAPS-Password)(lDAPDisplayName=msLAPS-EncryptedPassword))' -Properties lDAPDisplayName;Get-Command Get-LapsADPassword,Find-LapsADExtendedRights -ErrorAction SilentlyContinue} ([ordered]@{'Windows LAPS schema'='msLAPS-(Encrypted)?Password';'Password cmdlet'='Get-LapsADPassword';'Rights cmdlet'='Find-LapsADExtendedRights'})}
        'E-SHA-DC01-02' {return Invoke-B5RegexChecks 'LAPS GPO XML and exact OU links' {$gpo=Get-GPO -All|Where-Object DisplayName -match 'LAPS'|Select-Object -First 1;"GPO=$($gpo.DisplayName)";foreach($ou in 'OU=00-Servers,DC=nb-b5,DC=local','OU=10-Workstations,DC=nb-b5,DC=local'){$links=(Get-GPInheritance $ou).GpoLinks.DisplayName;"OU=$ou;LINKED=$($links-contains$gpo.DisplayName)"};Get-GPOReport -Guid $gpo.Id -ReportType Xml} ([ordered]@{'LAPS GPO exists'='GPO=.+LAPS';'Servers exact link'='OU=OU=00-Servers,DC=nb-b5,DC=local;LINKED=True';'Workstations exact link'='OU=OU=10-Workstations,DC=nb-b5,DC=local;LINKED=True';'AD backup setting'='(?s)<Name>BackupDirectory</Name>.{0,1000}<Number>2</Number>';'Password length 14'='(?s)<Name>PasswordLength</Name>.{0,1000}<Number>14</Number>';'Password age 7'='(?s)<Name>PasswordAgeDays</Name>.{0,1000}<Number>7</Number>';'Complexity with special characters'='(?s)<Name>PasswordComplexity</Name>.{0,1000}<Number>4</Number>'})}
        'E-SHA-DC01-03' {return Invoke-B5RegexChecks 'Effective LAPS links on Domain Controllers and out-of-scope boundary' {$dcLinks=(Get-GPInheritance 'OU=Domain Controllers,DC=nb-b5,DC=local').InheritedGpoLinks.DisplayName;"DC_LAPS_LINKS=$(@($dcLinks|Where-Object{$_-match'LAPS'})-join',')";foreach($n in 'ISP-SHA01','ISP-BJ01','INET-SRV01','INET-CL01','SHA-WEB01','SHA-APP01'){"AD_OBJECT_$n=$([bool](Get-ADComputer -Filter "Name -eq '$n'" -ErrorAction SilentlyContinue))"}} ([ordered]@{'No effective DC LAPS link'='(?m)^DC_LAPS_LINKS=$';'Out-of-scope hosts absent from AD'='(?s)AD_OBJECT_ISP-SHA01=False.*AD_OBJECT_ISP-BJ01=False.*AD_OBJECT_INET-SRV01=False.*AD_OBJECT_INET-CL01=False.*AD_OBJECT_SHA-WEB01=False.*AD_OBJECT_SHA-APP01=False'})}
        'E-SHA-DC01-04' {return Invoke-B5RegexChecks 'Find-LapsADExtendedRights on both target OUs' {foreach($ou in 'OU=00-Servers,DC=nb-b5,DC=local','OU=10-Workstations,DC=nb-b5,DC=local'){$rights=Find-LapsADExtendedRights -Identity $ou;"OU=$ou;HOLDERS=$($rights.ExtendedRightHolders-join',')"}} ([ordered]@{'Server OU readers'='OU=OU=00-Servers[^\r\n]*GG_B5_LAPS_Readers';'Workstation OU readers'='OU=OU=10-Workstations[^\r\n]*GG_B5_LAPS_Readers'}) @('user\.sh01|user\.bj01')}
        'E-SHA-DC01-05' {return Invoke-B5RegexChecks 'Credential-specific Get-LapsADPassword test (password redacted)' {"IDENTITY=$(whoami.exe)";$result=Get-LapsADPassword BJ-CL01 -AsPlainText;"COMPUTER=$($result.DeviceName);PASSWORD_RETURNED=$(-not[string]::IsNullOrWhiteSpace([string]$result.Password))"} ([ordered]@{'Executed as laps.reader1'='IDENTITY=.*\\laps\.reader1';'Computer'='COMPUTER=BJ-CL01';'Plaintext password returned'='PASSWORD_RETURNED=True'})}
        'E-SHA-DC01-06' {return Invoke-B5RegexChecks 'Verify standard users have no direct, group-derived or explicit LAPS extended right' {$rights=@();foreach($ou in 'OU=00-Servers,DC=nb-b5,DC=local','OU=10-Workstations,DC=nb-b5,DC=local'){$rights+=@(Find-LapsADExtendedRights -Identity $ou).ExtendedRightHolders};foreach($u in 'user.sh01','user.bj01'){$groups=@(Get-ADPrincipalGroupMembership $u|Select-Object -Expand Name);$effective=@($groups|Where-Object{$g=$_;@($rights|Where-Object{$_-match('(?:^|\\)'+[regex]::Escape($g)+'$')}).Count-gt0});$explicit=@($rights|Where-Object{$_-match('(?:^|\\)'+[regex]::Escape($u)+'$')});"USER=$u;EFFECTIVE_HOLDER=$($effective.Count-gt0);EXPLICIT_RIGHT=$($explicit.Count-gt0)"}} ([ordered]@{'user.sh01 denied by rights model'='USER=user\.sh01;EFFECTIVE_HOLDER=False;EXPLICIT_RIGHT=False';'user.bj01 denied by rights model'='USER=user\.bj01;EFFECTIVE_HOLDER=False;EXPLICIT_RIGHT=False'})}
        {$_-in@('E-BJ-CL01-01','E-SHA-FS01-01','E-BJ-SRV01-01')} {return Invoke-B5RegexChecks 'Effective LAPS policy, successful backup event and AD expiration attribute' {$events=Get-WinEvent -LogName 'Microsoft-Windows-LAPS/Operational' -MaxEvents 100 -ErrorAction SilentlyContinue;gpresult.exe /r;$root=[ADSI]'LDAP://RootDSE';$s=New-Object DirectoryServices.DirectorySearcher([ADSI]("LDAP://"+$root.defaultNamingContext));$s.Filter="(&(objectCategory=computer)(sAMAccountName=$env:COMPUTERNAME`$))";$expiration=$s.FindOne().Properties['mslaps-passwordexpirationtime'];"HOST=$env:COMPUTERNAME;EXPIRATION_COUNT=$($expiration.Count)";$events|Select Id,TimeCreated,Message} ([ordered]@{'LAPS GPO applies'='LAPS';'Successful password backup event'='10018';'Password metadata in AD'='EXPIRATION_COUNT=[1-9]'})}
        'E-SHA-CL01-01' {return Invoke-B5RegexChecks 'Read host-specific Ansible LAPS reports via WSL/export fallback' {foreach($h in 'BJ-CL01','SHA-FS01','BJ-SRV01','SHA-DC01'){$content=Get-B5ReportText $h;($content-split"`r?`n")|Where-Object{$_-match'LAPS|Get-LapsADPassword|Find-LapsADExtendedRights'}|ForEach-Object{"HOST=$h;$_"}}} ([ordered]@{'BJ-CL01 LAPS'='(?m)^HOST=BJ-CL01;.*LAPS';'SHA-FS01 LAPS'='(?m)^HOST=SHA-FS01;.*LAPS';'BJ-SRV01 LAPS'='(?m)^HOST=BJ-SRV01;.*LAPS';'Access-right evidence'='(?m)^HOST=SHA-DC01;.*(Find-LapsADExtendedRights|LAPS.*rights)'})}

        'F-SHA-DC01-01' {return Invoke-B5RegexChecks 'Exact AppLocker GPO targeting' {$name='B5-AppLocker-Workstations';$gpo=Get-GPO $name;$workstation=Get-GPInheritance 'OU=10-Workstations,DC=nb-b5,DC=local';$servers=Get-GPInheritance 'OU=00-Servers,DC=nb-b5,DC=local';$root=Get-GPInheritance 'DC=nb-b5,DC=local';"GPO=$($gpo.DisplayName);WORKSTATION_LINK=$($workstation.GpoLinks.DisplayName-contains$name);SERVER_EFFECTIVE=$($servers.InheritedGpoLinks.DisplayName-contains$name);ROOT_LINK=$($root.GpoLinks.DisplayName-contains$name)"} ([ordered]@{'GPO and exact workstation link'='GPO=B5-AppLocker-Workstations;WORKSTATION_LINK=True';'Not effective on servers'='SERVER_EFFECTIVE=False';'Not linked at domain root'='ROOT_LINK=False'})}
        'F-SHA-DC01-02' {return Test-B5AppLockerGpo}
        'F-BJ-CL01-01' {return Invoke-B5RegexChecks 'Effective enforced AppLocker policy and applied GPO' {Get-AppLockerPolicy -Effective -Xml;gpresult.exe /r} ([ordered]@{'Applied GPO'='B5-AppLocker-Workstations';'Executable enforcement'='<RuleCollection[^>]+Type="Exe"[^>]+EnforcementMode="Enforced"';'Script enforcement'='<RuleCollection[^>]+Type="Script"[^>]+EnforcementMode="Enforced"'})}
        'F-SHA-CL01-01' {return Invoke-B5RegexChecks 'Effective AppLocker policy and running Application Identity' {Get-AppLockerPolicy -Effective -Xml;$svc=Get-CimInstance Win32_Service -Filter "Name='AppIDSvc'";"SERVICE=$($svc.State);START=$($svc.StartMode)";gpresult.exe /r} ([ordered]@{'Applied GPO'='B5-AppLocker-Workstations';'Effective rules'='RuleCollection';'Application Identity running'='SERVICE=Running'})}
        'F-BJ-CL01-02' {return Invoke-B5RegexChecks 'Application Identity service state' {$svc=Get-CimInstance Win32_Service -Filter "Name='AppIDSvc'";"STATE=$($svc.State);START=$($svc.StartMode)"} ([ordered]@{'Running'='STATE=Running';'Automatic or policy-controlled start'='START=(Auto|Manual)'})}
        'F-BJ-CL01-03' {return Invoke-B5RegexChecks 'Test required AppLocker files' {@("BLOCKED=$(Test-Path C:\B5Blocked\blocked.cmd)","ALLOWED=$(Test-Path C:\B5Allowed\allowed.cmd)")} ([ordered]@{'Blocked file'='BLOCKED=True';'Allowed file'='ALLOWED=True'})}
        'F-BJ-CL01-04' {return Invoke-B5RegexChecks 'Existing blocked.cmd and AppLocker deny event under user.bj01' {"FILE_EXISTS=$(Test-Path C:\B5Blocked\blocked.cmd -PathType Leaf)";Get-WinEvent -LogName 'Microsoft-Windows-AppLocker/MSI and Script' -MaxEvents 500|Where-Object{$_.Id-in8004,8007,8022-and$_.Message-match'blocked\.cmd|B5Blocked'}|ForEach-Object{$account=try{$_.UserId.Translate([Security.Principal.NTAccount]).Value}catch{[string]$_.UserId};"ID=$($_.Id);USER=$account;MESSAGE=$($_.Message)"}} ([ordered]@{'Blocked file currently exists'='FILE_EXISTS=True';'Deny event ID'='ID=(8004|8007|8022)';'Test identity'='USER=.*\\user\.bj01';'Blocked file event'='blocked\.cmd|B5Blocked'})}
        'F-BJ-CL01-05' {return Invoke-B5RegexChecks 'Existing allowed.cmd and AppLocker allow event under user.bj01' {"FILE_EXISTS=$(Test-Path C:\B5Allowed\allowed.cmd -PathType Leaf)";Get-WinEvent -LogName 'Microsoft-Windows-AppLocker/MSI and Script' -MaxEvents 500|Where-Object{$_.Id-in8002,8005-and$_.Message-match'allowed\.cmd|B5Allowed'}|ForEach-Object{$account=try{$_.UserId.Translate([Security.Principal.NTAccount]).Value}catch{[string]$_.UserId};"ID=$($_.Id);USER=$account;MESSAGE=$($_.Message)"}} ([ordered]@{'Allowed file currently exists'='FILE_EXISTS=True';'Allow event ID'='ID=(8002|8005)';'Test identity'='USER=.*\\user\.bj01';'Allowed file event'='allowed\.cmd|B5Allowed'})}
        'F-SHA-CL01-02' {return Invoke-B5RegexChecks 'Read BJ-CL01 Ansible AppLocker report via WSL/export fallback' {Get-B5ReportText BJ-CL01} ([ordered]@{'Enforcement status'='AppLocker|Enforced';'Blocked functional test'='blocked\.cmd.*(block|deny|8007)|(?:block|deny|8007).*blocked\.cmd';'Allowed functional test'='allowed\.cmd.*(allow|success|8005)|(?:allow|success|8005).*allowed\.cmd'})}

        'G-BJ-SRV01-01' {return Invoke-B5RegexChecks 'Get-Volume E; Get-Disk; Get-Partition' {Get-Volume -DriveLetter E;Get-Partition -DriveLetter E} ([ordered]@{'Drive E'='DriveLetter\s*:\s*E';'NTFS'='NTFS';'Label'='B5DATA'})}
        'G-BJ-SRV01-02' {return Invoke-B5RegexChecks 'Structured Get-BitLockerVolume C,E' {Get-BitLockerVolume -MountPoint C:,E:|ForEach-Object{"MOUNT=$($_.MountPoint);STATUS=$($_.VolumeStatus);PROTECTION=$($_.ProtectionStatus);PERCENT=$($_.EncryptionPercentage)"}} ([ordered]@{'E encrypted'='(?m)^MOUNT=E:;STATUS=(FullyEncrypted|EncryptionInProgress);';'C remains unencrypted'='(?m)^MOUNT=C:;STATUS=FullyDecrypted;'})}
        'G-BJ-SRV01-03' {return Invoke-B5RegexChecks 'Recovery protector and BJ-SRV01 AD recovery object' {$volume=Get-BitLockerVolume E:;$volume.KeyProtector|ForEach-Object{"TYPE=$($_.KeyProtectorType);ID=$($_.KeyProtectorId)"};$root=[ADSI]'LDAP://RootDSE';$s=New-Object DirectoryServices.DirectorySearcher([ADSI]("LDAP://"+$root.defaultNamingContext));$s.Filter='(&(objectCategory=computer)(sAMAccountName=BJ-SRV01$))';$computer=$s.FindOne();$recovery=New-Object DirectoryServices.DirectorySearcher([ADSI]$computer.Path);$recovery.SearchScope='OneLevel';$recovery.Filter='(objectClass=msFVE-RecoveryInformation)';"AD_RECOVERY_COUNT=$($recovery.FindAll().Count)"} ([ordered]@{'Recovery password protector'='TYPE=RecoveryPassword;ID=';'Backed up under BJ-SRV01'='AD_RECOVERY_COUNT=[1-9]'})}
        'G-BJ-SRV01-04' {return Invoke-B5RegexChecks 'Structured E volume status and proof readability' {$v=Get-BitLockerVolume E:;"MOUNT=$($v.MountPoint);STATUS=$($v.VolumeStatus);PROTECTION=$($v.ProtectionStatus);PERCENT=$($v.EncryptionPercentage)";"PROOF=$(Test-Path E:\B5DATA\bitlocker-proof.txt -PathType Leaf)"} ([ordered]@{'Protection on'='PROTECTION=On';'Valid volume status'='STATUS=(FullyEncrypted|EncryptionInProgress)';'Proof readable'='PROOF=True'})}
        'G-BJ-SRV01-05' {return Test-B5FileTerms @('E:\B5DATA\bitlocker-proof.txt') @('B5 BitLocker protected data volume')}
        'G-SHA-CL01-01' {return Invoke-B5RegexChecks 'Read Ansible BitLocker report via WSL/export fallback' {Get-B5ReportText BJ-SRV01} ([ordered]@{'BitLocker evidence'='BitLocker|manage-bde';'E volume'='E:'})}
        'G-SHA-DC01-01' {return Invoke-B5RegexChecks 'Find BJ-SRV01 BitLocker recovery objects' {$c=Get-ADComputer BJ-SRV01;Get-ADObject -Filter 'objectClass -eq "msFVE-RecoveryInformation"' -SearchBase $c.DistinguishedName} ([ordered]@{'Recovery object'='msFVE-RecoveryInformation'})}

        'H-SHA-DC01-01' {return Invoke-B5RegexChecks 'Effective KDS root key' {Get-KdsRootKey|ForEach-Object{"KEY=$($_.KeyId);EFFECTIVE=$($_.EffectiveTime.ToUniversalTime().ToString('o'));USABLE=$($_.EffectiveTime.ToUniversalTime()-le[datetime]::UtcNow)"}} ([ordered]@{'KDS key exists'='KEY=[0-9a-f-]+';'Key effective now'='USABLE=True'})}
        'H-SHA-DC01-02' {return Invoke-B5RegexChecks 'Get-ADServiceAccount gmsa-b5-report' {Get-ADServiceAccount gmsa-b5-report -Properties DistinguishedName,PrincipalsAllowedToRetrieveManagedPassword} ([ordered]@{'gMSA'='gmsa-b5-report';'Service account OU'='OU=40-B5-ServiceAccounts';'Allowed group'='GG_B5_GMSA_Hosts'})}
        {$_-in@('H-SHA-FS01-01','H-BJ-SRV01-01')} {return Invoke-B5RegexChecks 'Test-ADServiceAccount gmsa-b5-report (read-only test)' {"TEST=$(Test-ADServiceAccount gmsa-b5-report)"} ([ordered]@{'gMSA test'='TEST=True'})}
        'H-BJ-SRV01-02' {$today=(Get-Date).ToString('yyyy-MM-dd');return Invoke-B5RegexChecks 'Read scheduled task, last result and current proof without starting it' {$task=Get-ScheduledTask B5-gMSA-Report;$info=Get-ScheduledTaskInfo B5-gMSA-Report;$proof=Get-Item C:\Skills\B5\gmsa-proof.txt;"USER=$($task.Principal.UserId);LAST_RESULT=$($info.LastTaskResult);LAST_RUN=$($info.LastRunTime.ToString('o'));PROOF_DATE=$($proof.LastWriteTime.ToString('yyyy-MM-dd'));TODAY=$today";"CONTENT=$(Get-Content $proof.FullName -Raw)"} ([ordered]@{'Task account'='USER=(NBB5\\)?gmsa-b5-report\$';'Successful last run'='LAST_RESULT=0';'Current proof timestamp'='PROOF_DATE=(\d{4}-\d{2}-\d{2});TODAY=\1';'Hostname in content'='CONTENT=.*BJ-SRV01';'Current date in content'=('CONTENT=(?s:.*)'+[regex]::Escape($today))})}
        'H-SHA-CL01-01' {return Invoke-B5RegexChecks 'Read separate Ansible gMSA reports via WSL/export fallback' {foreach($h in 'SHA-FS01','BJ-SRV01'){$content=Get-B5ReportText $h;($content-split"`r?`n")|ForEach-Object{"HOST=$h;$_"}}} ([ordered]@{'SHA-FS01 report'='(?m)^HOST=SHA-FS01;.*(Test-ADServiceAccount|gmsa-b5-report)';'BJ-SRV01 report'='(?m)^HOST=BJ-SRV01;.*(Test-ADServiceAccount|gmsa-b5-report|B5-gMSA-Report)';'gMSA test'='Test-ADServiceAccount|gmsa-b5-report'})}

        'I-INET-CL01-01' {return Test-B5TcpSet @('10.25.20.10','10.35.20.10','10.25.20.20','10.35.20.20') @(5985) $false}
        'I-INET-CL01-02' {return Test-B5TcpSet @('10.25.10.11','10.25.10.12') @(5985,445) $false}
        'I-SHA-CL01-01' {return Test-B5WsManSet @('SHA-DC01','BJ-DC02','SHA-FS01','BJ-SRV01','BJ-CL01')}
        'I-INET-SRV01-01' {return Invoke-B5RegexChecks 'Route table and gateway reachability' {Get-NetRoute -DestinationPrefix 0.0.0.0/0;Test-NetConnection 198.18.200.1 -InformationLevel Detailed} ([ordered]@{'Default gateway'='198\.18\.200\.1';'Gateway reachable'='PingSucceeded\s*:\s*True|TcpTestSucceeded\s*:\s*True'})}
        'I-SHA-CL01-02' {return Test-B5FileTerms @('C:\Skills\B5\B5-validation.txt') @('Test-WSMan','INET-CL01','5985','10.25.20.10','10.35.20.10','10.25.20.20','10.35.20.20','10.25.10.11','10.25.10.12','445')}

        'J-SHA-CL01-01' {return Invoke-B5RegexChecks 'Read managed-by-ansible.txt remotely on five hosts' {foreach($h in 'SHA-DC01','BJ-DC02','SHA-FS01','BJ-SRV01','BJ-CL01'){Invoke-Command $h {Get-Content C:\Skills\B5\managed-by-ansible.txt -Raw}|ForEach-Object{"HOST=$h $_"}}} ([ordered]@{'SHA-DC01'='HOST=SHA-DC01.*managed by Ansible for B5';'BJ-DC02'='HOST=BJ-DC02.*managed by Ansible for B5';'SHA-FS01'='HOST=SHA-FS01.*managed by Ansible for B5';'BJ-SRV01'='HOST=BJ-SRV01.*managed by Ansible for B5';'BJ-CL01'='HOST=BJ-CL01.*managed by Ansible for B5'})}
        'J-SHA-CL01-02' {return Test-B5RoleReports}
        'J-SHA-CL01-03' {return Test-B5Submission}
        'J-SHA-CL01-04' {return Test-B5FileTerms @('C:\Skills\B5\B5-validation.txt') @('Ansible','transport','DMZ','LAPS','AppLocker','BitLocker','gMSA','external','known')}
    }
    return New-B5ManualResult "Для аспекта $id автоматический evaluator не определён."
}

function Write-B5Summary {
    $max=(@($script:B5Rows|Measure-Object MaxMark -Sum).Sum); $award=(@($script:B5Rows|Measure-Object Awarded -Sum).Sum); $counts=@{}
    foreach($s in 'PASS','PART','FAIL','WARN'){$counts[$s]=@($script:B5Rows|Where-Object Status -eq $s).Count}
    $lines=@('B5 Local Evaluation Summary','===========================',"Awarded: $([Math]::Round($award,3)) / $([Math]::Round($max,3))","PASS=$($counts.PASS); PART=$($counts.PART); FAIL=$($counts.FAIL); WARN=$($counts.WARN)",'Итог относится к критериям текущей точки проверки.')
    Write-Host '';Write-B5Log ($lines-join[Environment]::NewLine) DarkGray
    if($script:B5Report){Set-Content $script:B5SummaryPath ($lines-join[Environment]::NewLine) -Encoding UTF8}
}

function Invoke-B5HostChecks {
    param([Parameter(Mandatory=$true)][string]$HostKey,[switch]$Report,[string]$ReportDir,[switch]$NoPause,[string]$StartFromAspect)
    $HostKey=$HostKey.ToUpperInvariant();$script:B5Pause=-not$NoPause;Initialize-B5Report $HostKey -Report:$Report -ReportDir $ReportDir
    Write-B5Log ('#'*86) Magenta;Write-B5Log "B5 local checks for $HostKey" Magenta;Write-B5Log "B5 checker version: $script:B5Version" Green
    $criteria=@(Get-B5Criteria $HostKey);if($criteria.Count-eq0){throw "Для $HostKey нет критериев B5."}
    foreach($aspect in $criteria){if($StartFromAspect-and[string]::Compare($aspect.AspectID,$StartFromAspect,$true)-lt0){continue};Start-B5Aspect $aspect;try{$result=Invoke-B5Aspect $HostKey $aspect}catch{$result=New-B5ManualResult "Ошибка evaluator: $($_.Exception.Message)"};Complete-B5Aspect $aspect $result}
    Write-B5Summary
}

