param([switch]$Report,[string]$ReportDir,[switch]$NoPause,[string]$StartFromAspect)
. (Join-Path $PSScriptRoot '..\common\b2-common.ps1')
Invoke-B2HostChecks -HostKey 'INET-SRV01' -Report:$Report -ReportDir $ReportDir -NoPause:$NoPause -StartFromAspect $StartFromAspect

