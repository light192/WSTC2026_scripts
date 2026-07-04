Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ReportDir = $env:B1_REPORT_DIR
if (-not $script:ReportDir) {
    $script:ReportDir = Join-Path $PSScriptRoot '..\reports'
}
$script:CriteriaMapPath = Join-Path $PSScriptRoot '..\criteria\b1_criteria_map.tsv'
$script:ResultsPath = Join-Path $script:ReportDir 'b1-results.tsv'
$script:DetailPath = Join-Path $script:ReportDir 'b1-detail.log'
$script:SummaryPath = Join-Path $script:ReportDir 'b1-summary.txt'
$script:LastContextId = $null
$script:PauseBetweenChecks = $true

function Initialize-B1Report {
    param([string]$ReportDir = $script:ReportDir)
    $script:ReportDir = $ReportDir
    $script:ResultsPath = Join-Path $script:ReportDir 'b1-results.tsv'
    $script:DetailPath = Join-Path $script:ReportDir 'b1-detail.log'
    $script:SummaryPath = Join-Path $script:ReportDir 'b1-summary.txt'
    New-Item -ItemType Directory -Path $script:ReportDir -Force | Out-Null
    Set-Content -Path $script:ResultsPath -Value "CriterionID`tMaxMark`tStatus`tMessage" -Encoding UTF8
    Set-Content -Path $script:DetailPath -Value '' -Encoding UTF8
    if (Test-Path $script:SummaryPath) {
        Remove-Item -Path $script:SummaryPath -Force
    }
}

function Write-Section {
    param([string]$Text)
    Write-Host ''
    Write-Host '######################################################################################' -ForegroundColor Magenta
    Write-Host $Text -ForegroundColor Magenta
    Write-Host '######################################################################################' -ForegroundColor Magenta
    Write-Host ''
    Add-Content -Path $script:DetailPath -Value ''
    Add-Content -Path $script:DetailPath -Value "=== $Text ==="
}

function Write-Step {
    param([string]$Text)
    Write-Host "Шаг: $Text" -ForegroundColor Yellow
    Add-Content -Path $script:DetailPath -Value "Шаг: $Text"
}

function Write-Command {
    param([string]$Text)
    Write-Host "Команда: $Text" -ForegroundColor Cyan
    Add-Content -Path $script:DetailPath -Value "Команда: $Text"
}

function Write-Detail {
    param([string]$Text)
    Write-Host $Text
    Add-Content -Path $script:DetailPath -Value $Text
}

function Write-Output {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        $Text = '(пустой вывод)'
    }
    Write-Host 'Фактический вывод:' -ForegroundColor Blue
    Write-Host $Text
    Add-Content -Path $script:DetailPath -Value 'Фактический вывод:'
    Add-Content -Path $script:DetailPath -Value $Text
}

function Write-ManualInstruction {
    param([string]$CriterionId, [string]$Instruction)
    Write-Host "[MANUAL] $CriterionId" -ForegroundColor Magenta
    Write-Host $Instruction -ForegroundColor Magenta
    Add-Content -Path $script:DetailPath -Value "[MANUAL] $CriterionId"
    Add-Content -Path $script:DetailPath -Value $Instruction
}

function Pause-IfNeeded {
    if ($script:PauseBetweenChecks) {
        Read-Host 'Нажмите Enter, чтобы продолжить'
    }
}

function Get-CriterionContext {
    param([string]$CriterionId)
    if (-not (Test-Path $script:CriteriaMapPath)) { return }
    if ($script:LastContextId -eq $CriterionId) { return }
    $script:LastContextId = $CriterionId
    $pattern = '^{0}' -f [regex]::Escape($CriterionId)
    $row = Get-Content -Path $script:CriteriaMapPath | Where-Object { $_ -match $pattern } | Select-Object -First 1
    if (-not $row) { return }
    $parts = $row -split "`t"
    if ($parts.Count -ge 5) {
        Write-Host "[CRITERION] $CriterionId - $($parts[2])" -ForegroundColor DarkCyan
        Write-Host "[COMMANDS] $($parts[3])" -ForegroundColor DarkCyan
        Write-Host "[EXPECTED] $($parts[4])" -ForegroundColor DarkCyan
        Add-Content -Path $script:DetailPath -Value "[CRITERION] $CriterionId - $($parts[2])"
        Add-Content -Path $script:DetailPath -Value "[COMMANDS] $($parts[3])"
        Add-Content -Path $script:DetailPath -Value "[EXPECTED] $($parts[4])"
    }
}

function Record-Result {
    param([string]$CriterionId, [string]$MaxMark, [string]$Status, [string]$Message)
    Get-CriterionContext -CriterionId $CriterionId
    $line = "{0}`t{1}`t{2}`t{3}" -f $CriterionId, $MaxMark, $Status, $Message
    Add-Content -Path $script:ResultsPath -Value $line
    switch ($Status) {
        'PASS' { Write-Host "[PASS] $CriterionId/$MaxMark - $Message" -ForegroundColor Green }
        'FAIL' { Write-Host "[FAIL] $CriterionId/$MaxMark - $Message" -ForegroundColor Red }
        'WARN' { Write-Host "[WARN] $CriterionId/$MaxMark - $Message" -ForegroundColor Yellow }
        'SKIP' { Write-Host "[SKIP] $CriterionId/$MaxMark - $Message" -ForegroundColor Cyan }
        default { Write-Host "[$Status] $CriterionId/$MaxMark - $Message" }
    }
    Pause-IfNeeded
}

function Invoke-RemoteCheck {
    param([string]$ComputerName, [scriptblock]$ScriptBlock)
    if ($ComputerName -eq 'localhost' -or $ComputerName -eq $env:COMPUTERNAME) {
        try { return & $ScriptBlock } catch { return $null }
    }
    try { return Invoke-Command -ComputerName $ComputerName -ScriptBlock $ScriptBlock -ErrorAction Stop } catch { return $null }
}

function Write-Summary {
    param([string]$ReportPath = $script:SummaryPath)
    $rows = Import-Csv -Path $script:ResultsPath -Delimiter "`t" -ErrorAction SilentlyContinue
    if (-not $rows) {
        Set-Content -Path $ReportPath -Value "B1 Evaluation Summary`nNo checks executed." -Encoding UTF8
        return
    }
    $total = 0
    $passed = 0
    $failed = 0
    $warned = 0
    $skipped = 0
    $counts = @{}
    foreach ($row in $rows) {
        if ($row.CriterionID -eq 'CriterionID') { continue }
        $mark = [double]$row.MaxMark
        $total += $mark
        switch ($row.Status) {
            'PASS' { $passed += $mark; if ($counts.ContainsKey('PASS')) { $counts['PASS'] += 1 } else { $counts['PASS'] = 1 } }
            'FAIL' { $failed += $mark; if ($counts.ContainsKey('FAIL')) { $counts['FAIL'] += 1 } else { $counts['FAIL'] = 1 } }
            'WARN' { $warned += $mark; if ($counts.ContainsKey('WARN')) { $counts['WARN'] += 1 } else { $counts['WARN'] = 1 } }
            'SKIP' { $skipped += $mark; if ($counts.ContainsKey('SKIP')) { $counts['SKIP'] += 1 } else { $counts['SKIP'] = 1 } }
        }
    }
    $lines = @(
        'B1 Evaluation Summary',
        '=====================',
        "Passed marks: $([math]::Round($passed,2)) / $([math]::Round($total,2))",
        "Failed marks: $([math]::Round($failed,2))",
        "Warn marks:   $([math]::Round($warned,2))",
        "Skip marks:   $([math]::Round($skipped,2))",
        '',
        'Counts:'
    )
    foreach ($entry in $counts.GetEnumerator() | Sort-Object Name) {
        $lines += "  $($entry.Key): $($entry.Value)"
    }
    Set-Content -Path $ReportPath -Value ($lines -join [Environment]::NewLine) -Encoding UTF8
    Write-Host "Summary written to $ReportPath" -ForegroundColor DarkGray
}
