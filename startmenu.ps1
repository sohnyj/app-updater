# Usage: powershell.exe -ExecutionPolicy Bypass -File .\startmenu.ps1

$BaseDirectory = Join-Path $env:LOCALAPPDATA "mpv"
$UserStartMenuPath = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
$ShortcutPath = Join-Path $UserStartMenuPath "mpv.lnk"

$Shell = New-Object -ComObject WScript.Shell
$Shortcut = $Shell.CreateShortcut($ShortcutPath)

$Shortcut.TargetPath = Join-Path $BaseDirectory "mpv.exe"
$Shortcut.WorkingDirectory = $BaseDirectory
$Shortcut.Description = "mpv"
$Shortcut.IconLocation = "$(Join-Path $BaseDirectory 'mpv.exe'), 0"
$Shortcut.Save()

Write-Host "`n [I] Start Menu Path: $ShortcutPath" -ForegroundColor Gray
Write-Host " [+] Start Menu created successfully." -ForegroundColor Green
