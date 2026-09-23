# Usage: powershell.exe -ExecutionPolicy Bypass -File .\startmenu.ps1

$BaseDirectory = Join-Path -Path $env:LOCALAPPDATA -ChildPath "mpv"
$ExecutablePath = Join-Path -Path $BaseDirectory -ChildPath "mpv.exe"
$StartMenuPath = Join-Path -Path $env:APPDATA -ChildPath "Microsoft\Windows\Start Menu\Programs"
$ShortcutPath = Join-Path -Path $StartMenuPath -ChildPath "mpv.lnk"

$Shell = New-Object -ComObject WScript.Shell
$Shortcut = $Shell.CreateShortcut($ShortcutPath)

$Shortcut.TargetPath = $ExecutablePath
$Shortcut.WorkingDirectory = $BaseDirectory
$Shortcut.Description = "mpv"
$Shortcut.IconLocation = "$ExecutablePath,0"
$Shortcut.Save()

Write-Host "`n [I] Start Menu Path: $ShortcutPath" -ForegroundColor Gray
Write-Host " [+] Start Menu created successfully." -ForegroundColor Green
