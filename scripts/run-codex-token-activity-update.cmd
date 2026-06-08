@echo off
set "SCRIPT_DIR=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%update-codex-token-activity.ps1" -RepoRoot "%SCRIPT_DIR%.." -Push
