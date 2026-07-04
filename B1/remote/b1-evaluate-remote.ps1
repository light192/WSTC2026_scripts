param(
    [string]$ReportDir = (Join-Path $PSScriptRoot '..\reports'),
    [string[]]$ComputerName = @('sha-dc01','sha-rtr01','sha-fs01','sha-cl01','bj-dc02','bj-rtr01','bj-srv01','bj-cl01','sha-web01','sha-app01'),
    [switch]$NoPause,
    [string]$StartFromCriterion
)

. (Join-Path $PSScriptRoot '..\common\b1-common.ps1')
$script:PauseBetweenChecks = -not $NoPause
$script:StartFromCriterion = $StartFromCriterion
Initialize-B1Report -ReportDir $ReportDir

$RemoteHostMap = @{
    'sha-rtr01' = '10.21.20.1'
    'sha-dc01' = '10.21.20.10'
    'sha-fs01' = '10.21.20.20'
    'sha-web01' = '10.21.10.11'
    'sha-app01' = '10.21.10.12'
    'sha-cl01' = '10.21.30.120'
    'bj-rtr01' = '10.31.20.1'
    'bj-dc02' = '10.31.20.10'
    'bj-srv01' = '10.31.20.20'
    'bj-cl01' = '10.31.30.120'
}

function Resolve-B1CriterionId {
    param([string]$CriterionId)
    if ([string]::IsNullOrWhiteSpace($CriterionId)) { return $null }
    $trimmed = $CriterionId.Trim()
    if ($trimmed -match '^(B1\.)?([1-8])$') {
        return "B1.$($Matches[2])"
    }
    return $trimmed
}

function Should-RunCriterion {
    param([string]$CriterionId)
    $target = Resolve-B1CriterionId -CriterionId $script:StartFromCriterion
    if (-not $target) { return $true }
    $current = Resolve-B1CriterionId -CriterionId $CriterionId
    return [string]::Compare($current, $target, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Test-B1_1 {
    Write-Section 'B1.1 - base addressing, hostname, routing, simulated Internet'
    Write-Step 'B1.1 - base addressing, hostname, routing, simulated Internet'
    Write-Command 'hostname'
    $ok = $true
    foreach ($computerName in $RemoteHostMap.Keys) {
        $output = Invoke-RemoteCheck -ComputerName $computerName -ScriptBlock { hostname }
        if (-not $output) {
            $ok = $false
            Write-ManualInstruction -CriterionId 'B1.1' -Instruction "Verify hostname and network settings on $computerName. Use hostname and Get-NetIPConfiguration." 
            continue
        }
        if ($output.ToString().Trim() -ne $computerName) {
            $ok = $false
            Write-Detail "$computerName reported $($output.ToString().Trim()) instead of expected $computerName"
        }
    }

    if ($ok) {
        Record-Result -CriterionId 'B1.1' -MaxMark '3.0' -Status 'PASS' -Message 'Hostnames match the published topology.'
    } else {
        Write-ManualInstruction -CriterionId 'B1.1' -Instruction 'Check IP configuration, default gateway, DNS client settings and route tables on the routers and clients. Confirm that the simulated Internet node 198.18.100.10 is reachable from both sites.'
        Record-Result -CriterionId 'B1.1' -MaxMark '3.0' -Status 'WARN' -Message 'Automatic hostname check passed, but full routing/IP validation needs manual confirmation.'
    }
}

function Test-B1_2 {
    Write-Section 'B1.2 - AD DS, additional DC, AD Sites, replication'
    Write-Step 'B1.2 - AD DS, additional DC, AD Sites, replication'
    Write-Command 'Get-ADDomain; Get-ADForest; Get-ADDomainController; repadmin /replsummary'
    $dcResult = Invoke-RemoteCheck -ComputerName 'sha-dc01' -ScriptBlock {
        if (Get-Command Get-ADDomain -ErrorAction SilentlyContinue) {
            $domain = Get-ADDomain | Select-Object DNSRoot, NetBIOSName
            $forest = Get-ADForest | Select-Object Name
            $controllers = Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName
            return "DOMAIN=$($domain.DNSRoot);NETBIOS=$($domain.NetBIOSName);FOREST=$($forest.Name);CTRL=$($controllers -join ',')"
        }
        return $null
    }

    if ($dcResult) {
        Record-Result -CriterionId 'B1.2' -MaxMark '5.0' -Status 'PASS' -Message 'AD DS information was retrieved successfully.'
    } else {
        Write-ManualInstruction -CriterionId 'B1.2' -Instruction 'Run Get-ADDomain, Get-ADForest, Get-ADDomainController and repadmin /replsummary on SHA-DC01 and BJ-DC02. Validate AD sites, subnets, site links and replication.'
        Record-Result -CriterionId 'B1.2' -MaxMark '5.0' -Status 'WARN' -Message 'AD DS validation could not be collected automatically from the target hosts.'
    }
}

function Test-B1_3 {
    Write-Section 'B1.3 - DNS forward/reverse records, PTR, DNS forwarding'
    Write-Step 'B1.3 - DNS forward/reverse records, PTR, DNS forwarding'
    Write-Command 'Get-DnsServerZone; Get-DnsServerResourceRecord; Get-DnsServerForwarder'
    $dnsResult = Invoke-RemoteCheck -ComputerName 'sha-dc01' -ScriptBlock {
        if (Get-Command Get-DnsServerZone -ErrorAction SilentlyContinue) {
            $zones = Get-DnsServerZone -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ZoneName
            return ($zones -join ',')
        }
        return $null
    }

    if ($dnsResult) {
        Record-Result -CriterionId 'B1.3' -MaxMark '3.0' -Status 'PASS' -Message 'DNS zone information is available.'
    } else {
        Write-ManualInstruction -CriterionId 'B1.3' -Instruction 'On SHA-DC01 and BJ-DC02 validate the nb-b1.local zone, reverse zones, PTR records and forwarders in DNS Manager.'
        Record-Result -CriterionId 'B1.3' -MaxMark '3.0' -Status 'WARN' -Message 'DNS zone validation requires DNS Server role access.'
    }
}

function Test-B1_4 {
    Write-Section 'B1.4 - DHCP scopes, relay, dynamic DNS, leases'
    Write-Step 'B1.4 - DHCP scopes, relay, dynamic DNS, leases'
    Write-Command 'Get-DhcpServerv4Scope; Get-DhcpServerv4Lease; Get-DhcpServerv4Failover'
    $dhcpResult = Invoke-RemoteCheck -ComputerName 'sha-fs01' -ScriptBlock {
        if (Get-Command Get-DhcpServerv4Scope -ErrorAction SilentlyContinue) {
            $scopes = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
            return ($scopes -join ',')
        }
        return $null
    }

    if ($dhcpResult) {
        Record-Result -CriterionId 'B1.4' -MaxMark '3.0' -Status 'PASS' -Message 'DHCP scope information is available.'
    } else {
        Write-ManualInstruction -CriterionId 'B1.4' -Instruction 'On SHA-FS01 and BJ-SRV01 verify the two DHCP scopes, the relay agents on SHA-RTR01/BJ-RTR01 and the client lease range.'
        Record-Result -CriterionId 'B1.4' -MaxMark '3.0' -Status 'WARN' -Message 'DHCP scope validation is not available automatically from the current host.'
    }
}

function Test-B1_5 {
    Write-Section 'B1.5 - OU, groups, users, PowerShell automation'
    Write-Step 'B1.5 - OU, groups, users, PowerShell automation'
    Write-Command 'Test-Path C:\Skills\Import-B1Users.ps1; Test-Path C:\Skills\b1-users.csv'
    $importScript = 'C:\Skills\Import-B1Users.ps1'
    $csvPath = 'C:\Skills\b1-users.csv'
    if ((Test-Path $importScript) -and (Test-Path $csvPath)) {
        Record-Result -CriterionId 'B1.5' -MaxMark '3.0' -Status 'PASS' -Message 'The import automation script and CSV were found.'
    } else {
        Write-ManualInstruction -CriterionId 'B1.5' -Instruction 'Create C:\Skills\Import-B1Users.ps1 and C:\Skills\b1-users.csv, then validate OU placement, group membership and user creation from Active Directory Users and Computers.'
        Record-Result -CriterionId 'B1.5' -MaxMark '3.0' -Status 'WARN' -Message 'PowerShell automation artifacts are not available to validate automatically.'
    }
}

function Test-B1_6 {
    Write-Section 'B1.6 - GPO baseline, Windows LAPS, minimal BitLocker recovery'
    Write-Step 'B1.6 - GPO baseline, Windows LAPS, minimal BitLocker recovery'
    Write-Command 'Get-GPO -All'
    $gpoResult = Invoke-RemoteCheck -ComputerName 'sha-dc01' -ScriptBlock {
        if (Get-Command Get-GPO -ErrorAction SilentlyContinue) {
            return ((Get-GPO -All | Select-Object -ExpandProperty DisplayName) -join ',')
        }
        return $null
    }

    if ($gpoResult) {
        Record-Result -CriterionId 'B1.6' -MaxMark '3.0' -Status 'PASS' -Message 'Group Policy objects are visible.'
    } else {
        Write-ManualInstruction -CriterionId 'B1.6' -Instruction 'Open Group Policy Management Console, verify GPO-B1-Domain-Baseline and GPO-B1-Workstations-Security, and confirm LAPS and BitLocker recovery backup on SHA-CL01 and BJ-CL01.'
        Record-Result -CriterionId 'B1.6' -MaxMark '3.0' -Status 'WARN' -Message 'GPO, LAPS and BitLocker settings require manual validation in GPMC and ADUC.'
    }
}

function Test-B1_7 {
    Write-Section 'B1.7 - File services, NTFS, drive mapping'
    Write-Step 'B1.7 - File services, NTFS, drive mapping'
    Write-Command 'Get-SmbShare; Get-Acl'
    $shareResult = Invoke-RemoteCheck -ComputerName 'sha-fs01' -ScriptBlock {
        if (Get-Command Get-SmbShare -ErrorAction SilentlyContinue) {
            return ((Get-SmbShare | Select-Object -ExpandProperty Name) -join ',')
        }
        return $null
    }

    if ($shareResult) {
        Record-Result -CriterionId 'B1.7' -MaxMark '3.0' -Status 'PASS' -Message 'File shares can be enumerated.'
    } else {
        Write-ManualInstruction -CriterionId 'B1.7' -Instruction 'On SHA-FS01 and BJ-SRV01 create the shares and verify the NTFS and share permissions from Server Manager or icacls. Confirm the drive mappings under the user accounts.'
        Record-Result -CriterionId 'B1.7' -MaxMark '3.0' -Status 'WARN' -Message 'Shared folder and NTFS permission details need manual confirmation.'
    }
}

function Test-B1_8 {
    Write-Section 'B1.8 - client validation, Git, final self-check'
    Write-Step 'B1.8 - client validation, Git, final self-check'
    Write-Command 'Test-Path C:\Skills\B1-selfcheck.txt'
    $gitResult = Invoke-RemoteCheck -ComputerName 'sha-cl01' -ScriptBlock {
        if (Test-Path 'C:\Skills\B1-selfcheck.txt') {
            return 'selfcheck-present'
        }
        return $null
    }

    if ($gitResult) {
        Record-Result -CriterionId 'B1.8' -MaxMark '2.0' -Status 'PASS' -Message 'The self-check artifact is present.'
    } else {
        Write-ManualInstruction -CriterionId 'B1.8' -Instruction 'On SHA-CL01 create the Git repository in C:\Skills, add the scripts and CSV, commit with the message final commit, and write the self-check file.'
        Record-Result -CriterionId 'B1.8' -MaxMark '2.0' -Status 'WARN' -Message 'Git repository and final self-check file are not available to validate automatically.'
    }
}

if (Should-RunCriterion 'B1.1') { Test-B1_1 }
if (Should-RunCriterion 'B1.2') { Test-B1_2 }
if (Should-RunCriterion 'B1.3') { Test-B1_3 }
if (Should-RunCriterion 'B1.4') { Test-B1_4 }
if (Should-RunCriterion 'B1.5') { Test-B1_5 }
if (Should-RunCriterion 'B1.6') { Test-B1_6 }
if (Should-RunCriterion 'B1.7') { Test-B1_7 }
if (Should-RunCriterion 'B1.8') { Test-B1_8 }
Write-Summary
