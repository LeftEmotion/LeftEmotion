param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$CodexRoot = (Join-Path $env:USERPROFILE ".codex"),
    [string]$Branch = "main",
    [int]$Days = 365,
    [int]$ActiveGapMinutes = 60,
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

function Format-TokenWan {
    param([int64]$Value)
    if ($Value -ge 10000) {
        $formatted = ($Value / 10000.0).ToString("0.0", [System.Globalization.CultureInfo]::InvariantCulture)
        $formatted = $formatted -replace "\.0$", ""
        return "$formatted&#x4E07;"
    }
    return $Value.ToString("N0", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-DurationLabel {
    param([TimeSpan]$Duration)
    if ($Duration.TotalMinutes -lt 1) { return "0 &#x5206;" }
    $hours = [int][Math]::Floor($Duration.TotalHours)
    $minutes = [int]$Duration.Minutes
    if ($hours -gt 0) { return "$hours &#x5C0F;&#x65F6; $minutes &#x5206;" }
    return "$minutes &#x5206;"
}

function Get-ColorLevel {
    param([int64]$Value, [int64]$MaxValue)
    if ($Value -le 0 -or $MaxValue -le 0) { return "#f1f1f1" }
    $ratio = [Math]::Log10($Value + 1) / [Math]::Log10($MaxValue + 1)
    if ($ratio -lt 0.22) { return "#dceeff" }
    if ($ratio -lt 0.42) { return "#badfff" }
    if ($ratio -lt 0.62) { return "#8bc8ff" }
    if ($ratio -lt 0.82) { return "#4aa6ff" }
    return "#1688f8"
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
        [int]$Days,
        [datetime]$Now
    )

    $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("Tokyo Standard Time")
    $localEvents = foreach ($event in $Events) {
        $localTime = [System.TimeZoneInfo]::ConvertTimeFromUtc($event.Timestamp, $tz)
        [pscustomobject]@{
            Date = $localTime.Date
            Timestamp = $localTime
            Session = $event.Session
            Total = $event.Total
            Output = $event.Output
            Reasoning = $event.Reasoning
        }
    }

    $today = $Now.Date
    $from = $today.AddDays(-($Days - 1))
    $daily = @{}
    foreach ($group in ($localEvents | Where-Object { $_.Date -ge $from -and $_.Date -le $today } | Group-Object { $_.Date.ToString("yyyy-MM-dd") })) {
        $sum = ($group.Group | Measure-Object Total -Sum).Sum
        $daily[$group.Name] = [int64]$sum
    }

    $totalTokens = [int64](($localEvents | Measure-Object Total -Sum).Sum)
    $peakTokens = if ($daily.Count -gt 0) { [int64](($daily.Values | Measure-Object -Maximum).Maximum) } else { 0 }

    $activeGap = New-TimeSpan -Minutes $ActiveGapMinutes
    $sessionDurations = foreach ($sessionGroup in ($localEvents | Group-Object Session)) {
        $times = $sessionGroup.Group | Sort-Object Timestamp
        if ($times.Count -gt 0) {
            $segmentStart = $times[0].Timestamp
            $previous = $times[0].Timestamp
            for ($i = 1; $i -lt $times.Count; $i++) {
                $current = $times[$i].Timestamp
                if (($current - $previous) -gt $activeGap) {
                    New-TimeSpan -Start $segmentStart -End $previous
                    $segmentStart = $current
                }
                $previous = $current
            }
            New-TimeSpan -Start $segmentStart -End $previous
        }
    }
    $longestDuration = if ($sessionDurations) {
        $sessionDurations | Sort-Object TotalSeconds -Descending | Select-Object -First 1
    } else {
        New-TimeSpan -Minutes 0
    }

    $activeDates = @{}
    foreach ($key in $daily.Keys) {
        if ($daily[$key] -gt 0) { $activeDates[$key] = $true }
    }

    $currentStreak = 0
    $cursor = $today
    while ($activeDates.ContainsKey($cursor.ToString("yyyy-MM-dd"))) {
        $currentStreak++
        $cursor = $cursor.AddDays(-1)
    }

    $longestStreak = 0
    $runningStreak = 0
    $scan = $from
    while ($scan -le $today) {
        if ($activeDates.ContainsKey($scan.ToString("yyyy-MM-dd"))) {
            $runningStreak++
            if ($runningStreak -gt $longestStreak) { $longestStreak = $runningStreak }
        } else {
            $runningStreak = 0
        }
        $scan = $scan.AddDays(1)
    }

    $stats = @(
        @{ Value = (Format-TokenWan $totalTokens); Label = "&#x7D2F;&#x8BA1; Token &#x6570;" },
        @{ Value = (Format-TokenWan $peakTokens); Label = "&#x5CF0;&#x503C; Token &#x6570;" },
        @{ Value = (Format-DurationLabel $longestDuration); Label = "&#x6700;&#x957F;&#x4EFB;&#x52A1;&#x65F6;&#x957F;" },
        @{ Value = "$currentStreak &#x5929;"; Label = "&#x5F53;&#x524D;&#x8FDE;&#x7EED;&#x5929;&#x6570;" },
        @{ Value = "$longestStreak &#x5929;"; Label = "&#x6700;&#x957F;&#x8FDE;&#x7EED;&#x5929;&#x6570;" }
    )

    $maxDaily = if ($daily.Count -gt 0) { [int64](($daily.Values | Measure-Object -Maximum).Maximum) } else { 0 }
    $startOffset = (([int]$from.DayOfWeek + 6) % 7)
    $gridStart = $from.AddDays(-$startOffset)
    $cell = 14
    $gap = 5
    $gridX = 112
    $gridY = 198

    $rects = New-Object System.Collections.Generic.List[string]
    $dateCursor = $gridStart
    while ($dateCursor -le $today) {
        $delta = [int]($dateCursor - $gridStart).TotalDays
        $col = [int][Math]::Floor($delta / 7)
        $row = $delta % 7
        $x = $gridX + ($col * ($cell + $gap))
        $y = $gridY + ($row * ($cell + $gap))
        $dateKey = $dateCursor.ToString("yyyy-MM-dd")
        $value = if ($daily.ContainsKey($dateKey)) { $daily[$dateKey] } else { 0 }
        $color = Get-ColorLevel -Value $value -MaxValue $maxDaily
        $opacity = if ($dateCursor -lt $from) { "0" } else { "1" }
        $title = "$dateKey`: $($value.ToString("N0", [System.Globalization.CultureInfo]::InvariantCulture)) tokens"
        $rects.Add("<rect x=""$x"" y=""$y"" width=""$cell"" height=""$cell"" rx=""4"" fill=""$color"" opacity=""$opacity""><title>$(Escape-Svg $title)</title></rect>")
        $dateCursor = $dateCursor.AddDays(1)
    }

    $monthLabels = New-Object System.Collections.Generic.List[string]
    $monthCursor = [datetime]::new($from.Year, $from.Month, 1)
    while ($monthCursor -le $today) {
        if ($monthCursor -ge $from.AddDays(14)) {
            $delta = [int]($monthCursor - $gridStart).TotalDays
            $col = [int][Math]::Floor($delta / 7)
            $x = $gridX + ($col * ($cell + $gap))
            $label = "$($monthCursor.Month)&#x6708;"
            $monthLabels.Add("<text x=""$x"" y=""354"" class=""month"">$label</text>")
        }
        $monthCursor = $monthCursor.AddMonths(1)
    }

    $statBlocks = New-Object System.Collections.Generic.List[string]
    $cardX = 112
    $cardY = 32
    $cardW = 916
    $slotW = $cardW / 5
    for ($i = 0; $i -lt $stats.Count; $i++) {
        $centerX = $cardX + ($slotW * $i) + ($slotW / 2)
        $value = $stats[$i].Value
        $label = $stats[$i].Label
        $statBlocks.Add("<text x=""$centerX"" y=""66"" text-anchor=""middle"" class=""stat-value"">$value</text>")
        $statBlocks.Add("<text x=""$centerX"" y=""91"" text-anchor=""middle"" class=""stat-label"">$label</text>")
        if ($i -gt 0) {
            $lineX = $cardX + ($slotW * $i)
            $statBlocks.Add("<line x1=""$lineX"" y1=""48"" x2=""$lineX"" y2=""92"" stroke=""#eeeeee""/>")
        }
    }

    $updated = $Now.ToString("yyyy-MM-dd HH:mm 'JST'")
    $rectMarkup = $rects -join "`n"
    $monthMarkup = $monthLabels -join "`n"
    $statMarkup = $statBlocks -join "`n"

    return @"
<svg xmlns="http://www.w3.org/2000/svg" width="1140" height="380" viewBox="0 0 1140 380" role="img" aria-label="Codex Token Activity">
  <style>
    text { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans CJK SC", "Microsoft YaHei", Arial, sans-serif; }
    .title { fill: #202124; font-size: 18px; font-weight: 700; }
    .mode { fill: #1f2328; font-size: 16px; font-weight: 700; }
    .mode-muted { fill: #8c8f94; font-size: 16px; font-weight: 600; }
    .stat-value { fill: #1f2328; font-size: 18px; font-weight: 500; }
    .stat-label { fill: #6f7378; font-size: 17px; }
    .month { fill: #8c8f94; font-size: 15px; }
    .updated { fill: #9aa0a6; font-size: 12px; }
  </style>
  <rect width="1140" height="380" fill="#ffffff"/>
  <rect x="112" y="32" width="916" height="76" rx="18" fill="#ffffff" stroke="#eeeeee"/>
  $statMarkup
  <text x="112" y="178" class="title">Token &#x6D3B;&#x52A8;</text>
  <text x="892" y="177" class="mode">&#x6BCF;&#x65E5;</text>
  <text x="944" y="177" class="mode-muted">&#x6BCF;&#x5468;</text>
  <text x="995" y="177" class="mode-muted">&#x7D2F;&#x8BA1;</text>
  $rectMarkup
  $monthMarkup
  <text x="112" y="374" class="updated">Updated $updated from local Codex token_count events.</text>
</svg>
"@
}

$repoRoot = (Resolve-Path $RepoRoot).Path
$assetsDir = Join-Path $repoRoot "assets"
$readmePath = Join-Path $repoRoot "README.md"
$svgPath = Join-Path $assetsDir "codex-token-activity.svg"

New-Item -ItemType Directory -Force -Path $assetsDir | Out-Null

if ($Push) {
    git -C $repoRoot pull --ff-only origin $Branch
}

$events = @(Read-CodexTokenEvents -Root $CodexRoot)
$tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("Tokyo Standard Time")
$now = [System.TimeZoneInfo]::ConvertTimeFromUtc((Get-Date).ToUniversalTime(), $tz)
$svg = New-CodexActivitySvg -Events $events -Days $Days -Now $now
Write-Utf8NoBom -Path $svgPath -Content $svg

$readme = [System.IO.File]::ReadAllText($readmePath, [System.Text.Encoding]::UTF8)
$block = @"
<!-- CODEX-TOKEN-ACTIVITY:START -->
![Codex Token Activity](assets/codex-token-activity.svg)

Updated automatically by ``scripts/update-codex-token-activity.ps1``.
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
    git -C $repoRoot add README.md assets/codex-token-activity.svg
    $changes = git -C $repoRoot status --short
    if ($changes) {
        git -C $repoRoot commit -m "Update Codex token activity graphic"
        git -C $repoRoot push origin $Branch
    }
}
