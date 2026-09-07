param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$CodexRoot = (Join-Path $env:USERPROFILE ".codex"),
    [string]$Branch = "main",
    [switch]$Push
)

$ErrorActionPreference = "Stop"

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Escape-Svg {
    param([object]$Value)
    return [System.Security.SecurityElement]::Escape([string]$Value)
}

function Format-CompactToken {
    param([int64]$Value)
    if ($Value -ge 1000000) {
        $formatted = ($Value / 1000000.0).ToString("0.0", [System.Globalization.CultureInfo]::InvariantCulture)
        $formatted = $formatted -replace "\.0$", ""
        return "${formatted}M"
    }
    if ($Value -ge 1000) {
        $formatted = ($Value / 1000.0).ToString("0.0", [System.Globalization.CultureInfo]::InvariantCulture)
        $formatted = $formatted -replace "\.0$", ""
        return "${formatted}K"
    }
    return $Value.ToString("N0", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Read-CodexTokenEvents {
    param([string]$Root)

    $searchRoots = @(
        (Join-Path $Root "sessions"),
        (Join-Path $Root "archived_sessions")
    ) | Where-Object { Test-Path $_ }

    $seen = @{}
    $events = New-Object System.Collections.Generic.List[object]

    foreach ($searchRoot in $searchRoots) {
        $files = Get-ChildItem -Path $searchRoot -Recurse -Filter "*.jsonl" -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            $sessionMatch = [regex]::Match($file.Name, "(019[0-9a-f-]+)\.jsonl$")
            $sessionId = if ($sessionMatch.Success) { $sessionMatch.Groups[1].Value } else { $file.BaseName }

            Select-String -Path $file.FullName -Pattern '"type":"token_count"' -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    $json = $_.Line | ConvertFrom-Json
                    $usage = $json.payload.info.last_token_usage
                    if ($null -eq $usage) { return }

                    $timestamp = ([datetime]$json.timestamp).ToUniversalTime()
                    $total = [int64]$usage.total_tokens
                    $input = [int64]$usage.input_tokens
                    $cached = [int64]$usage.cached_input_tokens
                    $output = [int64]$usage.output_tokens
                    $reasoning = [int64]$usage.reasoning_output_tokens
                    $key = "$sessionId|$($timestamp.ToString("o"))|$total|$input|$cached|$output|$reasoning"

                    if (-not $seen.ContainsKey($key)) {
                        $seen[$key] = $true
                        $events.Add([pscustomobject]@{
                            Timestamp = $timestamp
                            Session = $sessionId
                            Total = $total
                            Input = $input
                            CachedInput = $cached
                            Output = $output
                            Reasoning = $reasoning
                        })
                    }
                } catch {
                    # Ignore malformed or partially-written log lines.
                }
            }
        }
    }

    return $events
}

function New-CodexActivitySvg {
    param(
        [object[]]$Events,
        [datetime]$Now,
        [ValidateSet("light", "dark")][string]$Theme = "light"
    )

    $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("Tokyo Standard Time")
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $today = $Now.Date
    # A rolling six-calendar-month interval, including today, in Japan time.
    $from = $today.AddMonths(-6).AddDays(1)
    $daily = @{}
    foreach ($event in $Events) {
        $date = [System.TimeZoneInfo]::ConvertTimeFromUtc($event.Timestamp, $tz).Date
        if ($date -lt $from -or $date -gt $today) { continue }
        $key = $date.ToString("yyyy-MM-dd")
        $daily[$key] = [int64]$daily[$key] + [int64]$event.Total
    }
    $totalTokens = [int64](($daily.Values | Measure-Object -Sum).Sum)

    # Quartiles of active days keep the four shades useful even with a large peak.
    $positive = @($daily.Values | Where-Object { $_ -gt 0 } | Sort-Object)
    $thresholds = @(foreach ($fraction in @(0.25, 0.5, 0.75)) {
        if ($positive.Count -gt 0) {
            $positive[[int][Math]::Ceiling($positive.Count * $fraction) - 1]
        } else { 0 }
    })
    $palette = @("#eff2f5", "#9be9a8", "#40c463", "#30a14e", "#216e39")
    $background = "#ffffff"; $border = "#d1d9e0"; $foreground = "#1f2328"; $muted = "#59636e"
    if ($Theme -eq "dark") {
        $palette = @("#151b23", "#033a16", "#196c2e", "#2ea043", "#56d364")
        $background = "#0d1117"; $border = "#3d444d"; $foreground = "#f0f6fc"; $muted = "#9198a1"
    }

    # GitHub's calendar starts each column on Sunday. Padding is never data.
    $gridStart = $from.AddDays(-[int]$from.DayOfWeek)
    $cell = 18; $pitch = 23; $gridX = 52; $gridY = 80
    $weeks = [int][Math]::Floor(($today - $gridStart).TotalDays / 7) + 1
    $width = $gridX + $weeks * $pitch - ($pitch - $cell) + 24
    $right = $width - 24
    $rects = New-Object System.Collections.Generic.List[string]
    $monthLabels = New-Object System.Collections.Generic.List[string]
    $lastLabelCol = -10
    for ($date = $from; $date -le $today; $date = $date.AddDays(1)) {
        $delta = [int]($date - $gridStart).TotalDays
        $col = [int][Math]::Floor($delta / 7)
        $row = $delta % 7
        $x = $gridX + $col * $pitch
        $y = $gridY + $row * $pitch
        $key = $date.ToString("yyyy-MM-dd")
        $value = if ($daily.ContainsKey($key)) { [int64]$daily[$key] } else { 0 }
        $level = 0
        if ($value -gt 0) {
            $level = 1
            foreach ($threshold in $thresholds) { if ($value -gt $threshold) { $level++ } }
        }
        $color = $palette[$level]
        $title = "$key`: $($value.ToString('N0', $culture)) tokens"
        $rects.Add("<rect class=""day"" data-date=""$key"" data-tokens=""$value"" x=""$x"" y=""$y"" width=""$cell"" height=""$cell"" rx=""3"" fill=""$color""><title>$(Escape-Svg $title)</title></rect>")
        if (($date -eq $from -or $date.Day -eq 1) -and ($col - $lastLabelCol -ge 2)) {
            $monthLabels.Add("<text x=""$x"" y=""67"" class=""label"">$($date.ToString('MMM', $culture))</text>")
            $lastLabelCol = $col
        }
    }
    $weekLabels = New-Object System.Collections.Generic.List[string]
    foreach ($row in @(1, 3, 5)) {
        $y = $gridY + $row * $pitch + 13
        $label = @("Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat")[$row]
        $weekLabels.Add("<text x=""20"" y=""$y"" class=""label"">$label</text>")
    }
    $legend = New-Object System.Collections.Generic.List[string]
    $legendX = $right - 119
    for ($i = 0; $i -lt $palette.Count; $i++) {
        $x = $legendX + $i * 17
        $legend.Add("<rect x=""$x"" y=""251"" width=""13"" height=""13"" rx=""2"" class=""day"" fill=""$($palette[$i])""/>")
    }
    $lessX = $legendX - 10
    $range = "$($from.ToString('MMM d, yyyy', $culture)) - $($today.ToString('MMM d, yyyy', $culture))"
    $summary = "$(Format-CompactToken $totalTokens) tokens in the last 6 months"
    $description = "$($totalTokens.ToString('N0', $culture)) tokens from $range (JST). Each square represents one day; darker green means more tokens in light mode, brighter green in dark mode."
    return @"
<svg xmlns="http://www.w3.org/2000/svg" width="$width" height="284" viewBox="0 0 $width 284" role="img" aria-labelledby="activity-title activity-description">
  <title id="activity-title">Codex Token Activity - last 6 months</title>
  <desc id="activity-description">$(Escape-Svg $description)</desc>
  <style>
    text { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Arial, sans-serif; }
    .summary { fill: $foreground; font-size: 16px; font-weight: 600; }
    .label, .footer { fill: $muted; font-size: 12px; }
    .day { stroke: $foreground; stroke-opacity: 0.06; stroke-width: 1; }
  </style>
  <rect x="0.5" y="0.5" width="$($width - 1)" height="283" rx="6" fill="$background" stroke="$border"/>
  <text x="24" y="34" class="summary">$summary</text>
  $($monthLabels -join "`n  ")
  $($weekLabels -join "`n  ")
  $($rects -join "`n  ")
  <text x="24" y="262" class="footer">$range / JST</text>
  <text x="$lessX" y="262" text-anchor="end" class="footer">Less</text>
  $($legend -join "`n  ")
  <text x="$right" y="262" text-anchor="end" class="footer">More</text>
</svg>
"@
}

$repoRoot = (Resolve-Path $RepoRoot).Path
$assetsDir = Join-Path $repoRoot "assets"
$readmePath = Join-Path $repoRoot "README.md"
$svgPath = Join-Path $assetsDir "codex-token-activity.svg"
$darkSvgPath = Join-Path $assetsDir "codex-token-activity-dark.svg"

New-Item -ItemType Directory -Force -Path $assetsDir | Out-Null

if ($Push) {
    git -C $repoRoot pull --ff-only origin $Branch
    if ($LASTEXITCODE -ne 0) { throw "Cannot update: git pull failed." }
}

$events = @(Read-CodexTokenEvents -Root $CodexRoot)
$tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("Tokyo Standard Time")
$now = [System.TimeZoneInfo]::ConvertTimeFromUtc((Get-Date).ToUniversalTime(), $tz)
$svg = New-CodexActivitySvg -Events $events -Now $now
Write-Utf8NoBom -Path $svgPath -Content $svg
Write-Utf8NoBom -Path $darkSvgPath -Content (New-CodexActivitySvg -Events $events -Now $now -Theme dark)

$readme = [System.IO.File]::ReadAllText($readmePath, [System.Text.Encoding]::UTF8)
$block = @"
<!-- CODEX-TOKEN-ACTIVITY:START -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/codex-token-activity-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="assets/codex-token-activity.svg">
  <img alt="Codex token activity over the last six months" src="assets/codex-token-activity.svg">
</picture>
<!-- CODEX-TOKEN-ACTIVITY:END -->
"@

$pattern = "(?s)<!-- CODEX-TOKEN-ACTIVITY:START -->.*?<!-- CODEX-TOKEN-ACTIVITY:END -->"
if ([regex]::IsMatch($readme, $pattern)) {
    $readme = [regex]::Replace($readme, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $block }, 1)
} else {
    $readme = $readme.TrimEnd() + "`n`n## Codex Token Activity`n`n" + $block + "`n"
}
Write-Utf8NoBom -Path $readmePath -Content $readme

if ($Push) {
    $generated = @("README.md", "assets/codex-token-activity.svg", "assets/codex-token-activity-dark.svg")
    git -C $repoRoot add -- $generated
    if ($LASTEXITCODE -ne 0) { throw "Cannot stage activity files." }
    git -C $repoRoot diff --cached --quiet -- $generated
    if ($LASTEXITCODE -eq 1) {
        git -C $repoRoot commit -m "Update Codex token activity graphic" -- $generated
        if ($LASTEXITCODE -ne 0) { throw "Cannot commit activity files." }
    } elseif ($LASTEXITCODE -ne 0) { throw "Cannot inspect activity changes." }
    git -C $repoRoot push origin $Branch
    if ($LASTEXITCODE -ne 0) { throw "Cannot push activity update." }
}
