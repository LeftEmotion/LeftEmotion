$ErrorActionPreference = "Stop"
$scriptPath = Join-Path $PSScriptRoot "update-codex-token-activity.ps1"
$parseErrors = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
# Load definitions only, so tests never read private logs or write profile files.
foreach ($function in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    Invoke-Expression $function.Extent.Text
}
function Assert-True($condition, $message) { if (-not $condition) { throw $message } }
function Get-Days([xml]$svg) { @($svg.SelectNodes('//*[local-name()="rect" and @data-date]')) }
function New-Event([string]$utc, [int64]$total) {
    [pscustomobject]@{ Timestamp = [datetime]::Parse($utc).ToUniversalTime(); Total = $total }
}
$now = [datetime]'2026-09-07T17:00:00'
$events = @(
    (New-Event '2026-03-07T14:59:59Z' 900000), # Before the interval in JST.
    (New-Event '2026-03-07T15:00:00Z' 100),    # First included midnight in JST.
    (New-Event '2026-05-02T00:00:00Z' 200),
    (New-Event '2026-06-02T00:00:00Z' 300),
    (New-Event '2026-09-07T00:00:00Z' 400),
    (New-Event '2026-09-07T15:00:00Z' 800000)  # Tomorrow in JST.
)
[xml]$light = New-CodexActivitySvg -Events $events -Now $now
[xml]$dark = New-CodexActivitySvg -Events $events -Now $now -Theme dark
$days = Get-Days $light
Assert-True ($days.Count -eq 184) 'Expected 184 days in this six-month interval.'
Assert-True ($days[0].GetAttribute('data-date') -eq '2026-03-08') 'Incorrect first date.'
Assert-True ($days[-1].GetAttribute('data-date') -eq '2026-09-07') 'Incorrect last date.'
[xml]$inRangeOnly = New-CodexActivitySvg -Events $events[1..4] -Now $now
Assert-True ($light.OuterXml -eq $inRangeOnly.OuterXml) 'Out-of-range events must not change the graph or color thresholds.'
foreach ($svg in @($light, $dark)) {
    Assert-True (-not $svg.OuterXml.Contains('data-tokens')) 'Do not embed exact usage in SVG attributes.'
    Assert-True ($svg.InnerText -notmatch '\d[\d,.]*[KM]?\s+tokens') 'Do not disclose numeric token usage in text or descriptions.'
}
$colors = @($days | Where-Object { $_.GetAttribute('fill') -ne '#eff2f5' } | ForEach-Object { $_.GetAttribute('fill') } | Sort-Object -Unique)
Assert-True ($colors.Count -eq 4) 'Active-day quartiles should use all four green shades.'
$darkDays = Get-Days $dark
$lightValues = ($days | ForEach-Object { $_.InnerText }) -join ','
$darkValues = ($darkDays | ForEach-Object { $_.InnerText }) -join ','
Assert-True ($lightValues -eq $darkValues) 'Themes must show identical data.'
foreach ($dateString in @('2024-08-31', '2024-02-29', '2026-03-31', '2026-09-30', '2027-01-01')) {
    $end = [datetime]$dateString
    $start = $end.AddMonths(-6).AddDays(1)
    [xml]$empty = New-CodexActivitySvg -Events @() -Now $end
    $emptyDays = Get-Days $empty
    Assert-True ($emptyDays.Count -eq ($end - $start).Days + 1) "Incorrect interval at $dateString."
    Assert-True ($emptyDays[0].GetAttribute('data-date') -eq $start.ToString('yyyy-MM-dd')) "Incorrect boundary at $dateString."
    Assert-True (@($emptyDays | Where-Object { $_.GetAttribute('fill') -ne '#eff2f5' }).Count -eq 0) 'Empty input should render an inactive graph.'
    foreach ($day in $emptyDays) {
        Assert-True (([int]$day.x + [int]$day.width) -lt [int]$empty.svg.width) 'Cell clipped horizontally.'
        Assert-True (([int]$day.y + [int]$day.height) -lt 251) 'Cell overlaps footer.'
    }
}
[xml]$single = New-CodexActivitySvg -Events @((New-Event '2026-09-07T00:00:00Z' 1)) -Now $now
Assert-True (@((Get-Days $single) | Where-Object { $_.GetAttribute('fill') -ne '#eff2f5' }).Count -eq 1) 'Single active day should render without quantile errors.'
Write-Host 'PASS: no exact usage disclosed, six-month filtering, JST boundaries, leap years, month ends, empty/single-day data, color levels, theme parity, and grid bounds.'
