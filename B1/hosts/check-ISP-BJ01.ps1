param(
    [switch]$Report,
    [string]$ReportDir,
    [switch]$NoPause,
    [string]$StartFromAspect
)

$requestedReport = $Report
$requestedReportDir = $ReportDir
$requestedNoPause = $NoPause
$requestedStartFromAspect = $StartFromAspect

. (Join-Path $PSScriptRoot '..\common\b1-common.ps1')
Invoke-B1HostChecks -HostKey 'ISP-BJ01' -Report:$requestedReport -ReportDir $requestedReportDir -NoPause:$requestedNoPause -StartFromAspect $requestedStartFromAspect
