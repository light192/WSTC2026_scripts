param(
    [string]$ReportDir = (Join-Path $PSScriptRoot '..\reports'),
    [switch]$NoPause,
    [string]$StartFromCriterion
)

. (Join-Path $PSScriptRoot '..\common\b1-common.ps1')
$script:PauseBetweenChecks = -not $NoPause
$script:StartFromCriterion = $StartFromCriterion
Initialize-B1Report -ReportDir $ReportDir

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

function Test-B1LocalHost {
    Write-Section 'B1 local host self-check'
    $hostName = hostname
    $computerSystem = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $ipConfig = Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4Address }

    if (Should-RunCriterion 'B1.1') {
        Write-Step 'B1.1 - базовая адресация и hostname'
        Write-Command 'hostname'
        if ($hostName -match '^(SHA|BJ)') {
            Record-Result -CriterionId 'B1.1' -MaxMark '3.0' -Status 'PASS' -Message "Local host $hostName is reachable and reports basic network information."
        } else {
            Write-ManualInstruction -CriterionId 'B1.1' -Instruction 'Run the remote evaluator from the administration host or validate hostnames and IP configuration manually on the target VM.'
            Record-Result -CriterionId 'B1.1' -MaxMark '3.0' -Status 'WARN' -Message 'Host role could not be identified automatically; manual validation required.'
        }
    }

    if (Should-RunCriterion 'B1.2') {
        Write-Step 'B1.2 - AD DS, sites и replication'
        Write-Command 'Get-Command Get-ADDomain'
        if (Get-Command Get-ADDomain -ErrorAction SilentlyContinue) {
            Record-Result -CriterionId 'B1.2' -MaxMark '5.0' -Status 'PASS' -Message 'AD cmdlets are available on this host.'
        } else {
            Write-ManualInstruction -CriterionId 'B1.2' -Instruction 'On a domain controller, run Get-ADDomain, Get-ADForest and repadmin /replsummary to verify AD DS, sites and replication.'
            Record-Result -CriterionId 'B1.2' -MaxMark '5.0' -Status 'WARN' -Message 'AD checks need to be run from a domain controller.'
        }
    }

    if (Should-RunCriterion 'B1.3') {
        Write-Step 'B1.3 - DNS forward/reverse records и PTR'
        Write-Command 'Get-Command Get-DnsServerZone'
        if (Get-Command Get-DnsServerZone -ErrorAction SilentlyContinue) {
            Record-Result -CriterionId 'B1.3' -MaxMark '3.0' -Status 'PASS' -Message 'DNS Server cmdlets are available.'
        } else {
            Write-ManualInstruction -CriterionId 'B1.3' -Instruction 'On SHA-DC01 and BJ-DC02 verify DNS zones, records, PTRs and forwarders in DNS Manager.'
            Record-Result -CriterionId 'B1.3' -MaxMark '3.0' -Status 'WARN' -Message 'DNS checks require DNS Server role and manual validation.'
        }
    }

    if (Should-RunCriterion 'B1.4') {
        Write-Step 'B1.4 - DHCP scopes, relay и leases'
        Write-Command 'Get-Command Get-DhcpServerv4Scope'
        if ((Get-Command Get-DhcpServerv4Scope -ErrorAction SilentlyContinue) -or (Test-Path 'C:\Windows\System32\dhcp.exe')) {
            Record-Result -CriterionId 'B1.4' -MaxMark '3.0' -Status 'PASS' -Message 'DHCP cmdlets or binaries are present.'
        } else {
            Write-ManualInstruction -CriterionId 'B1.4' -Instruction 'On SHA-FS01 and BJ-SRV01 validate DHCP scopes, relay and client leases in DHCP Manager.'
            Record-Result -CriterionId 'B1.4' -MaxMark '3.0' -Status 'WARN' -Message 'DHCP validation is not available on this host.'
        }
    }

    if (Should-RunCriterion 'B1.5') {
        Write-Step 'B1.5 - OU, groups, users и automation'
        Write-Command 'Test-Path C:\Skills\Import-B1Users.ps1'
        $importScript = 'C:\Skills\Import-B1Users.ps1'
        $csvPath = 'C:\Skills\b1-users.csv'
        if ((Test-Path $importScript) -and (Test-Path $csvPath)) {
            Record-Result -CriterionId 'B1.5' -MaxMark '3.0' -Status 'PASS' -Message 'The import script and CSV are present.'
        } else {
            Write-ManualInstruction -CriterionId 'B1.5' -Instruction 'Create C:\Skills\Import-B1Users.ps1 and C:\Skills\b1-users.csv, then verify OU/group membership by running the script.'
            Record-Result -CriterionId 'B1.5' -MaxMark '3.0' -Status 'WARN' -Message 'Automation artifacts were not found locally.'
        }
    }

    if (Should-RunCriterion 'B1.6') {
        Write-Step 'B1.6 - GPO baseline, LAPS и BitLocker'
        Write-Command 'Get-Command Get-GPO'
        if (Get-Command Get-GPO -ErrorAction SilentlyContinue) {
            Record-Result -CriterionId 'B1.6' -MaxMark '3.0' -Status 'PASS' -Message 'Group Policy cmdlets are available.'
        } else {
            Write-ManualInstruction -CriterionId 'B1.6' -Instruction 'Open Group Policy Management and confirm the three GPOs; check LAPS and BitLocker recovery backup on the workstation OU.'
            Record-Result -CriterionId 'B1.6' -MaxMark '3.0' -Status 'WARN' -Message 'GPO/LAPS/BitLocker checks require the GPMC or RSAT tools.'
        }
    }

    if (Should-RunCriterion 'B1.7') {
        Write-Step 'B1.7 - file services, NTFS и drive mapping'
        Write-Command 'Get-Command Get-SmbShare'
        if ((Get-Command Get-SmbShare -ErrorAction SilentlyContinue) -or (Test-Path '\\files.nb-b1.local\Common')) {
            Record-Result -CriterionId 'B1.7' -MaxMark '3.0' -Status 'PASS' -Message 'File-services information is available.'
        } else {
            Write-ManualInstruction -CriterionId 'B1.7' -Instruction 'On SHA-FS01 and BJ-SRV01 create the shares and validate NTFS and share permissions from File Explorer or icacls.'
            Record-Result -CriterionId 'B1.7' -MaxMark '3.0' -Status 'WARN' -Message 'Share/NTFS validation could not be completed automatically.'
        }
    }

    if (Should-RunCriterion 'B1.8') {
        Write-Step 'B1.8 - client validation, Git и self-check'
        Write-Command 'Test-Path C:\Skills\B1-selfcheck.txt'
        if ((Test-Path 'C:\Skills\B1-selfcheck.txt') -and (Get-Command git -ErrorAction SilentlyContinue)) {
            Record-Result -CriterionId 'B1.8' -MaxMark '2.0' -Status 'PASS' -Message 'Git and self-check artifacts are present.'
        } else {
            Write-ManualInstruction -CriterionId 'B1.8' -Instruction 'Create the Git repository in C:\Skills, commit the scripts, and record the final self-check commands in B1-selfcheck.txt.'
            Record-Result -CriterionId 'B1.8' -MaxMark '2.0' -Status 'WARN' -Message 'Git repository or self-check artifact is missing.'
        }
    }
}

Test-B1LocalHost
Write-Summary


