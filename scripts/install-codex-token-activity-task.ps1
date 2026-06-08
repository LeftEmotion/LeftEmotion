param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$TaskName = "CodexTokenActivityProfileUpdate",
    [int]$EveryMinutes = 60
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path $RepoRoot).Path
$updateScript = Join-Path $repoRoot "scripts\update-codex-token-activity.ps1"
if (-not (Test-Path $updateScript)) {
    throw "Cannot find update script: $updateScript"
}

$escapedScript = $updateScript.Replace('"', '\"')
$escapedRepo = $repoRoot.Replace('"', '\"')
$taskCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$escapedScript`" -RepoRoot `"$escapedRepo`" -Push"

schtasks.exe /Create /F /SC MINUTE /MO $EveryMinutes /TN $TaskName /TR $taskCommand | Out-Host
Write-Host "Installed scheduled task '$TaskName' to update every $EveryMinutes minutes."
