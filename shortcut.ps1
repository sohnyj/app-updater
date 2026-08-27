# Usage: powershell.exe -ExecutionPolicy Bypass -File .\shortcut.ps1

$BaseDirectory = Join-Path $env:LOCALAPPDATA "mpv"
$ScriptPath = Join-Path $BaseDirectory "update\updater.ps1"
$ShortcutPath = Join-Path $BaseDirectory "update.lnk"

$Shell = New-Object -ComObject WScript.Shell
$Shortcut = $Shell.CreateShortcut($ShortcutPath)
$Shortcut.TargetPath = "powershell.exe"
$Shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File ""$ScriptPath"""
$Shortcut.WorkingDirectory = Split-Path $ScriptPath -Parent
$Shortcut.WindowStyle = 1
$Shortcut.IconLocation = "powershell.exe,0"
$Shortcut.Description = "Update mpv, ffmpeg and yt-dlp"

$Shortcut.Save()

Write-Host "`n [I] Updater Path: $ShortcutPath" -ForegroundColor Gray
Write-Host " [+] Updater Shortcut created successfully.`n" -ForegroundColor Green
