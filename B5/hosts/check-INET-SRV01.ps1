param([switch]$Report,[string]$ReportDir,[switch]$NoPause,[string]$StartFromAspect)
. (Join-Path $PSScriptRoot '..\common\b5-common.ps1')
Invoke-B5HostChecks INET-SRV01 -Report:$Report -ReportDir $ReportDir -NoPause:$NoPause -StartFromAspect $StartFromAspect
