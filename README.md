# app-updater

Lightweight app updater that tracks GitHub Releases. Target apps and repositories are configurable via `settings.json`.

No external dependencies — uses built-in PowerShell (`Invoke-WebRequest`, `Get-FileHash`, etc.) and 7-Zip for archive extraction.

`mpv_updater.ps1` is an example name — copy and rename per app (e.g., `vscodium_updater.ps1`), each with its own `settings.json`.

## Requirements

- PowerShell 5.1+ (built-in on Windows 10+)
- [7-Zip](https://www.7-zip.org/) (`7z.exe`) for archive extraction
    - A standalone `7z.exe` is sufficient; installation is not required.

## Installation

1. Click **Code** > **Download ZIP**
2. Extract to `%LOCALAPPDATA%\{APPNAME}\update`

## updater_shortcut.ps1

Creates `update.lnk` in `BaseDirectory` to launch `mpv_updater.ps1` via `powershell.exe -ExecutionPolicy Bypass`.

Windows blocks direct `.ps1` execution by double-click — the shortcut bypasses this.

**Usage:**

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\updater_shortcut.ps1
```

Run once to create `update.lnk`, then double-click it to run the updater.

## How it works

On each run, `mpv_updater.ps1` performs the following steps. If the target executable does not exist locally, date comparison is skipped and the latest release is installed unconditionally (first-run install).

1. **Pre-flight** — verifies target processes are not running and required paths/tools exist
2. **Fetch metadata** — retrieves latest release info from configured GitHub repositories
3. **Select targets** — compares release dates against local file timestamps
4. **Download** — downloads selected release assets
5. **Verify** — validates SHA256 hash against the GitHub `digest` field; warns if unavailable, excludes on mismatch
6. **Deploy** — extracts archives and moves files into the installation directory
7. **Cleanup** — removes temporary directories and optionally clears app cache

## settings.json

> [!CAUTION]
> On a full update, all `BaseDirectory` contents are deleted except `UpdateDirectory` and `ExcludeList` matches. `AppCacheDirectories` are also wiped when `AppCache.Clear` is enabled. ***Incorrect paths may cause data loss.***

### `Environment`

| Key | Description |
|-----|-------------|
| `Paths.BaseDirectory` | App installation path |
| `Paths.UpdateDirectory` | Update script and temp path — must be under `BaseDirectory` to be excluded from full-update deletion |
| `Paths.AppCacheDirectories` | Cache directories to clean after update (contents only, not the directories) |
| `ZipExecutablePath` | Path to `7z.exe` |

> [!NOTE]
> `BaseDirectory` is designed for user-space directories like `%LOCALAPPDATA%`. Using system-wide paths like `%PROGRAMFILES%` requires administrator privileges and is ***strongly discouraged*** — it bypasses UAC and risks unintended system-wide changes.

### `GlobalUpdateRules`

| Key | Description |
|-----|-------------|
| `VersionComparison.ForceUpdate` | If `true`, always updates regardless of date |
| `VersionComparison.OffsetMinutes` | Minutes added to local `LastWriteTime`. Compensates for build-to-publish time gap |
| `FileTypes.Executable` | `LastWriteTime` is overwritten with release date for future comparison |
| `FileTypes.Archive` | Extracted files keep their original `LastWriteTime` |
| `ExcludeList` | Items excluded from deletion during full update (matched by name substring) |
| `ApiEndpoint` | GitHub unauthenticated: 60 requests/hour rate limit |

### `Apps`

| Key | Description |
|-----|-------------|
| `Executable` | Executable name used to read `LastWriteTime` for comparison |
| `UpdateTargets` | Repository/filter pairs to match release assets |
| `DeployTargets` | Filter for items to deploy from extracted archive. Empty = deploy all |

### `UpdateTargets`

| Key | Description |
|-----|-------------|
| `Pin` | If `true`, preferred over other targets in the same app |
| `Force` | If `true`, always updates this target regardless of date |
| `Path` | GitHub repository path (`owner/repo`) |
| `Filter` | Substring to match against release asset names |

### Misc options

| Key | Description |
|-----|-------------|
| `AppCache.Clear` | If `true`, clears `AppCacheDirectories` on full update |
| `AppCache.ForceOnPartial` | If `true`, also clears cache on partial updates |
| `ErrorActionPreference` | PowerShell error handling (`Continue` / `Stop`, etc.) |
| `ProgressPreference` | Progress bar visibility (`SilentlyContinue` to suppress) |

### Default settings

| App | Source repository | Asset filter |
|-----|------------------|--------------|
| mpv | `sohnyj/minimal-mpv-winbuild` | `mpv-x86_64-v3` |
| ffmpeg | `sohnyj/minimal-mpv-winbuild` | `ffmpeg-x86_64-v3` |
| yt-dlp | `yt-dlp/yt-dlp-nightly-builds` | `yt-dlp.exe` |

## Example: multiple update sources

Multiple repositories can be listed under `UpdateTargets` for the same app. The updater selects the most recent asset across all sources.

```json
"Apps": {
    "mpv": {
        "Executable": "mpv.exe",
        "UpdateTargets": [
            { "Pin": false, "Force": false, "Path": "shinchiro/mpv-winbuild-cmake", "Filter": "mpv-x86_64-v3" },
            { "Pin": false, "Force": false, "Path": "zhongfly/mpv-winbuild",        "Filter": "mpv-x86_64-v3" },
            { "Pin": false, "Force": false, "Path": "sohnyj/minimal-mpv-winbuild",  "Filter": "mpv-x86_64-znver3" }
        ],
        "DeployTargets": ["mpv", "mpv.com", "mpv.exe"]
    },
    "ffmpeg": {
        "Executable": "ffmpeg.exe",
        "UpdateTargets": [
            { "Pin": false, "Force": false, "Path": "shinchiro/mpv-winbuild-cmake", "Filter": "ffmpeg-x86_64-v3" },
            { "Pin": false, "Force": false, "Path": "zhongfly/mpv-winbuild",        "Filter": "ffmpeg-x86_64-v3" },
            { "Pin": false, "Force": false, "Path": "sohnyj/minimal-mpv-winbuild",  "Filter": "ffmpeg-x86_64-znver3" }
        ],
        "DeployTargets": []
    },
    "yt-dlp": {
        "Executable": "yt-dlp.exe",
        "UpdateTargets": [
            { "Pin": false, "Force": false, "Path": "yt-dlp/yt-dlp",                "Filter": "yt-dlp.exe" },
            { "Pin": false, "Force": false, "Path": "yt-dlp/yt-dlp-nightly-builds", "Filter": "yt-dlp.exe" }
        ],
        "DeployTargets": []
    }
}
```

Set `"Pin": true` to prefer a specific source over latest-by-date selection. Set `"Force": true` on a target to always update it regardless of date.

## Example: VSCodium

Any app distributed via GitHub Releases can be tracked. Example: VSCodium as a portable installation and update.

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
        "ZipExecutablePath": "%ProgramFiles%\\7-Zip\\7z.exe"
    },
    "GlobalUpdateRules": {
        "VersionComparison": {
            "ForceUpdate": false,
            "OffsetMinutes": 60
        },
        "FileTypes": {
            "Executable": [".exe"],
            "Archive": [".7z", ".zip", ".tar.gz"]
        },
        "ExcludeList": ["update.lnk"],
        "ApiEndpoint": "https://api.github.com/repos/{0}/releases/latest"
    },
    "Apps": {
        "vscodium": {
            "Executable": "vscodium.exe",
            "UpdateTargets": [
                { "Pin": false, "Force": false, "Path": "VSCodium/vscodium", "Filter": "VSCodium-win32-x64" }
            ],
            "DeployTargets": []
        }
    },
    "AppCache": {
        "Clear": true,
        "ForceOnPartial": false
    },
    "ErrorActionPreference": "Continue",
    "ProgressPreference": "SilentlyContinue"
}
```
