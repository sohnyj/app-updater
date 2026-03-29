# app-updater

app-updater that keeps any app up to date by tracking GitHub Releases. Target apps and repositories are fully configurable via `settings.json`.

Designed to be lightweight with no external dependencies — relies entirely on built-in PowerShell features (`Invoke-WebRequest`, `Get-FileHash`, etc.) and 7-Zip for archive extraction. No package managers, runtimes, or third-party libraries required.

The script is named `mpv_updater.ps1` as an example — it is intended to be copied and renamed per app (e.g., `vscodium_updater.ps1`), each paired with its own `settings.json`.

## Requirements

- PowerShell 5.1 or later (built-in on Windows 10 and later)
- [7-Zip](https://www.7-zip.org/) (`7z.exe`), required for extracting archive assets
    - You don't necessarily need to install 7-Zip; having just `7z.exe` is sufficient.

## app-updater path
- `%LOCALAPPDATA%\APPNAME\update`
- Save the app-updater files to the path above.
    - `update` folder is a temporary directory used for processing update files.
    - `update` folder is excluded from cleanup logic in the `BaseDirectory`.

## Note on BaseDirectory path

This updater is designed for user-space directories such as `%LOCALAPPDATA%`. Installing to system-wide paths such as `%PROGRAMFILES%` requires running the script as administrator and is **strongly discouraged** — it bypasses UAC protections and risks unintended system-wide changes.

## How it works

On each run, `mpv_updater.ps1` performs the following steps. If the target executable does not exist locally, the date comparison is skipped and the latest release is downloaded and installed unconditionally — acting as an installer on first run.

1. **Pre-flight** — checks that target processes are not running and required paths/tools exist
2. **Remote discovery** — fetches the latest release metadata from each configured GitHub repository
3. **Selection** — compares release publish dates against local file timestamps to determine what needs updating
4. **Download** — downloads the selected release assets
5. **Verification** — validates SHA256 hash of downloaded files against the `digest` field from the GitHub Releases API; proceeds with a warning if no hash is available, excludes the file if hash mismatches
6. **Deploy** — extracts archives and copies files into the installation directory
7. **Cleanup** — removes temporary download directories and optionally clears app cache

## updater_shortcut.ps1

Creates a `.lnk` shortcut (`update.lnk`) in `BaseDirectory` that launches `mpv_updater.ps1` directly via `powershell.exe -ExecutionPolicy Bypass`.

Run this once after initial setup. The shortcut is needed because Windows does not allow directly double-clicking a `.ps1` file to execute it — a shortcut with the appropriate execution policy bypasses this restriction and provides a convenient one-click entry point for running the updater.

**Usage:**

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\updater_shortcut.ps1
```

Once `update.lnk` is created, double-click it to run the update process.

## settings.json

Configuration file that controls updater behavior.

**Caution:** Choose paths carefully. On a full update, all contents in `BaseDirectory` are deleted and replaced except for `UpdateDirectory` and items matching `GlobalExcludeList`. `AppCacheDirectories` entries are also wiped when `AppCacheClear` is enabled. **Setting these to wrong directories may result in unintended data loss.**

### `Environment`

| Key | Description |
|-----|-------------|
| `Paths.BaseDirectory` | Base path where apps are installed |
| `Paths.UpdateDirectory` | Temporary path for downloaded update files — must be a subdirectory of `BaseDirectory` to be excluded from deletion during a full update |
| `Paths.AppCacheDirectories` | Cache directories to clean after update — only the contents inside each directory are deleted, not the directories themselves |
| `ZipExecutablePath` | Path to 7-Zip executable used for extraction |

### `UpdateRules`

| Key | Description |
|-----|-------------|
| `VersionComparison.IgnorePublishDate` | If `true`, skips date comparison and always updates |
| `VersionComparison.OffsetMinutes` | Minutes added to the local file's `LastWriteTime` before comparing against the release publish date — update proceeds only if the release is newer than this adjusted time. Needed because binary build time and release publish time are not identical. For multi-architecture builds this gap can be significant, so adjust accordingly |
| `FileTypes.Executable` | File extensions treated as executables — deployed files of this type have their `LastWriteTime` overwritten with the release publish date, enabling accurate comparison on the next update run |
| `FileTypes.Archive` | File extensions treated as archives — extracted files are deployed as-is, preserving their original `LastWriteTime` |
| `GlobalExcludeList` | Files/folders to exempt from deletion during a full update — during deployment, all contents in `BaseDirectory` are deleted and replaced except for `UpdateDirectory` and items whose name contains any of the listed strings |
| `ApiEndpoint` | GitHub Releases API endpoint (`{0}` is replaced with the `Path` value). Unauthenticated requests are subject to GitHub's rate limit of 60 requests per hour |

### `Apps`

Defines apps to update. Each app has the following fields.

| Key | Description |
|-----|-------------|
| `Executable` | Executable name used to read `LastWriteTime` for update comparison |
| `UpdateTargets` | List of repository/filter pairs used to search for release asset candidates |
| `DeployTargets` | Filter list for selecting items to deploy from the extracted archive. Empty array deploys all contents |

### `UpdateTargets`

| Key | Description |
|-----|-------------|
| `Pin` | If `true`, this target is preferred over others in the same app when selecting the latest candidate |
| `Path` | GitHub repository path (`owner/repo`) |
| `Filter` | String to match against release asset names |

#### Misc options

| Key | Description |
|-----|-------------|
| `AppCacheClear` | If `true`, deletes `AppCacheDirectories` after update — only runs on a full update; skipped when only a partial set of apps is updated |
| `ErrorActionPreference` | PowerShell error handling behavior (`Continue` / `Stop`, etc.) |
| `ProgressPreference` | PowerShell progress bar visibility (`SilentlyContinue` to suppress) |

### Default settings

| App | Source repository | Asset filter |
|-----|------------------|--------------|
| mpv | `sohnyj/minimal-mpv-winbuild` | `mpv-x86_64-v3` |
| ffmpeg | `sohnyj/minimal-mpv-winbuild` | `ffmpeg-x86_64-v3` |
| yt-dlp | `yt-dlp/yt-dlp-nightly-builds` | `yt-dlp.exe` |

## Example: multiple update sources

Multiple repositories can be listed under `UpdateTargets` for the same app. The updater selects the most recently published asset across all sources. Each app under `Apps` shares `BaseDirectory`.

```json
"Apps": {
    "mpv": {
        "Executable": "mpv.exe",
        "UpdateTargets": [
            { "Pin": false, "Path": "shinchiro/mpv-winbuild-cmake", "Filter": "mpv-x86_64-v3" },
            { "Pin": false, "Path": "zhongfly/mpv-winbuild",        "Filter": "mpv-x86_64-v3" },
            { "Pin": false, "Path": "sohnyj/minimal-mpv-winbuild",  "Filter": "mpv-x86_64-znver3" }
        ],
        "DeployTargets": ["mpv", "mpv.com", "mpv.exe"]
    },
    "ffmpeg": {
        "Executable": "ffmpeg.exe",
        "UpdateTargets": [
            { "Pin": false, "Path": "shinchiro/mpv-winbuild-cmake", "Filter": "ffmpeg-x86_64-v3" },
            { "Pin": false, "Path": "zhongfly/mpv-winbuild",        "Filter": "ffmpeg-x86_64-v3" },
            { "Pin": false, "Path": "sohnyj/minimal-mpv-winbuild",  "Filter": "ffmpeg-x86_64-znver3" }
        ],
        "DeployTargets": []
    },
    "yt-dlp": {
        "Executable": "yt-dlp.exe",
        "UpdateTargets": [
            { "Pin": false, "Path": "yt-dlp/yt-dlp",                "Filter": "yt-dlp.exe" },
            { "Pin": false, "Path": "yt-dlp/yt-dlp-nightly-builds", "Filter": "yt-dlp.exe" }
        ],
        "DeployTargets": []
    }
}
```

To pin a specific source, set `"Pin": true` on the desired target. When any target in the group is pinned, the pinned one takes priority over the latest-by-date selection.

## Example: VSCodium

The updater is not limited to media tools. Any app distributed via GitHub Releases can be tracked. The following configuration manages VSCodium as a standalone portable installation.

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
    "UpdateRules": {
        "VersionComparison": {
            "IgnorePublishDate": false,
            "OffsetMinutes": 60
        },
        "FileTypes": {
            "Executable": [".exe"],
            "Archive": [".7z", ".zip", ".tar.gz"]
        },
        "GlobalExcludeList": ["update.lnk"],
        "ApiEndpoint": "https://api.github.com/repos/{0}/releases/latest"
    },
    "Apps": {
        "vscodium": {
            "Executable": "vscodium.exe",
            "UpdateTargets": [
                { "Pin": false, "Path": "VSCodium/vscodium", "Filter": "VSCodium-win32-x64" }
            ],
            "DeployTargets": []
        }
    },
    "AppCacheClear": true,
    "ErrorActionPreference": "Continue",
    "ProgressPreference": "SilentlyContinue"
}
```
