# Чистая базовая конфигурация D1: файловые службы и IIS на HQ-FILE01.
# Запустите от имени администратора после общей подготовки. Ввод в домен необязателен и требует готовности AD.

if (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) {
    Install-WindowsFeature FS-FileServer,Web-Server -IncludeManagementTools -ErrorAction Stop
}
elseif (Get-Command Enable-WindowsOptionalFeature -ErrorAction SilentlyContinue) {
    $IisFeatures = @(
        'IIS-WebServerRole',
        'IIS-WebServer',
        'IIS-CommonHttpFeatures',
        'IIS-DefaultDocument',
        'IIS-StaticContent',
        'IIS-HttpErrors',
        'IIS-HttpLogging',
        'IIS-RequestFiltering',
        'IIS-ManagementConsole'
    )
    foreach ($FeatureName in $IisFeatures) {
        Enable-WindowsOptionalFeature -Online -FeatureName $FeatureName -All -NoRestart -ErrorAction Stop | Out-Null
    }
}
else {
    throw 'Не найден способ установки IIS: отсутствуют Install-WindowsFeature и Enable-WindowsOptionalFeature.'
}

New-Item -ItemType Directory -Path C:\Shares\Public -Force | Out-Null
New-Item -ItemType Directory -Path C:\Shares\IT -Force | Out-Null
'D1_PUBLIC_SHARE_OK' | Set-Content C:\Shares\Public\readme.txt
'D1_IT_SHARE_OK' | Set-Content C:\Shares\IT\readme.txt
New-SmbShare -Name Public -Path C:\Shares\Public -ChangeAccess Everyone -ErrorAction SilentlyContinue
New-SmbShare -Name IT -Path C:\Shares\IT -ChangeAccess Administrators -ReadAccess Everyone -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path C:\inetpub\wwwroot -Force | Out-Null
'D1_HQ_FILE_WEB_OK' | Set-Content C:\inetpub\wwwroot\index.html
Start-Service W3SVC -ErrorAction Stop
Set-Service W3SVC -StartupType Automatic
New-Item -ItemType Directory -Path C:\D1-Baseline -Force | Out-Null
'D1_HQ_FILE01_READY' | Set-Content C:\D1-Baseline\file-ready.txt
