# app-updater

Lightweight app updater that tracks GitHub Releases. Target apps and repositories are configurable via `settings.json`.

The scripts are app-agnostic. For another app, copy the folder and give it its own `settings.json`.

## Requirements

- PowerShell 5.1+ (built-in on Windows 10+)
- `tar.exe` for archive extraction — [built into Windows](https://learn.microsoft.com/en-us/windows/tar/) since Windows 10 1803

## Installation

1. Click **Code** > **Download ZIP**
2. Extract to `%LOCALAPPDATA%\{APPNAME}\update`

## app_updater_shortcut.ps1

Creates `update.lnk` in `BaseDirectory` to launch `app_updater.ps1` via `powershell.exe -ExecutionPolicy Bypass`.

Windows blocks direct `.ps1` execution by double-click; the shortcut bypasses this.

**Usage:**

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\app_updater_shortcut.ps1
```

Run once, then double-click `update.lnk` to run the updater.

## How it works

On first run (target executable absent), date comparison is skipped and the latest release is installed.

1. **Pre-flight**: check target processes stopped, paths and tools present
2. **Fetch metadata**: get latest release info from GitHub
3. **Select targets**: compare release dates with local timestamps
4. **Download**: fetch selected assets
5. **Verify**: check SHA256 against `digest`; warn if missing, skip on mismatch
6. **Deploy**: extract archives, move files to the install directory
7. **Cleanup**: remove temp directories, optionally clear cache

## settings.json

> [!CAUTION]
> On a full update, all `BaseDirectory` contents are deleted except `UpdateDirectory` and `ExcludeList` matches. `AppCacheDirectories` are also wiped when `AppCache.Clear` is enabled. ***Incorrect paths may cause data loss.***

### `Environment`

| Key | Description |
|-----|-------------|
| `Paths.BaseDirectory` | App install path |
| `Paths.UpdateDirectory` | Script and temp path. Must be under `BaseDirectory` to survive full-update deletion |
| `Paths.AppCacheDirectories` | Cache directories to clean after update (contents only) |
| `TarExecutablePath` | Path to `tar.exe`. Defaults to the `System32` copy |

> [!NOTE]
> User-space directories like `%LOCALAPPDATA%` are recommended for `BaseDirectory`. System-wide paths like `%PROGRAMFILES%` require administrator privileges and are not recommended.

### `GlobalUpdateRules`

| Key | Description |
|-----|-------------|
| `VersionComparison.ForceUpdate` | Always update regardless of date |
| `VersionComparison.OffsetMinutes` | Minutes added to local `LastWriteTime` to offset the build-to-publish gap |
| `FileTypes.Executable` | Extensions deployed as a single file; `LastWriteTime` set to the release date |
| `FileTypes.Archive` | Extensions extracted before deploy; original `LastWriteTime` kept. Compressed tarballs unpack in one pass |
| `ExcludeList` | Names kept during full-update deletion (exact match) |
| `ApiEndpoint` | GitHub release API endpoint |
| `ApiToken` | Token for the metadata request. Empty = 60 req/hour, set = 5000. Not used for downloads |

> [!NOTE]
> `ApiToken` is stored in plain text. Never commit or share a `settings.json` with a real token. Use a read-only, minimal-scope token (public repositories need none).

### `Apps`

| Key | Description |
|-----|-------------|
| `Executable` | Name used to read `LastWriteTime` |
| `UpdateTargets` | Repository/filter pairs matching release assets |
| `DeployFilters` | Items to deploy from an archive. Empty = all |

### `UpdateTargets`

| Key | Description |
|-----|-------------|
| `Pin` | Prefer this target over others in the same app |
| `Force` | Always update this target regardless of date |
| `Path` | Repository path (`owner/repo`) |
| `Filter` | Substring matched against asset names |

### Misc options

| Key | Description |
|-----|-------------|
| `AppCache.Clear` | Clear `AppCacheDirectories` on full update |
| `AppCache.ForceOnPartial` | Also clear cache on partial updates |
| `ErrorActionPreference` | PowerShell error handling (`Continue` / `Stop`) |
| `ProgressPreference` | Progress bar visibility (`SilentlyContinue` to hide) |

## Example: multiple update sources

List multiple repositories under one app's `UpdateTargets`; the updater picks the most recent asset across all sources.

```json
"Apps": {
    "mpv": {
        "Executable": "mpv.exe",
        "UpdateTargets": [
            { "Pin": false, "Force": false, "Path": "shinchiro/mpv-winbuild-cmake", "Filter": "mpv-x86_64-v3" },
            { "Pin": false, "Force": false, "Path": "zhongfly/mpv-winbuild",        "Filter": "mpv-x86_64-v3" },
            { "Pin": false, "Force": false, "Path": "sohnyj/minimal-mpv-winbuild",  "Filter": "mpv-x86_64-znver3" }
        ],
        "DeployFilters": ["mpv", "mpv.com", "mpv.exe"]
    },
    "ffmpeg": {
        "Executable": "ffmpeg.exe",
        "UpdateTargets": [
            { "Pin": false, "Force": false, "Path": "shinchiro/mpv-winbuild-cmake", "Filter": "ffmpeg-x86_64-v3" },
            { "Pin": false, "Force": false, "Path": "zhongfly/mpv-winbuild",        "Filter": "ffmpeg-x86_64-v3" },
            { "Pin": false, "Force": false, "Path": "sohnyj/minimal-mpv-winbuild",  "Filter": "ffmpeg-x86_64-znver3" }
        ],
        "DeployFilters": []
    },
    "yt-dlp": {
        "Executable": "yt-dlp.exe",
        "UpdateTargets": [
            { "Pin": false, "Force": false, "Path": "yt-dlp/yt-dlp",                "Filter": "yt-dlp.exe" },
            { "Pin": false, "Force": false, "Path": "yt-dlp/yt-dlp-nightly-builds", "Filter": "yt-dlp.exe" }
        ],
        "DeployFilters": []
    }
}
```

## Example: VSCodium

Any app on GitHub Releases can be tracked. Example: portable VSCodium.

```json
{
    "Environment": {
        "Paths": {
            "BaseDirectory": "%LOCALAPPDATA%\\vscodium",
            "UpdateDirectory": "%LOCALAPPDATA%\\vscodium\\update",
            "AppCacheDirectories": [
                "%APPDATA%\\VSCodium\\cache",
                "%APPDATA%\\VSCodium\\gpucache",
                "%APPDATA%\\VSCodium\\logs"
            ]
        },
        "TarExecutablePath": "%SystemRoot%\\System32\\tar.exe"
    },
    "GlobalUpdateRules": {
        "VersionComparison": {
            "ForceUpdate": false,
            "OffsetMinutes": 60
        },
        "FileTypes": {
            "Executable": [".exe"],
            "Archive": [".7z", ".zip", ".tar", ".tar.gz"]
        },
        "ExcludeList": ["update.lnk"],
        "ApiEndpoint": "https://api.github.com/repos/{0}/releases/latest",
        "ApiToken": ""
    },
    "Apps": {
        "vscodium": {
            "Executable": "vscodium.exe",
            "UpdateTargets": [
                { "Pin": false, "Force": false, "Path": "VSCodium/vscodium", "Filter": "VSCodium-win32-x64" }
            ],
            "DeployFilters": []
        }
    },
    "AppCache": {
        "Clear": true,
        "ForceOnPartial": false
    },
    "StartMenu": {
        "Create": false,
        "Script": "app_startmenu_shortcut.ps1"
    },
    "ErrorActionPreference": "Continue",
    "ProgressPreference": "SilentlyContinue"
}
```
