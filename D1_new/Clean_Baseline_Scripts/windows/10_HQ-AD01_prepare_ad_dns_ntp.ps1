# D1 clean baseline: AD DS, DNS and NTP on HQ-AD01 (PDF role: "AD DS, DNS, NTP").
# Run after 00_D1_common_windows_prepare.ps1 -NodeName HQ-AD01 and a reboot if the
# computer name changed. Run as Administrator. Promoting the forest reboots the server;
# re-run this script after that reboot to finish the DNS records and NTP config.
#
# A single DNS zone (skill39.d1) is used for every host, HQ and DC alike, because the
# taskbook PDF uses one flat FQDN suffix (e.g. dc-lnx01.skill39.d1) for the whole lab -
# there is no corp/dc/cloud sub-domain split in the taskbook.
$DomainName = 'skill39.d1'
$Netbios = 'D1SKILL'
$SafeModePassword = ConvertTo-SecureString 'Skill39@D1' -AsPlainText -Force
Install-WindowsFeature AD-Domain-Services,DNS -IncludeManagementTools

Import-Module ADDSDeployment
$ComputerSystem = Get-CimInstance Win32_ComputerSystem
$NtdsService = Get-Service NTDS -ErrorAction SilentlyContinue
$IsDomainController = (
    $ComputerSystem.PartOfDomain -and
    $ComputerSystem.Domain -ieq $DomainName -and
    $null -ne $NtdsService
)

if (-not $IsDomainController) {
    Write-Host "This server is not yet a domain controller for $DomainName. Creating a new forest."
    Install-ADDSForest -DomainName $DomainName -DomainNetbiosName $Netbios -SafeModeAdministratorPassword $SafeModePassword -InstallDns -Force
    return
}

Import-Module ActiveDirectory
$AdwsService = Get-Service ADWS -ErrorAction Stop
if ($AdwsService.Status -ne 'Running') {
    Start-Service ADWS
    $AdwsService.WaitForStatus('Running', [TimeSpan]::FromSeconds(60))
}

try {
    $null = Get-ADDomain -Identity $DomainName -Server localhost -ErrorAction Stop
}
catch {
    throw "Domain $DomainName or AD Web Services is not ready yet. Reboot the server and re-run this script. $($_.Exception.Message)"
}

New-ADOrganizationalUnit -Name 'D1-Users' -Path 'DC=skill39,DC=d1' -ErrorAction SilentlyContinue
New-ADOrganizationalUnit -Name 'D1-Computers' -Path 'DC=skill39,DC=d1' -ErrorAction SilentlyContinue
foreach ($u in @('operator','analyst','student')) {
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$u'" -ErrorAction SilentlyContinue)) {
        New-ADUser -Name $u -SamAccountName $u -AccountPassword (ConvertTo-SecureString 'Skill39@D1' -AsPlainText -Force) -Enabled $true -Path 'OU=D1-Users,DC=skill39,DC=d1'
    }
}

# Hosts and services table (PDF section 4) - one A record per host, all in skill39.d1.
$records = @(
    @{Name='hq-ws01';    IP='10.19.10.10'},
    @{Name='hq-ad01';    IP='10.19.20.10'},
    @{Name='hq-file01';  IP='10.19.20.20'},
    @{Name='hq-lnx01';   IP='10.19.20.30'},
    @{Name='dc-lnx01';   IP='10.21.10.10'},
    @{Name='dc-lnx02';   IP='10.21.10.20'},
    @{Name='dc-cl01';    IP='10.21.10.30'},
    @{Name='dc-win01';   IP='10.21.10.40'},
    @{Name='dc-svc01';   IP='10.21.10.50'},
    @{Name='dc1.cloud';  IP='10.201.1.1'},
    @{Name='dc2.cloud';  IP='10.201.2.1'}
)
foreach ($r in $records) {
    Add-DnsServerResourceRecordA -ZoneName $DomainName -Name $r.Name -IPv4Address $r.IP -CreatePtr -ErrorAction SilentlyContinue
}

# NTP (PDF role: HQ-AD01 also provides NTP).
w32tm /config /manualpeerlist:"0.pool.ntp.org 1.pool.ntp.org" /syncfromflags:manual /reliable:YES /update
Restart-Service w32time -ErrorAction SilentlyContinue

New-Item -ItemType Directory -Path C:\D1-Baseline -Force | Out-Null
'D1_HQ_AD01_READY' | Set-Content C:\D1-Baseline\ad-ready.txt
