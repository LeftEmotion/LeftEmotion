param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$TaskName = "CodexTokenActivityProfileUpdate",
    [int]$EveryMinutes = 60
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path $RepoRoot).Path
$updateScript = Join-Path $repoRoot "scripts\update-codex-token-activity.ps1"
$runnerScript = Join-Path $repoRoot "scripts\run-codex-token-activity-update.cmd"
if (-not (Test-Path $updateScript)) {
    throw "Cannot find update script: $updateScript"
}
if (-not (Test-Path $runnerScript)) {
    throw "Cannot find runner script: $runnerScript"
}

$taskCommand = "`"$runnerScript`""

schtasks.exe /Create /F /SC MINUTE /MO $EveryMinutes /TN $TaskName /TR $taskCommand | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "Failed to install scheduled task '$TaskName'."
}
Write-Host "Installed scheduled task '$TaskName' to update every $EveryMinutes minutes."
