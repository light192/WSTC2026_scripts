param(
    [switch]$Report,
    [string]$ReportDir,
    [switch]$NoPause,
    [string]$StartFromAspect
)

$hostKey = $env:COMPUTERNAME.ToUpperInvariant()
$hostScript = Join-Path $PSScriptRoot "..\hosts\check-$hostKey.ps1"
if (-not (Test-Path -LiteralPath $hostScript)) {
    $available = Get-ChildItem (Join-Path $PSScriptRoot '..\hosts') -Filter 'check-*.ps1' |
        ForEach-Object { $_.BaseName -replace '^check-','' } | Sort-Object
    throw "Нет локального B3-скрипта для '$hostKey'. Доступны: $($available -join ', ')"
}

$arguments = @{}
if ($Report) { $arguments.Report = $true }
if (-not [string]::IsNullOrWhiteSpace($ReportDir)) { $arguments.ReportDir = $ReportDir }
if ($NoPause) { $arguments.NoPause = $true }
if (-not [string]::IsNullOrWhiteSpace($StartFromAspect)) { $arguments.StartFromAspect = $StartFromAspect }
& $hostScript @arguments


