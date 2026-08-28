$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$criteriaPath = Join-Path $root 'criteria\b5_device_criteria_map.tsv'
$commonPath = Join-Path $root 'common\b5-common.ps1'

$parseErrors = @()
Get-ChildItem $root -Recurse -Filter '*.ps1' | ForEach-Object {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$errors)
    $parseErrors += @($errors)
}
if ($parseErrors.Count) {
    $parseErrors | Select-Object @{n='Line';e={$_.Extent.StartLineNumber}},ErrorId,Message | Format-Table -Wrap
    throw "PowerShell parse errors: $($parseErrors.Count)"
}

$rows = @(Import-Csv $criteriaPath -Delimiter "`t" -Encoding UTF8)
if ($rows.Count -ne 112) { throw "Expected 112 criteria, got $($rows.Count)" }
$points = [double](@($rows | Measure-Object MaxMark -Sum).Sum)
if ([Math]::Abs($points - 25.0) -gt 0.00001) { throw "Expected 25.00 points, got $points" }
if (@($rows.AspectID | Group-Object | Where-Object Count -gt 1).Count) { throw 'Duplicate aspect IDs' }

$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($commonPath,[ref]$tokens,[ref]$errors)
$switch = $ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.SwitchStatementAst] -and $node.Extent.Text -match 'A-ISP-SHA01-01'
},$true) | Select-Object -First 1
if (-not $switch) { throw 'Invoke-B5Aspect switch not found' }

$uncovered = foreach ($id in $rows.AspectID) {
    $found = $false
    foreach ($clause in $switch.Clauses) {
        $condition = $clause.Item1.Extent.Text
        if ($condition.StartsWith("'")) {
            if ((Invoke-Expression $condition) -eq $id) { $found=$true; break }
        } elseif ($condition.StartsWith('{')) {
            $_ = $id
            if (& ([scriptblock]::Create($condition.Trim('{}')))) { $found=$true; break }
        }
    }
    if (-not $found) { $id }
}
if (@($uncovered).Count) { throw "Uncovered aspect IDs: $($uncovered -join ', ')" }

$expectedHosts = @('ISP-SHA01','ISP-BJ01','INET-SRV01','INET-CL01','SHA-RTR01','BJ-RTR01','SHA-WEB01','SHA-APP01','SHA-DC01','BJ-DC02','SHA-FS01','BJ-SRV01','SHA-CL01','BJ-CL01')
foreach ($hostName in $expectedHosts) {
    if (-not (Test-Path (Join-Path $root "hosts\check-$hostName.ps1"))) { throw "Missing host entry point: $hostName" }
    if ($hostName -notin $rows.HostKey) { throw "No criteria for host: $hostName" }
}

Write-Host "B5 package validation passed: 112 aspects, 25.00 points, 14 hosts, 0 parse errors, 0 uncovered IDs." -ForegroundColor Green
