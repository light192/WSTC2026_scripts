# Чистая базовая конфигурация D1: AD DS, DNS и DHCP на HQ-AD01.
# Запустите после 00_D1_common_windows_prepare.ps1 -NodeName HQ-AD01 и перезагрузки, если имя компьютера было изменено.
# Запустите от имени администратора. При повышении роли этот скрипт может перезагрузить сервер.
$DomainName = 'corp.d1.skills'
$Netbios = 'D1CORP'
$SafeModePassword = ConvertTo-SecureString 'Skill39@D1' -AsPlainText -Force
Install-WindowsFeature AD-Domain-Services,DNS,DHCP -IncludeManagementTools

Import-Module ADDSDeployment
$ComputerSystem = Get-CimInstance Win32_ComputerSystem
$NtdsService = Get-Service NTDS -ErrorAction SilentlyContinue
$IsDomainController = (
    $ComputerSystem.PartOfDomain -and
    $ComputerSystem.Domain -ieq $DomainName -and
    $null -ne $NtdsService
)

if (-not $IsDomainController) {
    Write-Host "Сервер ещё не является контроллером домена $DomainName. Запускается создание нового леса."
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
    throw "Домен $DomainName или служба AD Web Services ещё не готовы. Перезагрузите сервер и повторно запустите скрипт. $($_.Exception.Message)"
}

New-ADOrganizationalUnit -Name 'D1-Users' -Path 'DC=corp,DC=d1,DC=skills' -ErrorAction SilentlyContinue
New-ADOrganizationalUnit -Name 'D1-Computers' -Path 'DC=corp,DC=d1,DC=skills' -ErrorAction SilentlyContinue
foreach ($u in @('operator','analyst','student')) {
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$u'" -ErrorAction SilentlyContinue)) {
        New-ADUser -Name $u -SamAccountName $u -AccountPassword (ConvertTo-SecureString 'Skill39@D1' -AsPlainText -Force) -Enabled $true -Path 'OU=D1-Users,DC=corp,DC=d1,DC=skills'
    }
}
Add-DnsServerPrimaryZone -Name 'dc.d1.skills' -ReplicationScope 'Forest' -ErrorAction SilentlyContinue
Add-DnsServerPrimaryZone -Name 'cloud.d1.skills' -ReplicationScope 'Forest' -ErrorAction SilentlyContinue
$records = @(
    @{Zone='corp.d1.skills';Name='hq-ad01';IP='10.19.20.10'},
    @{Zone='corp.d1.skills';Name='hq-file01';IP='10.19.20.20'},
    @{Zone='corp.d1.skills';Name='hq-lnx01';IP='10.19.20.30'},
    @{Zone='corp.d1.skills';Name='hq-ws01';IP='10.19.10.11'},
    @{Zone='dc.d1.skills';Name='dc-lnx01';IP='10.19.110.11'},
    @{Zone='dc.d1.skills';Name='dc-lnx02';IP='10.19.110.12'},
    @{Zone='dc.d1.skills';Name='dc-win01';IP='10.19.110.21'},
    @{Zone='dc.d1.skills';Name='dc-svc01';IP='10.19.110.31'},
    @{Zone='dc.d1.skills';Name='dc-cl01';IP='10.19.120.11'},
    @{Zone='cloud.d1.skills';Name='cloud-service';IP='10.19.210.1'},
    @{Zone='cloud.d1.skills';Name='cloud-backup';IP='10.19.220.1'}
)
foreach ($r in $records) {
    Add-DnsServerResourceRecordA -ZoneName $r.Zone -Name $r.Name -IPv4Address $r.IP -CreatePtr -ErrorAction SilentlyContinue
}
Add-DnsServerResourceRecordCName -ZoneName 'dc.d1.skills' -Name 'portal' -HostNameAlias 'dc-lnx01.dc.d1.skills.' -ErrorAction SilentlyContinue
Add-DnsServerResourceRecordCName -ZoneName 'corp.d1.skills' -Name 'files' -HostNameAlias 'hq-file01.corp.d1.skills.' -ErrorAction SilentlyContinue
Add-DhcpServerv4Scope -Name 'HQ_USERS' -StartRange 10.19.10.100 -EndRange 10.19.10.200 -SubnetMask 255.255.255.0 -State Active -ErrorAction SilentlyContinue
Set-DhcpServerv4OptionValue -ScopeId 10.19.10.0 -Router 10.19.10.1 -DnsServer 10.19.20.10 -DnsDomain 'corp.d1.skills'
Add-DhcpServerInDC -DnsName 'hq-ad01.corp.d1.skills' -IPAddress 10.19.20.10 -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path C:\D1-Baseline -Force | Out-Null
'D1_HQ_AD01_READY' | Set-Content C:\D1-Baseline\ad-ready.txt
