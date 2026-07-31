# D1 clean baseline: SMB file service on HQ-FILE01 (PDF role: "SMB file service").
# Run as Administrator after the common prep. Share name matches the taskbook
# path used in ticket T03: \\hq-file01\shared.

Install-WindowsFeature FS-FileServer -IncludeManagementTools

New-Item -ItemType Directory -Path C:\Shares\shared -Force | Out-Null
'D1_HQ_FILE01_SHARE_OK' | Set-Content C:\Shares\shared\readme.txt
New-SmbShare -Name shared -Path C:\Shares\shared -ChangeAccess Everyone -ErrorAction SilentlyContinue

New-Item -ItemType Directory -Path C:\D1-Baseline -Force | Out-Null
'D1_HQ_FILE01_READY' | Set-Content C:\D1-Baseline\file-ready.txt
