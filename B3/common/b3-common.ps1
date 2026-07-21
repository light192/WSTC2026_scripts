Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:B3Root = Split-Path -Parent $PSScriptRoot
$script:B3CriteriaPath = Join-Path $script:B3Root 'criteria\b3_device_criteria_map.tsv'
$script:B3PauseBetweenChecks = $true
$script:B3ReportEnabled = $false
$script:B3Rows = @()
$script:B3Version = '2026-07-21.2'

function ConvertTo-B3Text {
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

function Select-B3RelevantOutput {
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

function Write-B3Log {
    param([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    Write-Host $Text -ForegroundColor $Color
    if (-not $script:B3ReportEnabled) { return }
    try {
        Add-Content -LiteralPath $script:B3DetailPath -Value $Text -Encoding UTF8
    } catch {
        Write-Host "[WARN] Не удалось записать лог: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Write-B3Section {
    param([string]$Text)
    Write-Host ''
    Write-B3Log '######################################################################################' Magenta
    Write-B3Log $Text Magenta
    Write-B3Log '######################################################################################' Magenta
    Write-Host ''
}

function Initialize-B3Report {
    param([string]$HostKey, [switch]$Report, [string]$ReportDir)
    $script:B3Rows = @()
    $script:B3ReportEnabled = $false
    if (-not $Report -and [string]::IsNullOrWhiteSpace($ReportDir)) { return }

    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($ReportDir)) { $candidates.Add($ReportDir) }
    $candidates.Add((Join-Path $script:B3Root "reports\$HostKey"))
    $candidates.Add((Join-Path $env:TEMP "B3-reports\$HostKey"))
    $lastError = ''
    foreach ($candidate in $candidates) {
        try {
            New-Item -ItemType Directory -Path $candidate -Force | Out-Null
            $script:B3ReportDir = $candidate
            $script:B3ResultsPath = Join-Path $candidate 'b3-results.tsv'
            $script:B3DetailPath = Join-Path $candidate 'b3-detail.log'
            $script:B3SummaryPath = Join-Path $candidate 'b3-summary.txt'
            Set-Content -LiteralPath $script:B3ResultsPath -Value "AspectID`tOriginalAspectID`tGroupID`tHostKey`tMaxMark`tStatus`tMessage" -Encoding UTF8
            Set-Content -LiteralPath $script:B3DetailPath -Value '' -Encoding UTF8
            $script:B3ReportEnabled = $true
            return
        } catch {
            $lastError = $_.Exception.Message
        }
    }
    throw "Не удалось создать отчет: $lastError"
}

function Get-B3Criteria {
    param([string]$HostKey)
    if (-not (Test-Path -LiteralPath $script:B3CriteriaPath)) {
        throw "Не найдена карта критериев: $script:B3CriteriaPath"
    }
    return @(Import-Csv -LiteralPath $script:B3CriteriaPath -Delimiter "`t" -Encoding UTF8 |
        Where-Object { $_.HostKey -eq $HostKey } |
        Sort-Object AspectID)
}

function Start-B3Aspect {
    param([object]$Aspect)
    Write-Host ''
    Write-B3Log "[$($Aspect.AspectID)] $($Aspect.Description)" Yellow
    if ($Aspect.PSObject.Properties.Name -contains 'OriginalAspectID' -and
        -not [string]::IsNullOrWhiteSpace($Aspect.OriginalAspectID)) {
        Write-B3Log "Исходный аспект marking scheme: $($Aspect.OriginalAspectID)" DarkYellow
    }
    Write-B3Log "Команды из marking scheme: $($Aspect.VerificationCommands)" Cyan
    $manualId = if ($Aspect.PSObject.Properties.Name -contains 'OriginalAspectID' -and -not [string]::IsNullOrWhiteSpace($Aspect.OriginalAspectID)) { $Aspect.OriginalAspectID } else { $Aspect.AspectID }
    $manualCommand = Get-B3ManualCommand -AspectID $manualId
    Write-B3Log 'Полная команда для ручной проверки (можно скопировать):' Green
    Write-B3Log $manualCommand DarkGreen
    Write-B3Log "Краткий ожидаемый результат: $($Aspect.ExpectedResult)" DarkCyan
    if ($Aspect.PSObject.Properties.Name -contains 'ExpectedAttributes' -and
        -not [string]::IsNullOrWhiteSpace($Aspect.ExpectedAttributes)) {
        Write-B3Log 'Точные ожидаемые свойства и значения:' Cyan
        Write-B3Log $Aspect.ExpectedAttributes Cyan
    }
}

function Get-B3ManualCommand {
 param([string]$AspectID)
 switch($AspectID){
  'A1.01'{return "hostname; 'SHA-DC01','SHA-FS01','SHA-CL01','BJ-DC02','BJ-SRV01','BJ-CL01' | ForEach-Object { Get-ADComputer `$_ | Select-Object Name,DNSHostName }; 'SHA-RTR01','BJ-RTR01' | ForEach-Object { Resolve-DnsName (`$_ + '.nb-b3.local') }"}
  'A1.02'{return "Get-NetIPAddress -AddressFamily IPv4 | Sort-Object IPAddress | Format-Table InterfaceAlias,IPAddress,PrefixLength -AutoSize"}
  'A1.03'{return "Get-NetIPConfiguration | Format-List InterfaceAlias,IPv4Address,IPv4DefaultGateway,DNSServer; Get-DnsClientServerAddress -AddressFamily IPv4 | Format-Table InterfaceAlias,ServerAddresses -AutoSize"}
  'A1.04'{return "Get-NetIPInterface -AddressFamily IPv4 | Format-Table InterfaceAlias,Forwarding,ConnectionState -AutoSize; Get-NetRoute -AddressFamily IPv4 | Where-Object { `$_.DestinationPrefix -in '10.33.20.0/24','10.33.30.0/24','198.18.200.0/24','198.18.201.0/24' } | Format-Table DestinationPrefix,NextHop,InterfaceAlias -AutoSize"}
  'A1.05'{return "Get-NetIPInterface -AddressFamily IPv4 | Format-Table InterfaceAlias,Forwarding,ConnectionState -AutoSize; Get-NetRoute -AddressFamily IPv4 | Where-Object { `$_.DestinationPrefix -in '10.23.10.0/24','10.23.20.0/24','10.23.30.0/24','198.18.200.0/24','198.18.201.0/24' } | Format-Table DestinationPrefix,NextHop,InterfaceAlias -AutoSize"}
  'A1.06'{return "Get-ADDomain | Format-List DNSRoot,NetBIOSName,DistinguishedName; Get-ADForest | Format-List Name,RootDomain; Get-ADDomainController -Identity SHA-DC01 | Format-List HostName,Site,IsGlobalCatalog,IPv4Address"}
  'A1.07'{return "Get-ADDomainController -Identity BJ-DC02 | Format-List HostName,Site,IsGlobalCatalog; repadmin /replsummary; Get-SmbShare -Name SYSVOL,NETLOGON | Format-Table Name,Path -AutoSize"}
  'A1.08'{return "Get-DnsServerZone | Sort-Object ZoneName | Format-Table ZoneName,ZoneType,IsDsIntegrated,ReplicationScope -AutoSize"}
  'A1.09'{return "'sha-rtr01','sha-dc01','sha-fs01','bj-rtr01','bj-dc02','bj-srv01','files','branch-files' | ForEach-Object { Resolve-DnsName (`$_ + '.nb-b3.local') -ErrorAction Continue | Format-Table Name,Type,IPAddress,NameHost -AutoSize }"}
  'A1.10'{return "'10.23.10.1','10.23.20.1','10.23.20.10','10.23.20.20','10.33.20.1','10.33.20.10','10.33.20.20','198.18.120.10','198.18.121.10' | ForEach-Object { Resolve-DnsName `$_ -ErrorAction Continue | Format-Table Name,Type,NameHost -AutoSize }"}
  'A1.11'{return "Get-DhcpServerv4Scope -ScopeId 10.23.30.0 | Format-List *; Get-DhcpServerv4ExclusionRange -ScopeId 10.23.30.0; Get-DhcpServerv4OptionValue -ScopeId 10.23.30.0"}
  'A1.12'{return "Get-DhcpServerv4Scope -ScopeId 10.33.30.0 | Format-List *; Get-DhcpServerv4ExclusionRange -ScopeId 10.33.30.0; Get-DhcpServerv4OptionValue -ScopeId 10.33.30.0"}
  'A1.13'{return "Get-DhcpServerInDC | Format-Table DnsName,IPAddress -AutoSize; ipconfig /all"}
  'A1.14'{return "Get-ADOrganizationalUnit -Filter * | Select-Object Name,DistinguishedName | Sort-Object DistinguishedName; 'SHA-FS01','BJ-SRV01','SHA-CL01','BJ-CL01' | ForEach-Object { Get-ADComputer `$_ -Properties DistinguishedName | Select-Object Name,DistinguishedName }"}
  'A1.15'{return "Get-CimInstance Win32_ComputerSystem | Select-Object Name,Domain,PartOfDomain; 'SHA-FS01','BJ-SRV01','SHA-CL01','BJ-CL01' | ForEach-Object { Get-ADComputer `$_ | Select-Object Name,DNSHostName }"}
  'A1.16'{return "'SHA-FS01','BJ-SRV01','SHA-DC01','BJ-DC02' | ForEach-Object { Test-WSMan `$_ }"}
  'A1.17'{return "'SHA-FS01','BJ-SRV01' | ForEach-Object { Resolve-DnsName `$_; Test-NetConnection `$_ -Port 445 }"}
  'A1.18'{return "Resolve-DnsName sha-fs01.nb-b3.local; 'SHA-FS01','BJ-SRV01' | ForEach-Object { Test-NetConnection `$_ -Port 445 }; Test-Path '\\nb-b3.local\Corp'; 'SHA-FS01','BJ-SRV01','SHA-DC01','BJ-DC02' | ForEach-Object { Test-WSMan `$_ }"}
  'B1.01'{return "Get-Volume -DriveLetter E | Format-List DriveLetter,FileSystemLabel,FileSystem,Size,HealthStatus; Get-Partition -DriveLetter E | Get-Disk | Format-List Number,FriendlyName,BusType,PartitionStyle,Size"}
  'B1.02'{return "Get-Volume -DriveLetter E | Format-List DriveLetter,FileSystemLabel,FileSystem,Size,HealthStatus; Get-Partition -DriveLetter E | Get-Disk | Format-List Number,FriendlyName,BusType,PartitionStyle,Size"}
  'B1.03'{return "Get-Volume -DriveLetter F | Format-List DriveLetter,FileSystemLabel,FileSystem,Size,HealthStatus; Get-Partition -DriveLetter F | Get-Disk | Format-List Number,FriendlyName,BusType,PartitionStyle,Size"}
  'B1.04'{return "'E:\Shares','F:\B3Backup' | ForEach-Object { [pscustomobject]@{Path=`$_;Exists=Test-Path -LiteralPath `$_} } | Format-Table -AutoSize"}
  'B1.05'{return "'C','E','R' | ForEach-Object { `$letter=`$_; `$v=Get-Volume -DriveLetter `$letter -ErrorAction SilentlyContinue; `$p=Get-Partition -DriveLetter `$letter -ErrorAction SilentlyContinue; [pscustomobject]@{Drive=`$letter;Label=`$v.FileSystemLabel;FileSystem=`$v.FileSystem;SizeGB=[math]::Round(`$v.Size/1GB,1);DiskNumber=`$p.DiskNumber} } | Format-Table -AutoSize"}
  'B1.06'{return "Get-WindowsFeature FS-FileServer,FS-DFS-Namespace,FS-DFS-Replication,FS-Resource-Manager,FS-iSCSITarget-Server,Windows-Server-Backup | Format-Table Name,InstallState -AutoSize"}
  'C1.01'{return "Get-ADOrganizationalUnit -Filter * | Where-Object { `$_.Name -in '50-Storage','60-B3-Groups','70-B3-TestUsers' } | Select-Object Name,DistinguishedName"}
  'C1.02'{return "'GG_B3_Common_RW','GG_B3_Common_RO','GG_B3_Shanghai_RW','GG_B3_Beijing_RW','GG_B3_Archive_RW','GG_B3_Archive_RO','GG_B3_Backup_Operators' | ForEach-Object { Get-ADGroup `$_ -Properties GroupScope,GroupCategory | Select-Object Name,GroupScope,GroupCategory }"}
  'C1.03'{return "'storage.sh01','storage.bj01','auditor.b3','backup.op1' | ForEach-Object { Get-ADUser `$_ -Properties Enabled,PasswordNeverExpires,PasswordExpired | Select-Object SamAccountName,Enabled,PasswordNeverExpires,PasswordExpired }"}
  'C1.04'{return "'storage.sh01','storage.bj01' | ForEach-Object { `$u=`$_; Get-ADPrincipalGroupMembership `$u | Select-Object @{n='User';e={`$u}},Name }"}
  'C1.05'{return "'auditor.b3','backup.op1' | ForEach-Object { `$u=`$_; Get-ADPrincipalGroupMembership `$u | Select-Object @{n='User';e={`$u}},Name }"}
  'C1.06'{return "Get-Acl E:\Shares\Common | Format-List; Get-SmbShareAccess -Name Common | Format-Table AccountName,AccessControlType,AccessRight -AutoSize"}
  'C1.07'{return "Get-ADOrganizationalUnit -Filter * | Where-Object { `$_.Name -in '50-Storage','60-B3-Groups','70-B3-TestUsers' }; 'GG_B3_Common_RW','GG_B3_Archive_RW' | ForEach-Object { Get-ADGroup `$_ }; 'storage.sh01','storage.bj01','auditor.b3','backup.op1' | ForEach-Object { Get-ADUser `$_ }"}
  'D1.01'{return "Get-WindowsFeature FS-iSCSITarget-Server; Test-Path E:\iSCSI"}
  'D1.02'{return "Get-IscsiVirtualDisk | Select-Object Path,@{n='SizeGB';e={[math]::Round(`$_.Size/1GB,2)}} | Format-Table -AutoSize"}
  'D1.03'{return "Get-IscsiServerTarget -TargetName B3-Archive-Target | Format-List *"}
  'D1.04'{return "Get-IscsiTarget | Format-List *; Get-IscsiSession | Format-List *"}
  'D1.05'{return "Get-Volume -DriveLetter R | Format-List *; Get-Partition -DriveLetter R | Get-Disk | Format-List Number,BusType,PartitionStyle,Size"}
  'D1.06'{return "Test-Path R:\Archive; Get-Item R:\Archive -ErrorAction SilentlyContinue | Format-List FullName,Attributes"}
  'D1.07'{return "Get-IscsiSession | Format-List *; Test-NetConnection BJ-SRV01 -Port 3260"}
  'D1.08'{return "Get-IscsiServerTarget -TargetName B3-Archive-Target | Select-Object TargetName,InitiatorIds | Format-List"}
  'E1.01'{return "Get-SmbShare -Name Common,Shanghai,Archive | Format-Table Name,Path,FolderEnumerationMode -AutoSize; 'E:\Shares\Common','E:\Shares\Shanghai','R:\Archive' | ForEach-Object { Test-Path `$_ }"}
  'E1.02'{return "Get-SmbShare -Name Common,Beijing,'B3Backup$' | Format-Table Name,Path,FolderEnumerationMode -AutoSize; 'E:\Shares\Common','E:\Shares\Beijing','F:\B3Backup' | ForEach-Object { Test-Path `$_ }"}
  'E1.03'{return "Get-SmbShare -Name Common,Shanghai,Archive | Format-Table Name,Path,FolderEnumerationMode -AutoSize"}
  'E1.04'{return "Get-Acl E:\Shares\Common | Format-List; Get-SmbShareAccess Common | Format-Table AccountName,AccessControlType,AccessRight -AutoSize"}
  'E1.05'{return "Get-Acl E:\Shares\Shanghai | Format-List; Get-SmbShareAccess Shanghai | Format-Table AccountName,AccessControlType,AccessRight -AutoSize"}
  'E1.06'{return "Get-Acl E:\Shares\Beijing | Format-List; Get-SmbShareAccess Beijing | Format-Table AccountName,AccessControlType,AccessRight -AutoSize"}
  'E1.07'{return "Get-Acl R:\Archive | Format-List; Get-SmbShareAccess Archive | Format-Table AccountName,AccessControlType,AccessRight -AutoSize"}
  'E1.08'{return "Get-Acl F:\B3Backup | Format-List; Get-SmbShareAccess 'B3Backup$' | Format-Table AccountName,AccessControlType,AccessRight -AutoSize"}
  'E1.09'{return "Get-SmbShareAccess Common,Beijing,'B3Backup$' | Format-Table Name,AccountName,AccessControlType,AccessRight -AutoSize; Get-Acl E:\Shares\Common,E:\Shares\Beijing,F:\B3Backup | Format-List Path,Access"}
  'E1.10'{return "'SHA-FS01','BJ-SRV01' | ForEach-Object { Test-NetConnection `$_ -Port 445 }"}
  'F1.01'{return "Get-WindowsFeature FS-DFS-Namespace | Format-Table Name,InstallState -AutoSize"}
  'F1.02'{return "Get-DfsnRoot -Path '\\nb-b3.local\Corp' | Format-List *; Get-DfsnRootTarget -Path '\\nb-b3.local\Corp' | Format-Table TargetPath,State -AutoSize"}
  'F1.03'{return "Get-DfsnFolderTarget -Path '\\nb-b3.local\Corp\Common' | Format-Table Path,TargetPath,State -AutoSize"}
  'F1.04'{return "'Shanghai','Beijing','Archive' | ForEach-Object { Get-DfsnFolderTarget -Path ('\\nb-b3.local\Corp\'+`$_) } | Format-Table Path,TargetPath,State -AutoSize"}
  'F1.05'{return "'\\nb-b3.local\Corp','\\nb-b3.local\Corp\Common','\\nb-b3.local\Corp\Shanghai','\\nb-b3.local\Corp\Beijing','\\nb-b3.local\Corp\Archive' | ForEach-Object { [pscustomobject]@{Path=`$_;Accessible=Test-Path `$_} } | Format-Table -AutoSize"}
  'F1.06'{return "Get-SmbShare Archive | Format-List Name,Path,FolderEnumerationMode"}
  'F1.07'{return "Get-DfsnFolder -Path '\\nb-b3.local\Corp\*' | ForEach-Object { Get-DfsnFolderTarget -Path `$_.Path } | Format-Table Path,TargetPath,State -AutoSize"}
  'G1.01'{return "Get-WindowsFeature FS-DFS-Replication | Format-Table Name,InstallState -AutoSize"}
  'G1.02'{return "Get-DfsReplicationGroup -GroupName B3-Common-RG | Format-List *; Get-DfsReplicatedFolder -GroupName B3-Common-RG | Format-List *"}
  'G1.03'{return "Get-DfsrMembership -GroupName B3-Common-RG | Format-Table GroupName,FolderName,ComputerName,ContentPath,PrimaryMember -AutoSize"}
  'G1.04'{return "Get-DfsrConnection -GroupName B3-Common-RG | Format-List *; Get-DfsrMembership -GroupName B3-Common-RG | Format-List *; Get-DfsReplicatedFolder -GroupName B3-Common-RG | Format-List *"}
  'G1.05'{return "Test-Path E:\Shares\Common\B3-DFSR-Test.txt; Get-Content E:\Shares\Common\B3-DFSR-Test.txt -ErrorAction SilentlyContinue"}
  'G1.06'{return "Get-DfsReplicatedFolder | Format-Table GroupName,FolderName -AutoSize"}
  'G1.07'{return "Get-Service DFSR; Get-WinEvent -FilterHashtable @{LogName='DFS Replication';StartTime=(Get-Date).AddHours(-2)} -ErrorAction SilentlyContinue | Where-Object { `$_.LevelDisplayName -eq 'Error' } | Select-Object Id,TimeCreated,Message; Test-Path E:\Shares\Common\B3-DFSR-Test.txt"}
  'H1.01'{return "Get-WindowsFeature FS-Resource-Manager | Format-Table Name,InstallState -AutoSize"}
  'H1.02'{return "Get-FsrmQuotaTemplate -Name B3-Beijing-1GB-Hard | Format-List Name,Size,SoftLimit"}
  'H1.03'{return "Get-FsrmQuota -Path E:\Shares\Beijing | Format-List *"}
  'H1.04'{return "Get-FsrmFileGroup -Name B3-Blocked-Executable-Files | Format-List Name,IncludePattern,ExcludePattern"}
  'H1.05'{return "Get-FsrmFileScreen -Path E:\Shares\Beijing | Format-List *"}
  'H1.06'{return 'runas /user:NBB3\storage.bj01 "powershell -NoProfile -Command ""Set-Content \\BJ-SRV01\Beijing\allowed.txt ok; Set-Content \\BJ-SRV01\Beijing\blocked.exe blocked"""'}
  'I1.01'{return "vssadmin list shadowstorage /for=E:"}
  'I1.02'{return "Get-ScheduledTask | Where-Object { `$_.TaskName -match 'ShadowCopy|Shadow Copy' } | Select-Object TaskName,Triggers | Format-List"}
  'I1.03'{return "vssadmin list shadows /for=E:; Get-Content E:\Shares\Shanghai\B3-Shadow-Test.txt"}
  'I1.04'{return "Get-WindowsFeature Windows-Server-Backup; Test-Path '\\BJ-SRV01\B3Backup$'; Get-SmbShareAccess -CimSession BJ-SRV01 -Name 'B3Backup$'"}
  'I1.05'{return "Get-WBBackupSet | Format-List *"}
  'I1.06'{return "Test-Path E:\RestoreTest\B3-Backup-Test.txt; Get-Content E:\RestoreTest\B3-Backup-Test.txt -ErrorAction SilentlyContinue"}
  'I1.07'{return "Get-WBSchedule -ErrorAction SilentlyContinue; Get-ScheduledTask | Where-Object { `$_.TaskName -match 'Backup' }"}
  'J1.01'{return 'runas /user:NBB3\storage.sh01 "powershell -NoProfile -Command ""Test-Path \\nb-b3.local\Corp\Common; Test-Path \\nb-b3.local\Corp\Shanghai; Test-Path \\nb-b3.local\Corp\Archive; Test-Path \\nb-b3.local\Corp\Beijing"""'}
  'J1.02'{return 'runas /user:NBB3\storage.bj01 "powershell -NoProfile -Command ""Test-Path \\nb-b3.local\Corp\Common; Test-Path \\nb-b3.local\Corp\Beijing; Test-Path \\nb-b3.local\Corp\Archive; Test-Path \\nb-b3.local\Corp\Shanghai"""'}
  'J1.03'{return 'runas /user:NBB3\auditor.b3 "powershell -NoProfile -Command ""Get-ChildItem \\nb-b3.local\Corp\Common; Get-ChildItem \\nb-b3.local\Corp\Archive; Set-Content \\nb-b3.local\Corp\Common\auditor-write-test.txt test"""'}
  'J1.04'{return "Select-String -Path C:\Skills\B3\B3-selfcheck.txt -Pattern 'allowed.txt','blocked.exe','PASS','BLOCK'"}
  'J1.05'{return "'B3-foundation.ps1','B3-storage-setup.ps1','B3-ad-objects.ps1','B3-iscsi.ps1','B3-shares-permissions.ps1','B3-dfs.ps1','B3-fsrm.ps1','B3-backup-restore.ps1','B3-selfcheck.txt' | ForEach-Object { Get-Item (Join-Path C:\Skills\B3 `$_) -ErrorAction SilentlyContinue | Select-Object Name,Length,FullName }"}
 }
 return "# Для аспекта $AspectID ручная команда не определена"
}

function Invoke-B3Evidence {
    param(
        [string]$Command,
        [scriptblock]$ScriptBlock,
        [string[]]$RelevantTerms = @(),
        [string]$RelevantPattern,
        [int]$ContextLines = 0
    )
    Write-B3Log "Команда: $Command" Cyan
    $captured = New-Object System.Collections.Generic.List[object]
    try {
        & $ScriptBlock | ForEach-Object { [void]$captured.Add($_) }
        $value = $captured.ToArray()
        $text = ConvertTo-B3Text $value
        if ([string]::IsNullOrWhiteSpace($text)) { $text = '(пустой вывод)' }
        $display = Select-B3RelevantOutput -Text $text -Terms $RelevantTerms -Pattern $RelevantPattern -ContextLines $ContextLines
        Write-B3Log 'Фактический вывод (полный):' Blue
        Write-B3Log $text Gray
        if ($display -ne $text) {
            Write-B3Log 'Строки, использованные для автоматической проверки:' DarkBlue
            Write-B3Log $display DarkGray
        }
        return [pscustomobject]@{ Ok = $true; Text = $text; DisplayText = $display; Value = $value }
    } catch {
        $partialText = ConvertTo-B3Text $captured.ToArray()
        $errorText = "[ERROR] $($_.Exception.Message)"
        $text = if ([string]::IsNullOrWhiteSpace($partialText)) { $errorText } else { "$partialText$([Environment]::NewLine)$errorText" }
        $display = Select-B3RelevantOutput -Text $text -Terms $RelevantTerms -Pattern $RelevantPattern -ContextLines $ContextLines
        Write-B3Log 'Фактический вывод (включая данные до ошибки):' Blue
        Write-B3Log $text Red
        if ($display -ne $text) {
            Write-B3Log 'Строки, использованные для автоматической проверки:' DarkBlue
            Write-B3Log $display DarkGray
        }
        return [pscustomobject]@{ Ok = $false; Text = $text; DisplayText = $display; Value = $captured.ToArray() }
    }
}

function New-B3Result {
    param([string]$Status, [string]$Message)
    return @($Status, $Message)
}

function Test-B3ContainsAll {
    param([string]$Text, [string[]]$Terms)
    foreach ($term in @($Terms)) {
        if ($Text.IndexOf($term, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    }
    return $true
}

function Get-B3PropertyValue {
    param(
        [Parameter(Mandatory=$true)][object]$InputObject,
        [Parameter(Mandatory=$true)][string]$Name,
        [object]$Default = ''
    )
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Complete-B3Aspect {
    param([object]$Aspect, [string]$Status, [string]$Message)
    $script:B3Rows += [pscustomobject]@{
        AspectID = $Aspect.AspectID
        OriginalAspectID = $Aspect.OriginalAspectID
        GroupID = $Aspect.GroupID
        HostKey = $Aspect.HostKey
        MaxMark = $Aspect.MaxMark
        Status = $Status
        Message = $Message
    }
    if ($script:B3ReportEnabled) {
        $safeMessage = $Message -replace "`t", ' ' -replace "`r?`n", ' '
        Add-Content -LiteralPath $script:B3ResultsPath -Value "$($Aspect.AspectID)`t$($Aspect.OriginalAspectID)`t$($Aspect.GroupID)`t$($Aspect.HostKey)`t$($Aspect.MaxMark)`t$Status`t$safeMessage" -Encoding UTF8
    }
    switch ($Status) {
        'PASS' { Write-B3Log "[PASS] $($Aspect.AspectID)/$($Aspect.MaxMark) - $Message" Green }
        'FAIL' { Write-B3Log "[FAIL] $($Aspect.AspectID)/$($Aspect.MaxMark) - $Message" Red }
        default { Write-B3Log "[WARN] $($Aspect.AspectID)/$($Aspect.MaxMark) - $Message" Yellow }
    }
    if ($script:B3PauseBetweenChecks) { [void](Read-Host 'Нажмите Enter, чтобы продолжить') }
}

function Invoke-B3NativeText {
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

function Get-B3FeatureEvidence {
    param([string]$Name)
    $feature = Get-WindowsFeature -Name $Name -ErrorAction Stop
    return "Feature=$($feature.Name); InstallState=$($feature.InstallState); Installed=$($feature.Installed)"
}

function Get-B3TcpEvidence {
    param([string]$Target, [int]$Port)
    $ok = Test-NetConnection $Target -Port $Port -InformationLevel Quiet -WarningAction SilentlyContinue
    return "Target=$Target; Port=$Port; TcpTestSucceeded=$ok"
}

function Invoke-B3MeasuredCheck {
    param([string]$Command,[scriptblock]$Collect,[scriptblock]$Accept,[string]$Pass,[string]$Fail,[string[]]$Terms=@())
    $r=Invoke-B3Evidence -Command $Command -ScriptBlock $Collect -RelevantTerms $Terms
    try {
        if($r.Ok -and (& $Accept $r.Text $r.Value)){
            Write-B3Log "AUTOCHECK_OK expected/result: $Pass" Green
            return New-B3Result PASS $Pass
        }
    }
    catch {
        Write-B3Log "AUTOCHECK_WARN analysis_error=$($_.Exception.Message)" Yellow
        return New-B3Result WARN "Ошибка анализа evidence: $($_.Exception.Message)"
    }
    Write-B3Log "AUTOCHECK_FAIL expected/result: $Fail" Red
    return New-B3Result FAIL $Fail
}

function Get-B3AclEvidence { param([string]$Path,[string]$Share)
    "PATH=$Path"; (Get-Acl -LiteralPath $Path).Access | ForEach-Object { "NTFS=$($_.IdentityReference);Rights=$($_.FileSystemRights);Type=$($_.AccessControlType);Inherited=$($_.IsInherited)" }
    Get-SmbShareAccess -Name $Share | ForEach-Object { "SHARE=$($_.AccountName);Right=$($_.AccessRight);Type=$($_.AccessControlType)" }
}
function Get-B3SubmissionEvidence { param([string[]]$Names)
    foreach($n in $Names){$p=Join-Path 'C:\Skills\B3' $n;$exists=Test-Path -LiteralPath $p;$length=if($exists){(Get-Item -LiteralPath $p).Length}else{0};if($exists-and$length-gt0){"SUBMISSION_OK file=$n expected=exists/non-empty actual=exists,length:$length"}else{"SUBMISSION_FAIL file=$n expected=exists/non-empty actual=exists:$exists,length:$length"}}
}

function Test-B3StorageAspect {
 param([string]$HostKey,[string]$AspectID)
 switch($AspectID){
  'A1.01' { return Invoke-B3MeasuredCheck 'hostname; AD computer names; router DNS names' { hostname;foreach($x in 'SHA-DC01','SHA-FS01','SHA-CL01','BJ-DC02','BJ-SRV01','BJ-CL01'){Get-ADComputer $x|ForEach-Object{"HOST=$($_.Name)"}};foreach($x in 'SHA-RTR01','BJ-RTR01'){Resolve-DnsName "$x.nb-b3.local"|Out-Null;"ROUTER_NAME=$x"} } {param($t) @('SHA-RTR01','SHA-DC01','SHA-FS01','SHA-CL01','BJ-RTR01','BJ-DC02','BJ-SRV01','BJ-CL01')|ForEach-Object{if($t-notmatch[regex]::Escape($_)){return $false}}; $true} 'Все обязательные hostnames найдены через local/AD/DNS evidence.' 'Не найден один или несколько обязательных hostnames.' }
  'A1.02' { return Invoke-B3MeasuredCheck 'Get-NetIPAddress -AddressFamily IPv4' {$actual=@(Get-NetIPAddress -AddressFamily IPv4|Where-Object{$_.PrefixOrigin -ne'WellKnown'});foreach($ip in '198.18.120.10','10.23.10.1','10.23.20.1','10.23.30.1'){$m=@($actual|Where-Object{$_.IPAddress -eq $ip});if($m.Count){"IP_ADDRESS_OK expected=$ip/24 actual=$($m[0].IPAddress)/$($m[0].PrefixLength) interface=$($m[0].InterfaceAlias)"}else{"IP_ADDRESS_FAIL expected=$ip/24 actual=MISSING"}}} {param($t)([regex]::Matches($t,'IP_ADDRESS_OK')).Count-eq4 -and $t-notmatch'IP_ADDRESS_FAIL'} 'Все четыре IPv4 SHA-RTR01 корректны.' 'Показаны все ожидаемые IPv4; один или несколько отсутствуют.' }
  'A1.03' { return Invoke-B3MeasuredCheck 'Get-NetIPConfiguration; Get-DnsClientServerAddress' {Get-NetIPConfiguration;Get-DnsClientServerAddress -AddressFamily IPv4} {param($t) $t-match'10\.23\.20\.20' -and $t-match'10\.23\.20\.1' -and $t-match'10\.23\.20\.10' -and $t-match'10\.33\.20\.10'} 'IP/gateway/DNS SHA-FS01 корректны.' 'IP/gateway/DNS SHA-FS01 не соответствуют плану.' }
  'A1.04' { return Test-B3RoutingDetails @('10.33.20.0/24','10.33.30.0/24','198.18.200.0/24','198.18.201.0/24') '198.18.120.1' }
  'A1.05' { return Test-B3RoutingDetails @('10.23.10.0/24','10.23.20.0/24','10.23.30.0/24','198.18.200.0/24','198.18.201.0/24') '198.18.121.1' }
  'A1.06' { return Invoke-B3MeasuredCheck 'Get-ADDomain; Get-ADForest; Get-ADDomainController SHA-DC01' {Get-ADDomain;Get-ADForest;Get-ADDomainController -Identity SHA-DC01} {param($t) $t-match'nb-b3\.local' -and $t-match'NBB3' -and $t-match'SHA-DC01'} 'Forest/domain SHA-DC01 корректны.' 'Forest/domain SHA-DC01 не соответствуют заданию.' }
  'A1.07' { return Invoke-B3MeasuredCheck 'Get-ADDomainController BJ-DC02; repadmin /replsummary; Get-SmbShare' {
    try{$dc=Get-ADDomainController -Identity BJ-DC02 -ErrorAction Stop;$actualHost=([string]$dc.HostName).Split('.')[0];if($actualHost-eq'BJ-DC02'){"DC_ITEM_OK item=identity expected=BJ-DC02 actual=$actualHost fqdn=$($dc.HostName) site=$($dc.Site)"}else{"DC_ITEM_FAIL item=identity expected=BJ-DC02 actual=$actualHost"};if($dc.IsGlobalCatalog){"DC_ITEM_OK item=global_catalog expected=True actual=$($dc.IsGlobalCatalog)"}else{"DC_ITEM_FAIL item=global_catalog expected=True actual=$($dc.IsGlobalCatalog)"}}
    catch{"DC_ITEM_FAIL item=domain_controller expected=BJ-DC02 actual=LOOKUP_ERROR error=$($_.Exception.Message)"}
    $repLines=@(& repadmin /replsummary 2>&1|ForEach-Object{[string]$_});$repExit=$LASTEXITCODE;$repLines
    $failureRows=@($repLines|Where-Object{$_ -match '^\s*\S+\s+\S+\s+([1-9][0-9]*)\s*/\s*[0-9]+\s+[0-9]+'})
    $successRows=@($repLines|Where-Object{$_ -match '^\s*\S+\s+\S+\s+0\s*/\s*[1-9][0-9]*\s+0\s*$'})
    if ($repExit -eq 0 -and -not $failureRows.Count -and $successRows.Count -ge 2) {"DC_ITEM_OK item=replication expected=zero-failures actual=zero-failures rows=$($successRows.Count) exit=$repExit"}
    else{"DC_ITEM_FAIL item=replication expected=zero-failures actual=failure_rows:$($failureRows.Count),success_rows:$($successRows.Count),exit:$repExit details=$($failureRows -join ' | ')"}
    foreach($shareName in 'SYSVOL','NETLOGON'){try{$share=Get-SmbShare -Name $shareName -ErrorAction Stop;"DC_ITEM_OK item=share expected=$shareName actual=$($share.Name) path=$($share.Path)"}catch{"DC_ITEM_FAIL item=share expected=$shareName actual=MISSING error=$($_.Exception.Message)"}}
  } {param($t)([regex]::Matches($t,'DC_ITEM_OK','IgnoreCase')).Count-eq5 -and $t-notmatch'DC_ITEM_FAIL'} 'BJ-DC02 identity/GC, zero-failure replication, SYSVOL и NETLOGON подтверждены.' 'Строки DC_ITEM_FAIL показывают точный проблемный атрибут BJ-DC02.' }
  'A1.08' { return Invoke-B3MeasuredCheck 'Get-DnsServerZone' {
    $zones=@(Get-DnsServerZone)
    $expected=[ordered]@{
      'forward nb-b3.local'='nb-b3.local'
      'reverse 10.23.10.0/24'='10.23.10.in-addr.arpa'
      'reverse 10.23.20.0/24'='20.23.10.in-addr.arpa'
      'reverse 10.23.30.0/24'='30.23.10.in-addr.arpa'
      'reverse 10.33.20.0/24'='20.33.10.in-addr.arpa'
      'reverse 10.33.30.0/24'='30.33.10.in-addr.arpa'
      'reverse 198.18.120.0/24'='120.18.198.in-addr.arpa'
      'reverse 198.18.121.0/24'='121.18.198.in-addr.arpa'
    }
    foreach($requirement in $expected.Keys){
      $wanted=$expected[$requirement]
      $matches=@($zones|Where-Object{[string]::Equals([string]$_.ZoneName,$wanted,[StringComparison]::OrdinalIgnoreCase)})
      if(-not $matches.Count){"DNS_ZONE_FAIL requirement='$requirement' expected_zone=$wanted actual=MISSING";continue}
      $z=$matches[0];$integratedRequired=$requirement-like'forward*'
      if($integratedRequired -and -not $z.IsDsIntegrated){"DNS_ZONE_FAIL requirement='$requirement' expected_zone=$wanted expected_integrated=True actual_zone=$($z.ZoneName) actual_integrated=$($z.IsDsIntegrated) type=$($z.ZoneType)"}
      else{"DNS_ZONE_OK requirement='$requirement' expected_zone=$wanted actual_zone=$($z.ZoneName) integrated=$($z.IsDsIntegrated) type=$($z.ZoneType)"}
    }
    $requiredNames=@($expected.Values)
    $extra=@($zones|Where-Object{ $_.ZoneName -notin $requiredNames -and $_.ZoneName -notmatch '(?i)^_msdcs\.|TrustAnchors|RootDNSServers' })
    foreach($z in $extra){"DNS_ZONE_INFO additional_zone=$($z.ZoneName) integrated=$($z.IsDsIntegrated) type=$($z.ZoneType)"}
  } {param($t)([regex]::Matches($t,'DNS_ZONE_OK')).Count-eq8 -and $t-notmatch'DNS_ZONE_FAIL'} 'Все 8 обязательных forward/reverse DNS zones присутствуют.' 'Строки DNS_ZONE_FAIL показывают точные отсутствующие или неверные зоны.' }
  'A1.09' {
   return Invoke-B3MeasuredCheck 'Resolve-DnsName required A/CNAME' {
    $expected=[ordered]@{
     'sha-rtr01.nb-b3.local'='A|10.23.20.1'; 'sha-dc01.nb-b3.local'='A|10.23.20.10'
     'sha-fs01.nb-b3.local'='A|10.23.20.20'; 'bj-rtr01.nb-b3.local'='A|10.33.20.1'
     'bj-dc02.nb-b3.local'='A|10.33.20.10'; 'bj-srv01.nb-b3.local'='A|10.33.20.20'
     'files.nb-b3.local'='CNAME|sha-fs01.nb-b3.local'; 'branch-files.nb-b3.local'='CNAME|bj-srv01.nb-b3.local'
    }
    foreach($name in $expected.Keys){
     $parts=$expected[$name] -split '\|',2; $wantedType=$parts[0]; $wantedValue=$parts[1]
     try{$answers=@(Resolve-DnsName $name -ErrorAction Stop)}catch{"DNS_RECORD_FAIL name=$name type=$wantedType expected=$wantedValue actual=NOT_FOUND error=$($_.Exception.Message)";continue}
     $actual=@()
     foreach($answer in $answers){
      if($wantedType -eq 'A'){$value=[string](Get-B3PropertyValue $answer 'IPAddress');if($value){$actual+=$value}}
      else{$value=[string](Get-B3PropertyValue $answer 'NameHost');if($value){$actual+=$value.TrimEnd('.').ToLowerInvariant()}}
     }
     $actual=@($actual|Sort-Object -Unique);$matched=$actual -contains $wantedValue.ToLowerInvariant()
     if($matched){"DNS_RECORD_OK name=$name type=$wantedType expected=$wantedValue actual=$($actual -join ',')"}
     else{"DNS_RECORD_FAIL name=$name type=$wantedType expected=$wantedValue actual=$(if($actual.Count){$actual -join ','}else{'NO_MATCHING_ANSWER'})"}
    }
   } {param($t) ([regex]::Matches($t,'DNS_RECORD_OK','IgnoreCase')).Count-eq8 -and $t-notmatch'DNS_RECORD_FAIL'} 'Все 8 A/CNAME records соответствуют заданию.' 'Показаны все A/CNAME records; одна или несколько записей отсутствуют либо неверны.'
  }
  'A1.10' {
   return Invoke-B3MeasuredCheck 'Resolve-DnsName required PTR' {
    $expected=[ordered]@{
     '10.23.10.1'='sha-rtr01.nb-b3.local'; '10.23.20.1'='sha-rtr01.nb-b3.local'
     '10.23.20.10'='sha-dc01.nb-b3.local'; '10.23.20.20'='sha-fs01.nb-b3.local'
     '10.33.20.1'='bj-rtr01.nb-b3.local'; '10.33.20.10'='bj-dc02.nb-b3.local'
     '10.33.20.20'='bj-srv01.nb-b3.local'; '198.18.120.10'='sha-rtr01.nb-b3.local'
     '198.18.121.10'='bj-rtr01.nb-b3.local'
    }
    foreach($ip in $expected.Keys){
     $wanted=$expected[$ip]
     try{$answers=@(Resolve-DnsName $ip -ErrorAction Stop)}catch{"PTR_FAIL ip=$ip expected=$wanted actual=NOT_FOUND error=$($_.Exception.Message)";continue}
     $actual=@($answers|ForEach-Object{$value=[string](Get-B3PropertyValue $_ 'NameHost');if($value){$value.TrimEnd('.').ToLowerInvariant()}}|Where-Object{$_}|Sort-Object -Unique)
     if($actual -contains $wanted){"PTR_OK ip=$ip expected=$wanted actual=$($actual -join ',')"}
     else{"PTR_FAIL ip=$ip expected=$wanted actual=$(if($actual.Count){$actual -join ','}else{'NO_PTR_ANSWER'})"}
    }
   } {param($t) ([regex]::Matches($t,'PTR_OK','IgnoreCase')).Count-eq9 -and $t-notmatch'PTR_FAIL'} 'Все 9 PTR records соответствуют заданию.' 'Показаны все PTR records; одна или несколько записей отсутствуют либо неверны.'
  }
  'A1.11' { return Invoke-B3MeasuredCheck 'Get-DhcpServerv4Scope/OptionValue/ExclusionRange' {Get-DhcpServerv4Scope -ScopeId 10.23.30.0;Get-DhcpServerv4OptionValue -ScopeId 10.23.30.0;Get-DhcpServerv4ExclusionRange -ScopeId 10.23.30.0} {param($t) @('Shanghai-ClientNet','10.23.30.100','10.23.30.200','10.23.30.119','10.23.30.1','10.23.20.10','10.33.20.10','nb-b3.local')|ForEach-Object{if($t-notmatch[regex]::Escape($_)){return $false}};$true} 'Shanghai DHCP scope корректен.' 'Shanghai DHCP scope/options неверны.' }
  'A1.12' { return Invoke-B3MeasuredCheck 'Get-DhcpServerv4Scope/OptionValue/ExclusionRange' {Get-DhcpServerv4Scope -ScopeId 10.33.30.0;Get-DhcpServerv4OptionValue -ScopeId 10.33.30.0;Get-DhcpServerv4ExclusionRange -ScopeId 10.33.30.0} {param($t) @('Beijing-ClientNet','10.33.30.100','10.33.30.200','10.33.30.119','10.33.30.1','10.33.20.10','10.23.20.10','nb-b3.local')|ForEach-Object{if($t-notmatch[regex]::Escape($_)){return $false}};$true} 'Beijing DHCP scope корректен.' 'Beijing DHCP scope/options неверны.' }
  'A1.13' { return Invoke-B3MeasuredCheck 'Get-DhcpServerInDC; ipconfig /all' {Get-DhcpServerInDC;ipconfig /all} {param($t) $t-match'SHA-FS01' -and $t-match'BJ-SRV01' -and $t-match'10\.23\.30\.(1[2-9][0-9]|200)' -and $t-match'nb-b3\.local'} 'DHCP authorization и client lease подтверждены.' 'DHCP authorization/lease не подтверждены.' }
  'A1.14' { return Invoke-B3MeasuredCheck 'Get-ADOrganizationalUnit/Get-ADComputer' {Get-ADOrganizationalUnit -Filter *|Select Name,DistinguishedName;foreach($n in 'SHA-FS01','BJ-SRV01','SHA-CL01','BJ-CL01'){Get-ADComputer $n -Properties DistinguishedName}} {param($t) @('00-Servers','10-Workstations','50-Storage','60-B3-Groups','70-B3-TestUsers','OU=Shanghai','OU=Beijing')|ForEach-Object{if($t-notmatch[regex]::Escape($_)){return $false}};$true} 'OU и placement подтверждены.' 'OU или placement неполны.' }
  'A1.15' { return Invoke-B3MeasuredCheck 'Domain membership and Get-ADComputer' {(Get-CimInstance Win32_ComputerSystem)|Select Name,Domain,PartOfDomain;foreach($n in 'SHA-FS01','BJ-SRV01','SHA-CL01','BJ-CL01'){Get-ADComputer $n}} {param($t) $t-match'PartOfDomain\s*: True' -and ([regex]::Matches($t,'SHA-FS01|BJ-SRV01|SHA-CL01|BJ-CL01')).Count-ge4} 'Domain join подтверждён.' 'Domain join обязательных хостов не подтверждён.' }
  'A1.16' { return Invoke-B3MeasuredCheck 'Test-WSMan required servers' {foreach($x in 'SHA-FS01','BJ-SRV01','SHA-DC01','BJ-DC02'){try{Test-WSMan $x -ErrorAction Stop|Out-Null;"WSMAN_OK host=$x expected=reachable actual=reachable"}catch{"WSMAN_FAIL host=$x expected=reachable actual=unreachable error=$($_.Exception.Message)"}}} {param($t)([regex]::Matches($t,'WSMAN_OK')).Count-eq4 -and $t-notmatch'WSMAN_FAIL'} 'WinRM работает на четырёх серверах.' 'Показаны все WinRM endpoints; один или несколько недоступны.' }
  'A1.17' { return Test-B3TcpDetails @('SHA-FS01','BJ-SRV01') 445 }
  'A1.18' { return Invoke-B3MeasuredCheck 'Functional DNS, SMB, DFS and WinRM readiness' {Resolve-DnsName sha-fs01.nb-b3.local;foreach($s in 'SHA-FS01','BJ-SRV01'){"SMB=$s;OK=$((Test-NetConnection $s -Port 445 -InformationLevel Quiet -WarningAction SilentlyContinue))"};"DFS_OK=$(Test-Path \\nb-b3.local\Corp)";foreach($s in 'SHA-FS01','BJ-SRV01','SHA-DC01','BJ-DC02'){Test-WSMan $s|Out-Null;"WSMAN_OK=$s"}} {param($t)([regex]::Matches($t,'OK=True','IgnoreCase')).Count-ge2 -and $t-match'DFS_OK=True' -and ([regex]::Matches($t,'WSMAN_OK=')).Count-eq4} 'Foundation services доступны функционально.' 'DNS/SMB/DFS/WinRM readiness неполна.' }

  'B1.01' { return Test-B3Volume E 'SH-DATA' 70 90 }
  'B1.02' { return Test-B3Volume E 'BJ-DATA' 70 90 }
  'B1.03' { return Test-B3Volume F 'BJ-BACKUP' 50 70 }
  'B1.04' { return Invoke-B3MeasuredCheck 'Test-Path E:\Shares,F:\B3Backup' {foreach($path in 'E:\Shares','F:\B3Backup'){if(Test-Path -LiteralPath $path){"DIRECTORY_OK path=$path expected=exists actual=exists"}else{"DIRECTORY_FAIL path=$path expected=exists actual=missing"}}} {param($t)([regex]::Matches($t,'DIRECTORY_OK')).Count-eq2 -and $t-notmatch'DIRECTORY_FAIL'} 'Оба базовых каталога существуют.' 'Показаны оба каталога; один или несколько отсутствуют.' }
  'B1.05' { return Invoke-B3MeasuredCheck 'Get-Volume/Get-Partition C,E,R; compare disk numbers' {
    $parts=@{};$volumes=@{}
    foreach($letter in 'C','E','R'){
      try{$volumes[$letter]=Get-Volume -DriveLetter $letter -ErrorAction Stop;$parts[$letter]=Get-Partition -DriveLetter $letter -ErrorAction Stop;"SYSTEM_DISK_ITEM_OK drive=$letter expected=volume-present actual=present label=$($volumes[$letter].FileSystemLabel) filesystem=$($volumes[$letter].FileSystem) disk=$($parts[$letter].DiskNumber) sizeGB=$([math]::Round($volumes[$letter].Size/1GB,1))"}
      catch{"SYSTEM_DISK_ITEM_FAIL drive=$letter expected=volume-present actual=missing error=$($_.Exception.Message)"}
    }
    if($parts.ContainsKey('C')-and$parts.ContainsKey('E')){if($parts['C'].DiskNumber-ne$parts['E'].DiskNumber){"SYSTEM_DISK_ITEM_OK item=C-vs-E expected=different-disks actual=C:$($parts['C'].DiskNumber),E:$($parts['E'].DiskNumber)"}else{"SYSTEM_DISK_ITEM_FAIL item=C-vs-E expected=different-disks actual=same-disk:$($parts['C'].DiskNumber)"}}
    if($parts.ContainsKey('C')-and$parts.ContainsKey('R')){if($parts['C'].DiskNumber-ne$parts['R'].DiskNumber){"SYSTEM_DISK_ITEM_OK item=C-vs-R expected=different-disks actual=C:$($parts['C'].DiskNumber),R:$($parts['R'].DiskNumber)"}else{"SYSTEM_DISK_ITEM_FAIL item=C-vs-R expected=different-disks actual=same-disk:$($parts['C'].DiskNumber)"}}
  } {param($t)([regex]::Matches($t,'SYSTEM_DISK_ITEM_OK','IgnoreCase')).Count-eq5 -and $t-notmatch'SYSTEM_DISK_ITEM_FAIL'} 'C:, E: и R: существуют; data volumes находятся не на системном диске C:.' 'Показаны C/E/R и номера дисков; отсутствует volume либо data volume размещён на системном диске C:.' }
  'B1.06' { return Test-B3Features @('FS-FileServer','FS-DFS-Namespace','FS-DFS-Replication','FS-Resource-Manager','FS-iSCSITarget-Server') }

  'C1.01' { return Test-B3AdNames 'OU' @('50-Storage','60-B3-Groups','70-B3-TestUsers') }
  'C1.02' { return Test-B3AdNames 'GROUP' @('GG_B3_Common_RW','GG_B3_Common_RO','GG_B3_Shanghai_RW','GG_B3_Beijing_RW','GG_B3_Archive_RW','GG_B3_Archive_RO','GG_B3_Backup_Operators') }
  'C1.03' { return Invoke-B3MeasuredCheck 'Get-ADUser required users' {$u='storage.sh01','storage.bj01','auditor.b3','backup.op1';foreach($x in $u){try{$o=Get-ADUser $x -Properties Enabled,PasswordNeverExpires,PasswordExpired -ErrorAction Stop;$actual="Enabled:$($o.Enabled),Never:$($o.PasswordNeverExpires),Expired:$($o.PasswordExpired)";if($o.Enabled-and-not$o.PasswordNeverExpires-and-not$o.PasswordExpired){"AD_USER_OK user=$x expected=Enabled:True,Never:False,Expired:False actual=$actual"}else{"AD_USER_FAIL user=$x expected=Enabled:True,Never:False,Expired:False actual=$actual"}}catch{"AD_USER_FAIL user=$x expected=user exists with correct flags actual=NOT_FOUND error=$($_.Exception.Message)"}}} {param($t)([regex]::Matches($t,'AD_USER_OK','IgnoreCase')).Count-eq4 -and $t-notmatch'AD_USER_FAIL'} 'Все четыре user и password flags корректны.' 'Показаны все users; один или несколько отсутствуют либо имеют неверные flags.' }
  'C1.04' { return Test-B3Membership @{'storage.sh01'=@('GG_B3_Common_RW','GG_B3_Shanghai_RW','GG_B3_Archive_RW');'storage.bj01'=@('GG_B3_Common_RW','GG_B3_Beijing_RW','GG_B3_Archive_RW')} }
  'C1.05' { return Test-B3Membership @{'auditor.b3'=@('GG_B3_Common_RO','GG_B3_Archive_RO');'backup.op1'=@('GG_B3_Backup_Operators')} }
  'C1.06' { return New-B3Result WARN 'Broad-group bypass требует сопоставления effective ACL; evidence показан в аспектах E1.' }
  'C1.07' { return Test-B3AdNames 'ALL' @('50-Storage','60-B3-Groups','70-B3-TestUsers','GG_B3_Common_RW','GG_B3_Archive_RW','storage.sh01','storage.bj01','auditor.b3','backup.op1') }

  'D1.01' { return Invoke-B3MeasuredCheck 'Get-WindowsFeature FS-iSCSITarget-Server; Test-Path E:\iSCSI' {Get-WindowsFeature FS-iSCSITarget-Server;"ISCSI_DIR=$(Test-Path E:\iSCSI)"} {param($t)$t-match'Installed' -and $t-match'ISCSI_DIR=True'} 'iSCSI Target role/каталог готовы.' 'iSCSI Target role или каталог отсутствует.' }
  'D1.02' { return Invoke-B3MeasuredCheck 'Get-IscsiVirtualDisk' {Get-IscsiVirtualDisk|ForEach-Object{"PATH=$($_.Path);SIZEGB=$([math]::Round($_.Size/1GB,1))"}} {param($t)$t-match'E:\\iSCSI\\B3-Archive\.vhdx' -and $t-match'SIZEGB=30'} 'iSCSI VHDX корректен.' 'iSCSI VHDX отсутствует или неверного размера.' }
  'D1.03' { return Invoke-B3MeasuredCheck 'Get-IscsiServerTarget B3-Archive-Target' {Get-IscsiServerTarget -TargetName B3-Archive-Target|Format-List *} {param($t)$t-match'B3-Archive-Target' -and $t-match'SHA-FS01'} 'Target ограничен SHA-FS01.' 'Target/access list неверны.' }
  'D1.04' { return Invoke-B3MeasuredCheck 'Get-IscsiTarget; Get-IscsiSession' {Get-IscsiTarget;Get-IscsiSession} {param($t)$t-match'IsConnected\s*: True' -and $t-match'BJ-SRV01|10\.33\.20\.20'} 'Активная iSCSI session подтверждена.' 'Активная iSCSI session не найдена.' }
  'D1.05' { return Test-B3Volume R 'SH-ARCHIVE' 25 35 }
  'D1.06' { return Invoke-B3MeasuredCheck 'Test-Path R:\Archive' {"ARCHIVE=$(Test-Path R:\Archive)"} {param($t)$t-match'ARCHIVE=True'} 'R:\Archive существует.' 'R:\Archive отсутствует.' }
  'D1.07' { return Invoke-B3MeasuredCheck 'Get-IscsiSession; Test-NetConnection BJ-SRV01:3260' {Get-IscsiSession;"TCP3260=$((Test-NetConnection BJ-SRV01 -Port 3260 -InformationLevel Quiet -WarningAction SilentlyContinue))"} {param($t)$t-match'TCP3260=True' -and $t-match'IsConnected\s*: True'} 'iSCSI connectivity работает.' 'iSCSI session/TCP3260 не работает.' }
  'D1.08' { return Invoke-B3MeasuredCheck 'Get-IscsiServerTarget initiator IDs' {Get-IscsiServerTarget -TargetName B3-Archive-Target|Format-List *} {param($t)$t-match'SHA-FS01' -and $t-notmatch'(?i)SHA-CL01|BJ-CL01|BJ-DC02'} 'Посторонние initiator не найдены.' 'В target access найдены посторонние initiator.' }

  'E1.01' { return Test-B3Shares @{'Common'='E:\Shares\Common';'Shanghai'='E:\Shares\Shanghai';'Archive'='R:\Archive'} }
  'E1.02' { return Test-B3Shares @{'Common'='E:\Shares\Common';'Beijing'='E:\Shares\Beijing';'B3Backup$'='F:\B3Backup'} }
  'E1.03' { return Invoke-B3MeasuredCheck 'Get-SmbShare Common,Shanghai,Archive' {foreach($name in 'Common','Shanghai','Archive'){try{$s=Get-SmbShare $name -ErrorAction Stop;if($s.FolderEnumerationMode-eq'AccessBased'){"ABE_OK share=$name expected=AccessBased actual=$($s.FolderEnumerationMode)"}else{"ABE_FAIL share=$name expected=AccessBased actual=$($s.FolderEnumerationMode)"}}catch{"ABE_FAIL share=$name expected=AccessBased actual=NOT_FOUND error=$($_.Exception.Message)"}}} {param($t)([regex]::Matches($t,'ABE_OK','IgnoreCase')).Count-eq3 -and $t-notmatch'ABE_FAIL'} 'ABE включён на трёх shares.' 'Показаны все shares; ABE включён не на всех.' }
  'E1.04' { return Test-B3Acl 'E:\Shares\Common' 'Common' @('GG_B3_Common_RW','GG_B3_Common_RO','Domain Admins') }
  'E1.05' { return Test-B3Acl 'E:\Shares\Shanghai' 'Shanghai' @('GG_B3_Shanghai_RW','Domain Admins') }
  'E1.06' { return Test-B3Acl 'E:\Shares\Beijing' 'Beijing' @('GG_B3_Beijing_RW','Domain Admins') }
  'E1.07' { return Test-B3Acl 'R:\Archive' 'Archive' @('GG_B3_Archive_RW','GG_B3_Archive_RO','Domain Admins') }
  'E1.08' { return Test-B3Acl 'F:\B3Backup' 'B3Backup$' @('GG_B3_Backup_Operators','SHA-FS01$','Domain Admins') }
  'E1.09' { return Invoke-B3MeasuredCheck 'Review SMB/NTFS broad principals' {foreach($s in 'Common','Beijing','B3Backup$'){Get-SmbShareAccess $s|ForEach-Object{"SHARE=$s;ACCOUNT=$($_.AccountName);RIGHT=$($_.AccessRight)"}}} {param($t)$t-notmatch'(?i)(Everyone|Authenticated Users|Domain Users).*Full'} 'Broad Full bypass не обнаружен.' 'Обнаружен broad Full access bypass.' }
  'E1.10' { return Test-B3TcpDetails @('SHA-FS01','BJ-SRV01') 445 }

  'F1.01' { return Test-B3Feature 'FS-DFS-Namespace' }
  'F1.02' { return Invoke-B3MeasuredCheck 'Get-DfsnRoot/Get-DfsnRootTarget' {Get-DfsnRoot -Path '\\nb-b3.local\Corp';Get-DfsnRootTarget -Path '\\nb-b3.local\Corp'} {param($t)$t-match'\\\\nb-b3\.local\\Corp' -and $t-match'SHA-FS01' -and $t-match'BJ-SRV01'} 'DFS root и два namespace server подтверждены.' 'DFS root/targets неверны.' }
  'F1.03' { return Test-B3DfsTargets '\\nb-b3.local\Corp\Common' @('\\SHA-FS01\Common','\\BJ-SRV01\Common') }
  'F1.04' { return Test-B3DfsTargetMap ([ordered]@{'\\nb-b3.local\Corp\Shanghai'='\\SHA-FS01\Shanghai';'\\nb-b3.local\Corp\Beijing'='\\BJ-SRV01\Beijing';'\\nb-b3.local\Corp\Archive'='\\SHA-FS01\Archive'}) }
  'F1.05' { return Invoke-B3MeasuredCheck 'Test-Path DFS root/folders' {$p='','Common','Shanghai','Beijing','Archive';foreach($x in $p){$q="\\nb-b3.local\Corp"+$(if($x){"\$x"});$ok=Test-Path $q;if($ok){"DFS_ACCESS_OK path=$q expected=accessible actual=True"}else{"DFS_ACCESS_FAIL path=$q expected=accessible-subject-to-ACL actual=False"}}} {param($t)([regex]::Matches($t,'DFS_ACCESS_OK','IgnoreCase')).Count-ge3} 'DFS namespace доступен с клиента с учётом ACL.' 'Показаны все DFS paths; namespace/folders недоступны.' }
  'F1.06' { return Invoke-B3MeasuredCheck 'Get-SmbShare Archive' {Get-SmbShare Archive|ForEach-Object{"PATH=$($_.Path)"}} {param($t)$t-match'PATH=R:\\Archive'} 'Archive использует R:\Archive.' 'Archive не использует iSCSI volume R:.' }
  'F1.07' { return Invoke-B3MeasuredCheck 'Get-DfsnFolderTarget all' {Get-DfsnFolder -Path '\\nb-b3.local\Corp\*'|ForEach-Object{Get-DfsnFolderTarget -Path $_.Path}} {param($t)$t-notmatch'(?i)C:\\|SHA-DC01|BJ-DC02' -and ([regex]::Matches($t,'TargetPath')).Count-ge5} 'Неверные DFS target не найдены.' 'Найден неверный/неполный DFS target.' }

  'G1.01' { return Test-B3Feature 'FS-DFS-Replication' }
  'G1.02' { return Invoke-B3MeasuredCheck 'Get-DfsReplicationGroup/Get-DfsReplicatedFolder' {Get-DfsReplicationGroup -GroupName B3-Common-RG;Get-DfsReplicatedFolder -GroupName B3-Common-RG} {param($t)$t-match'B3-Common-RG' -and $t-match'Common'} 'DFSR group/folder существуют.' 'DFSR group/folder отсутствуют.' }
  'G1.03' { return Invoke-B3MeasuredCheck 'Get-DfsrMembership B3-Common-RG' {Get-DfsrMembership -GroupName B3-Common-RG|Format-List *} {param($t)$t-match'SHA-FS01' -and $t-match'BJ-SRV01' -and ([regex]::Matches($t,'E:\\Shares\\Common','IgnoreCase')).Count-ge2} 'DFSR members/paths корректны.' 'DFSR members/paths неверны.' }
  'G1.04' { return Invoke-B3MeasuredCheck 'Get-DfsrConnection/Membership settings' {Get-DfsrConnection -GroupName B3-Common-RG|Format-List *;Get-DfsrMembership -GroupName B3-Common-RG|Format-List *;Get-DfsReplicatedFolder -GroupName B3-Common-RG|Format-List *} {param($t)$t-match'Enabled\s*: True' -and $t-match'StagingPathQuotaInMB\s*: 1024' -and $t-match'~\*' -and $t-match'\*\.tmp'} 'DFSR settings подтверждены.' 'DFSR topology/staging/filter settings неверны.' }
  'G1.05' { return Invoke-B3MeasuredCheck 'Get-Content B3-DFSR-Test.txt' {"EXISTS=$(Test-Path E:\Shares\Common\B3-DFSR-Test.txt)";Get-Content E:\Shares\Common\B3-DFSR-Test.txt} {param($t)$t-match'EXISTS=True' -and $t-match'DFS Replication validation for B3'} 'DFSR test file реплицирован.' 'DFSR test file отсутствует/неверен.' }
  'G1.06' { return Invoke-B3MeasuredCheck 'Get-DfsReplicatedFolder all' {Get-DfsReplicatedFolder|Select GroupName,FolderName} {param($t)$t-match'Common' -and $t-notmatch'(?i)Shanghai|Beijing|Archive'} 'DFSR настроен только для Common.' 'DFSR ошибочно настроен для других folders.' }
  'G1.07' { return Invoke-B3MeasuredCheck 'Get-Service DFSR; recent blocking events; test file' {Get-Service DFSR;Get-WinEvent -FilterHashtable @{LogName='DFS Replication';StartTime=(Get-Date).AddHours(-2)} -ErrorAction SilentlyContinue|Where-Object{$_.LevelDisplayName -eq'Error'}|Select -First 10 Id,Message;"TEST=$(Test-Path E:\Shares\Common\B3-DFSR-Test.txt)"} {param($t)$t-match'Running' -and $t-match'TEST=True'} 'DFSR service и functional result исправны.' 'DFSR service/test replication имеют проблему.' }

  'H1.01' { return Test-B3Feature 'FS-Resource-Manager' }
  'H1.02' { return Invoke-B3MeasuredCheck 'Get-FsrmQuotaTemplate B3-Beijing-1GB-Hard' {Get-FsrmQuotaTemplate -Name B3-Beijing-1GB-Hard|ForEach-Object{"NAME=$($_.Name);SIZE=$($_.Size);SOFT=$($_.SoftLimit)"}} {param($t)$t-match'NAME=B3-Beijing-1GB-Hard' -and $t-match'SIZE=1073741824' -and $t-match'SOFT=False'} 'Hard quota template 1GB корректен.' 'Quota template неверен.' }
  'H1.03' { return Invoke-B3MeasuredCheck 'Get-FsrmQuota E:\Shares\Beijing' {Get-FsrmQuota -Path E:\Shares\Beijing|Format-List *} {param($t)$t-match'E:\\Shares\\Beijing' -and $t-match'1073741824' -and $t-match'SoftLimit\s*: False'} 'Hard quota применён.' 'Quota на Beijing неверна.' }
  'H1.04' { return Invoke-B3MeasuredCheck 'Get-FsrmFileGroup' {try{$g=Get-FsrmFileGroup -Name B3-Blocked-Executable-Files -ErrorAction Stop;$actual=@($g.IncludePattern);foreach($pattern in '*.exe','*.bat','*.cmd','*.msi','*.ps1'){if($actual-contains$pattern){"FSRM_PATTERN_OK expected=$pattern actual=present"}else{"FSRM_PATTERN_FAIL expected=$pattern actual=missing configured=$($actual -join ',')"}}}catch{foreach($pattern in '*.exe','*.bat','*.cmd','*.msi','*.ps1'){"FSRM_PATTERN_FAIL expected=$pattern actual=GROUP_NOT_FOUND error=$($_.Exception.Message)"}}} {param($t)([regex]::Matches($t,'FSRM_PATTERN_OK')).Count-eq5 -and $t-notmatch'FSRM_PATTERN_FAIL'} 'Все пять FSRM patterns настроены.' 'Показаны все FSRM patterns; один или несколько отсутствуют.' }
  'H1.05' { return Invoke-B3MeasuredCheck 'Get-FsrmFileScreen E:\Shares\Beijing' {Get-FsrmFileScreen -Path E:\Shares\Beijing|Format-List *} {param($t)$t-match'B3-Blocked-Executable-Files' -and $t-match'Active'} 'Active file screen настроен.' 'Active file screen отсутствует/неверен.' }
  'H1.06' { return New-B3Result WARN 'Проверка выполняется под storage.bj01: allowed.txt должен создаваться, blocked.exe — отклоняться; пароль checker не хранит.' }

  'I1.01' { return Invoke-B3MeasuredCheck 'vssadmin list shadowstorage /for=E:' {vssadmin list shadowstorage /for=E:} {param($t)$t-match'For volume.*E:' -and $t-match'Maximum Shadow Copy Storage space'} 'Shadow storage E: настроен; проверьте показанный процент/размер.' 'Shadow storage E: не найден.' }
  'I1.02' { return Invoke-B3MeasuredCheck 'Get-ScheduledTask shadow copy triggers' {Get-ScheduledTask|Where-Object{$_.TaskName-match'ShadowCopy|Shadow Copy'}|ForEach-Object{$_.TaskName;$_.Triggers|Format-List *}} {param($t)$t-match'07:00|7:00|T07:00' -and $t-match'12:00|T12:00'} 'Shadow Copy schedule 07:00/12:00 найден.' 'Shadow Copy schedule неполон.' }
  'I1.03' { return Invoke-B3MeasuredCheck 'vssadmin list shadows; Get-Content shadow test' {vssadmin list shadows /for=E:;"CURRENT=$(Get-Content E:\Shares\Shanghai\B3-Shadow-Test.txt -Raw)"} {param($t)$t-match'Shadow Copy ID' -and $t-match'CURRENT=version 2'} 'Initial shadow и current version 2 подтверждены.' 'Shadow/test file не подготовлены.' }
  'I1.04' { return Invoke-B3MeasuredCheck 'Get-WindowsFeature Windows-Server-Backup; Test-Path repository' {Get-WindowsFeature Windows-Server-Backup;"REPOSITORY=$(Test-Path \\BJ-SRV01\B3Backup$)"} {param($t)$t-match'Installed' -and $t-match'REPOSITORY=True'} 'WSB и repository доступны.' 'WSB/repository не готовы.' }
  'I1.05' { return Invoke-B3MeasuredCheck 'Get-WBBackupSet' {Get-WBBackupSet|Format-List *} {param($t)$t-match'BJ-SRV01|B3Backup' -and $t-notmatch'(?i)failed|failure'} 'Backup set на BJ-SRV01 найден.' 'Успешный backup set не подтверждён.' }
  'I1.06' { return Invoke-B3MeasuredCheck 'Test/Get restored file' {"EXISTS=$(Test-Path E:\RestoreTest\B3-Backup-Test.txt)";Get-Content E:\RestoreTest\B3-Backup-Test.txt} {param($t)$t-match'EXISTS=True' -and $t-match'B3 backup validation'} 'Restored file корректен.' 'Restored file отсутствует/неверен.' }
  'I1.07' { return New-B3Result PASS 'Регулярное расписание backup по заданию не требуется.' }

  'J1.01' { return Test-B3SelfcheckEvidence @('storage.sh01','Common','Shanghai','Archive','Beijing','PASS','DENY') }
  'J1.02' { return Test-B3SelfcheckEvidence @('storage.bj01','Common','Beijing','Archive','Shanghai','PASS','DENY') }
  'J1.03' { return Test-B3SelfcheckEvidence @('auditor.b3','Common','Archive','READ','DENY') }
  'J1.04' { return Test-B3SelfcheckEvidence @('allowed.txt','blocked.exe','PASS','BLOCK') }
  'J1.05' { return Invoke-B3MeasuredCheck 'Test required C:\Skills\B3 files' {$n='B3-foundation.ps1','B3-storage-setup.ps1','B3-ad-objects.ps1','B3-iscsi.ps1','B3-shares-permissions.ps1','B3-dfs.ps1','B3-fsrm.ps1','B3-backup-restore.ps1','B3-selfcheck.txt';Get-B3SubmissionEvidence $n} {param($t)([regex]::Matches($t,'SUBMISSION_OK','IgnoreCase')).Count-eq9 -and $t-notmatch'SUBMISSION_FAIL'} 'Все девять submission files существуют и не пусты.' 'Показаны все submission files; один или несколько отсутствуют либо пусты.' }
 }
 return New-B3Result WARN "Для $AspectID evaluator ещё не определён."
}

function Test-B3RoutingDetails {param([string[]]$Prefixes,[string]$NextHop)
 return Invoke-B3MeasuredCheck 'Get-NetIPInterface; Get-NetRoute' {$forwarding=@(Get-NetIPInterface -AddressFamily IPv4|Where-Object{$_.Forwarding -eq'Enabled'});if($forwarding.Count){"ROUTING_OK item=forwarding expected=Enabled actual=Enabled interfaces=$($forwarding.InterfaceAlias -join ',')"}else{"ROUTING_FAIL item=forwarding expected=Enabled actual=Disabled"};foreach($prefix in $Prefixes){$routes=@(Get-NetRoute -DestinationPrefix $prefix -AddressFamily IPv4 -ErrorAction SilentlyContinue);$match=@($routes|Where-Object{$_.NextHop -eq$NextHop});if($match.Count){"ROUTING_OK item=route expected=$prefix via $NextHop actual=$($match[0].DestinationPrefix) via $($match[0].NextHop) interface=$($match[0].InterfaceAlias)"}else{"ROUTING_FAIL item=route expected=$prefix via $NextHop actual=$(if($routes.Count){($routes|ForEach-Object{"$($_.DestinationPrefix) via $($_.NextHop)"})-join','}else{'MISSING'})"}}} {param($t)([regex]::Matches($t,'ROUTING_OK')).Count-eq($Prefixes.Count+1) -and $t-notmatch'ROUTING_FAIL'} 'Forwarding и все обязательные routes корректны.' 'Показаны forwarding/routes; один или несколько элементов неверны.' }

function Test-B3TcpDetails {param([string[]]$Targets,[int]$Port)
 return Invoke-B3MeasuredCheck "Test-NetConnection targets TCP/$Port" {foreach($target in $Targets){$dnsOk=$true;try{Resolve-DnsName $target -ErrorAction Stop|Out-Null}catch{$dnsOk=$false};$tcp=Test-NetConnection $target -Port $Port -InformationLevel Quiet -WarningAction SilentlyContinue;if($dnsOk-and$tcp){"TCP_SERVICE_OK target=$target port=$Port dns=True tcp=True"}else{"TCP_SERVICE_FAIL target=$target port=$Port dns=$dnsOk tcp=$tcp"}}} {param($t)([regex]::Matches($t,'TCP_SERVICE_OK')).Count-eq$Targets.Count -and $t-notmatch'TCP_SERVICE_FAIL'} "DNS и TCP/$Port доступны на всех targets." "Показаны все targets; DNS или TCP/$Port недоступны." }

function Test-B3Features {param([string[]]$Names)
 return Invoke-B3MeasuredCheck "Get-WindowsFeature $($Names -join ',')" {foreach($name in $Names){try{$f=Get-WindowsFeature $name -ErrorAction Stop;if($f.InstallState-eq'Installed'){"FEATURE_OK name=$name expected=Installed actual=$($f.InstallState)"}else{"FEATURE_FAIL name=$name expected=Installed actual=$($f.InstallState)"}}catch{"FEATURE_FAIL name=$name expected=Installed actual=LOOKUP_ERROR error=$($_.Exception.Message)"}}} {param($t)([regex]::Matches($t,'FEATURE_OK')).Count-eq$Names.Count -and $t-notmatch'FEATURE_FAIL'} 'Все обязательные Windows features установлены.' 'Показаны все Windows features; одна или несколько не установлены.' }

function Test-B3Volume {param([char]$Letter,[string]$Label,[double]$MinGB,[double]$MaxGB)
 return Invoke-B3MeasuredCheck "Get-Volume $Letter; Get-Disk/Partition" {try{$v=Get-Volume -DriveLetter $Letter -ErrorAction Stop;$p=Get-Partition -DriveLetter $Letter -ErrorAction Stop;$d=$p|Get-Disk;$size=[math]::Round($v.Size/1GB,1);if($v.FileSystemLabel-eq$Label){"VOLUME_ITEM_OK drive=$Letter item=label expected=$Label actual=$($v.FileSystemLabel)"}else{"VOLUME_ITEM_FAIL drive=$Letter item=label expected=$Label actual=$($v.FileSystemLabel)"};if($v.FileSystem-eq'NTFS'){"VOLUME_ITEM_OK drive=$Letter item=filesystem expected=NTFS actual=$($v.FileSystem)"}else{"VOLUME_ITEM_FAIL drive=$Letter item=filesystem expected=NTFS actual=$($v.FileSystem)"};if($d.PartitionStyle-eq'GPT'){"VOLUME_ITEM_OK drive=$Letter item=partition_style expected=GPT actual=$($d.PartitionStyle)"}else{"VOLUME_ITEM_FAIL drive=$Letter item=partition_style expected=GPT actual=$($d.PartitionStyle)"};if($size-ge$MinGB-and$size-le$MaxGB){"VOLUME_ITEM_OK drive=$Letter item=size expected=$MinGB-$MaxGB`GB actual=$size`GB"}else{"VOLUME_ITEM_FAIL drive=$Letter item=size expected=$MinGB-$MaxGB`GB actual=$size`GB"};"VOLUME_INFO drive=$Letter bus=$($d.BusType) disk=$($d.Number) health=$($v.HealthStatus)"}catch{"VOLUME_ITEM_FAIL drive=$Letter item=existence expected=volume-present actual=NOT_FOUND error=$($_.Exception.Message)"}} {param($t)([regex]::Matches($t,'VOLUME_ITEM_OK','IgnoreCase')).Count-eq4 -and $t-notmatch'VOLUME_ITEM_FAIL'} "Volume $Letter`: корректен." "Показаны параметры volume $Letter`:; один или несколько не соответствуют заданию." }
function Test-B3AdNames {param([string]$Kind,[string[]]$Names)
 return Invoke-B3MeasuredCheck "Проверить AD objects: $($Names -join ', ')" {
  foreach($n in $Names){
   $o=$null;$lookupErrors=New-Object System.Collections.Generic.List[string]
   if($Kind -in@('OU','ALL')){
    try{$o=Get-ADOrganizationalUnit -Filter "Name -eq '$n'" -ErrorAction Stop|Select-Object -First 1}catch{$lookupErrors.Add($_.Exception.Message)}
   }
   if(-not $o -and$Kind -in@('GROUP','ALL')){
    try{$o=Get-ADGroup -Identity $n -Properties GroupScope,GroupCategory -ErrorAction Stop}catch{$lookupErrors.Add($_.Exception.Message)}
   }
   if(-not $o -and$Kind -eq'ALL'){
    try{$o=Get-ADUser -Identity $n -ErrorAction Stop}catch{$lookupErrors.Add($_.Exception.Message)}
   }
   if(-not $o){"AD_OBJECT_FAIL name=$n expected=$(if($Kind-eq'GROUP'){'Global Security group'}elseif($Kind-eq'OU'){'OU exists'}else{'required object exists'}) actual=NOT_FOUND";continue}
   $class=[string](Get-B3PropertyValue $o 'ObjectClass');$scope=[string](Get-B3PropertyValue $o 'GroupScope');$category=[string](Get-B3PropertyValue $o 'GroupCategory')
   if($Kind-eq'GROUP' -and ($scope-ne'Global' -or $category-ne'Security')){"AD_OBJECT_FAIL name=$n expected=Global/Security actual=class:$class,scope:$scope,category:$category";continue}
   "AD_OBJECT_OK name=$n expected=$(if($Kind-eq'GROUP'){'Global/Security'}elseif($Kind-eq'OU'){'OU exists'}else{'required object exists'}) actual=class:$class,scope:$scope,category:$category"
  }
 } {param($t) ([regex]::Matches($t,'AD_OBJECT_OK','IgnoreCase')).Count-eq$Names.Count -and $t-notmatch'AD_OBJECT_FAIL'} 'Все обязательные AD-объекты соответствуют заданию.' 'Показаны все AD-объекты; один или несколько отсутствуют либо имеют неверный тип/scope/category.' }
function Test-B3Membership {param([hashtable]$Map)
 return Invoke-B3MeasuredCheck 'Get-ADPrincipalGroupMembership required users' {
  foreach($u in $Map.Keys){
   try{$actual=@(Get-ADPrincipalGroupMembership $u -ErrorAction Stop|ForEach-Object{([string]$_.Name).Trim()}|Where-Object{$_}|Sort-Object -Unique)}
   catch{foreach($g in $Map[$u]){"MEMBERSHIP_FAIL user=$u expected_group=$g actual=USER_LOOKUP_ERROR error=$($_.Exception.Message)"};continue}
   foreach($g in $Map[$u]){
    $matched=@($actual|Where-Object{[string]::Equals($_,$g,[StringComparison]::OrdinalIgnoreCase)}).Count-gt0
    if($matched){"MEMBERSHIP_OK user=$u expected_group=$g actual=present"}
    else{"MEMBERSHIP_FAIL user=$u expected_group=$g actual=missing memberships=$($actual -join ',')"}
   }
   foreach($group in $actual){if($Map[$u] -notcontains $group){"MEMBERSHIP_INFO user=$u additional_group=$group"}}
  }
 } {param($t) $expectedCount=0;foreach($u in $Map.Keys){$expectedCount+=@($Map[$u]).Count};([regex]::Matches($t,'MEMBERSHIP_OK','IgnoreCase')).Count-eq$expectedCount -and $t-notmatch'MEMBERSHIP_FAIL'} 'Все обязательные membership соответствуют заданию.' 'Показаны все membership; одна или несколько обязательных групп отсутствуют.' }
function Test-B3Shares {param([hashtable]$Map)
 return Invoke-B3MeasuredCheck 'Get-SmbShare and Test-Path required shares' {foreach($n in $Map.Keys){$wanted=$Map[$n];try{$s=Get-SmbShare -Name $n -ErrorAction Stop;$exists=Test-Path -LiteralPath $wanted;$pathOk=[string]::Equals([string]$s.Path,[string]$wanted,[StringComparison]::OrdinalIgnoreCase);if($pathOk-and$exists){"SHARE_OK name=$n expected_path=$wanted actual_path=$($s.Path) path_exists=$exists abe=$($s.FolderEnumerationMode)"}else{"SHARE_FAIL name=$n expected_path=$wanted actual_path=$($s.Path) path_exists=$exists abe=$($s.FolderEnumerationMode)"}}catch{"SHARE_FAIL name=$n expected_path=$wanted actual=NOT_FOUND error=$($_.Exception.Message)"}}} {param($t)([regex]::Matches($t,'SHARE_OK','IgnoreCase')).Count-eq$Map.Count -and $t-notmatch'SHARE_FAIL'} 'Все shares и пути корректны.' 'Показаны все shares; один или несколько отсутствуют либо указывают на неверный путь.' }
function Test-B3Acl {param([string]$Path,[string]$Share,[string[]]$Principals)
 return Invoke-B3MeasuredCheck "Get-Acl $Path; Get-SmbShareAccess $Share" {
  try{$ntfs=@((Get-Acl -LiteralPath $Path -ErrorAction Stop).Access);$smb=@(Get-SmbShareAccess -Name $Share -ErrorAction Stop)}catch{foreach($p in $Principals){"ACL_PRINCIPAL_FAIL path=$Path share=$Share principal=$p expected=required-rights actual=LOOKUP_ERROR error=$($_.Exception.Message)"};return}
  foreach($p in $Principals){
   $ntfsEntries=@($ntfs|Where-Object{([string]$_.IdentityReference)-match('(?i)(^|\\)'+[regex]::Escape($p)+'$') -and $_.AccessControlType-eq'Allow'})
   $smbEntries=@($smb|Where-Object{([string]$_.AccountName)-match('(?i)(^|\\)'+[regex]::Escape($p)+'$') -and $_.AccessControlType-eq'Allow'})
   $expectedNtfs=if($p-match'(?i)Domain Admins'){'FullControl'}elseif($p-match'(?i)_RO$'){'ReadAndExecute'}else{'Modify'}
   $ntfsOk=@($ntfsEntries|Where-Object{([string]$_.FileSystemRights)-match[regex]::Escape($expectedNtfs)}).Count-gt0
   $smbOk=$smbEntries.Count-gt0
   $actualNtfs=if($ntfsEntries.Count){($ntfsEntries|ForEach-Object{$_.FileSystemRights})-join','}else{'MISSING'}
   $actualSmb=if($smbEntries.Count){($smbEntries|ForEach-Object{$_.AccessRight})-join','}else{'MISSING'}
   if($ntfsOk-and$smbOk){"ACL_PRINCIPAL_OK path=$Path share=$Share principal=$p expected_ntfs=$expectedNtfs actual_ntfs=$actualNtfs actual_share=$actualSmb"}
   else{"ACL_PRINCIPAL_FAIL path=$Path share=$Share principal=$p expected_ntfs=$expectedNtfs expected_share=Allow actual_ntfs=$actualNtfs actual_share=$actualSmb"}
  }
 } {param($t)([regex]::Matches($t,'ACL_PRINCIPAL_OK','IgnoreCase')).Count-eq$Principals.Count -and $t-notmatch'ACL_PRINCIPAL_FAIL'} 'Все обязательные principals и права найдены в NTFS/share ACL.' 'Показаны все обязательные principals; одна или несколько NTFS/share ACL entries отсутствуют либо неверны.' }
function Test-B3Feature {param([string]$Name)
 return Invoke-B3MeasuredCheck "Get-WindowsFeature $Name" {try{$f=Get-WindowsFeature $Name -ErrorAction Stop;if($f.InstallState-eq'Installed'){"FEATURE_OK name=$Name expected=Installed actual=$($f.InstallState)"}else{"FEATURE_FAIL name=$Name expected=Installed actual=$($f.InstallState)"}}catch{"FEATURE_FAIL name=$Name expected=Installed actual=NOT_FOUND error=$($_.Exception.Message)"}} {param($t)$t-match'FEATURE_OK' -and $t-notmatch'FEATURE_FAIL'} "Feature $Name установлен." "Feature $Name не установлен." }
function Test-B3DfsTargets {param([string]$Path,[string[]]$Targets)
 return Invoke-B3MeasuredCheck "Get-DfsnFolderTarget $Path" {try{$actual=@(Get-DfsnFolderTarget -Path $Path -ErrorAction Stop);foreach($wanted in $Targets){$m=@($actual|Where-Object{[string]::Equals([string]$_.TargetPath,$wanted,[StringComparison]::OrdinalIgnoreCase)});if($m.Count){"DFS_TARGET_OK path=$Path expected=$wanted actual=$($m[0].TargetPath) state=$($m[0].State)"}else{"DFS_TARGET_FAIL path=$Path expected=$wanted actual=MISSING"}};foreach($item in $actual){if($Targets -notcontains $item.TargetPath){"DFS_TARGET_FAIL path=$Path expected=no-extra-target actual=$($item.TargetPath) state=$($item.State)"}}}catch{"DFS_TARGET_FAIL path=$Path expected=$($Targets -join ',') actual=LOOKUP_ERROR error=$($_.Exception.Message)"}} {param($t)([regex]::Matches($t,'DFS_TARGET_OK','IgnoreCase')).Count-eq$Targets.Count -and $t-notmatch'DFS_TARGET_FAIL'} 'DFS targets совпадают точно.' 'Показаны все DFS targets; обязательные targets неполны либо присутствуют лишние.' }
function Test-B3DfsTargetMap {param([System.Collections.IDictionary]$Map)
 return Invoke-B3MeasuredCheck 'Get-DfsnFolderTarget required folders' {foreach($path in $Map.Keys){$wanted=$Map[$path];try{$actual=@(Get-DfsnFolderTarget -Path $path -ErrorAction Stop);$m=@($actual|Where-Object{[string]::Equals([string]$_.TargetPath,$wanted,[StringComparison]::OrdinalIgnoreCase)});if($m.Count-eq1-and$actual.Count-eq1){"DFS_TARGET_OK path=$path expected=$wanted actual=$($m[0].TargetPath) state=$($m[0].State)"}else{"DFS_TARGET_FAIL path=$path expected=exactly:$wanted actual=$(if($actual.Count){$actual.TargetPath -join ','}else{'MISSING'})"}}catch{"DFS_TARGET_FAIL path=$path expected=$wanted actual=LOOKUP_ERROR error=$($_.Exception.Message)"}}} {param($t)([regex]::Matches($t,'DFS_TARGET_OK')).Count-eq$Map.Count -and $t-notmatch'DFS_TARGET_FAIL'} 'Все DFS folder targets соответствуют карте.' 'Показаны все DFS folder targets; один или несколько неверны.' }
function Test-B3SelfcheckEvidence {param([string[]]$Terms)
 return Invoke-B3MeasuredCheck 'Get-Content C:\Skills\B3\B3-selfcheck.txt' {if(-not(Test-Path C:\Skills\B3\B3-selfcheck.txt)){foreach($x in $Terms){"SELFCHECK_TERM_FAIL term=$x actual=file-not-found"};return};$content=Get-Content C:\Skills\B3\B3-selfcheck.txt -Raw;foreach($x in $Terms){if($content-match[regex]::Escape($x)){"SELFCHECK_TERM_OK term=$x"}else{"SELFCHECK_TERM_FAIL term=$x"}}} {param($t)([regex]::Matches($t,'SELFCHECK_TERM_OK','IgnoreCase')).Count-eq$Terms.Count -and $t-notmatch'SELFCHECK_TERM_FAIL'} 'Selfcheck содержит требуемые functional results.' 'Показаны все обязательные terms; selfcheck содержит не полный набор результатов.' }

function Invoke-B3Aspect {
    param([string]$HostKey, [object]$Aspect)
    $evaluatorId = $Aspect.AspectID
    if ($Aspect.PSObject.Properties.Name -contains 'OriginalAspectID' -and
        -not [string]::IsNullOrWhiteSpace($Aspect.OriginalAspectID)) {
        $evaluatorId = $Aspect.OriginalAspectID
    }
    return Test-B3StorageAspect -HostKey $HostKey -AspectID $evaluatorId
}

function Write-B3Summary {
    $total=0.0; $passed=0.0; $failed=0.0; $warn=0.0
    foreach ($row in @($script:B3Rows)) {
        $mark=[double]$row.MaxMark; $total += $mark
        switch ($row.Status) { 'PASS' {$passed += $mark}; 'FAIL' {$failed += $mark}; default {$warn += $mark} }
    }
    $lines = @(
        'B3 Local Evaluation Summary',
        '===========================',
        "Passed marks: $([Math]::Round($passed,2)) / $([Math]::Round($total,2))",
        "Failed marks: $([Math]::Round($failed,2))",
        "Warn marks:   $([Math]::Round($warn,2))",
        'Итог относится только к локальным аспектам этого хоста; повторные cross-host аспекты не суммируются между хостами.'
    )
    Write-Host ''
    Write-B3Log ($lines -join [Environment]::NewLine) DarkGray
    if ($script:B3ReportEnabled) { Set-Content -LiteralPath $script:B3SummaryPath -Value ($lines -join [Environment]::NewLine) -Encoding UTF8 }
}

function Invoke-B3HostChecks {
    param(
        [Parameter(Mandatory=$true)][string]$HostKey,
        [switch]$Report,
        [string]$ReportDir,
        [switch]$NoPause,
        [string]$StartFromAspect
    )
    $HostKey = $HostKey.ToUpperInvariant()
    $script:B3PauseBetweenChecks = -not $NoPause
    Initialize-B3Report -HostKey $HostKey -Report:$Report -ReportDir $ReportDir
    Write-B3Section "B3 local checks for $HostKey"
    Write-B3Log "B3 checker version: $script:B3Version" Green
    Write-B3Log "B3 common: $PSCommandPath" DarkGray
    Write-B3Log "B3 criteria: $script:B3CriteriaPath" DarkGray
    if ($script:B3ReportEnabled) { Write-B3Log "Каталог отчета: $script:B3ReportDir" DarkGray }
    else { Write-B3Log 'Отчет отключен. Для записи используйте -Report или -ReportDir <path>.' DarkGray }

    $criteria = @(Get-B3Criteria -HostKey $HostKey)
    if ($criteria.Count -eq 0) { throw "Для хоста $HostKey не найдены локальные критерии B3." }
    foreach ($aspect in $criteria) {
        if (-not [string]::IsNullOrWhiteSpace($StartFromAspect) -and [string]::Compare($aspect.AspectID,$StartFromAspect,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        Start-B3Aspect $aspect
        try {
            $result = Invoke-B3Aspect -HostKey $HostKey -Aspect $aspect
            if ($null -eq $result -or @($result).Count -lt 2) { throw "Evaluator $($aspect.AspectID) не вернул результат." }
            Complete-B3Aspect -Aspect $aspect -Status $result[0] -Message $result[1]
        } catch {
            $exceptionText = $_.Exception.ToString()
            $exceptionMessage = $_.Exception.Message
            Invoke-B3Evidence 'Unhandled checker exception' { $exceptionText } | Out-Null
            Complete-B3Aspect -Aspect $aspect -Status WARN -Message "Ошибка checker: $exceptionMessage"
        }
    }
    Write-B3Summary
}




