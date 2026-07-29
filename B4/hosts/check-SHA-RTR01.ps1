param([switch]$Report,[string]$ReportDir,[switch]$NoPause,[string]$StartFromAspect)
. (Join-Path $PSScriptRoot '..\common\b4-common.ps1')
Invoke-B4HostChecks SHA-RTR01 -Report:$Report -ReportDir $ReportDir -NoPause:$NoPause -StartFromAspect $StartFromAspect
