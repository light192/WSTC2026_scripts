param([switch]$Report,[string]$ReportDir,[switch]$NoPause,[string]$StartFromAspect)
$hostKey=$env:COMPUTERNAME.ToUpperInvariant()
$scriptPath=Join-Path $PSScriptRoot "..\hosts\check-$hostKey.ps1"
if(-not(Test-Path $scriptPath)){
    $available=Get-ChildItem (Join-Path $PSScriptRoot '..\hosts') -Filter 'check-*.ps1' |
        ForEach-Object {$_.BaseName-replace'^check-',''}|Sort-Object
    throw "Нет B4-скрипта для '$hostKey'. Доступны: $($available-join', ')"
}
$argsMap=@{}
if($Report){$argsMap.Report=$true}
if($ReportDir){$argsMap.ReportDir=$ReportDir}
if($NoPause){$argsMap.NoPause=$true}
if($StartFromAspect){$argsMap.StartFromAspect=$StartFromAspect}
& $scriptPath @argsMap
