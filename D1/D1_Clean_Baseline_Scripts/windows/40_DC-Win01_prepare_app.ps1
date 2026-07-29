# Чистая базовая конфигурация D1: простой сервер веб-приложения DC-Win01.
# Запустите от имени администратора после общей подготовки.
Install-WindowsFeature Web-Server -IncludeManagementTools
'D1_DC_WIN_APP_OK' | Set-Content C:\inetpub\wwwroot\index.html
New-Item -ItemType Directory -Path C:\inetpub\wwwroot\healthz -Force | Out-Null
'OK' | Set-Content C:\inetpub\wwwroot\healthz\index.html
New-Item -ItemType Directory -Path C:\D1-Baseline -Force | Out-Null
'D1_DC_WIN01_READY' | Set-Content C:\D1-Baseline\app-ready.txt
