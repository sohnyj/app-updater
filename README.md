# app-updater

Updates local apps from GitHub Releases. Configured through `settings.json`.

`updater.ps1` is app-agnostic. For another app, copy the folder with its own `settings.json`. The shortcut scripts (`shortcut.ps1`, `startmenu.ps1`) are hardcoded for mpv.

## Requirements

- PowerShell 5.1+ (built-in on Windows 10+)

## Installation

1. Click **Code** > **Download ZIP**
2. Extract to `%LOCALAPPDATA%\{APPNAME}\update`

## shortcut.ps1

Creates `update.lnk` in `BaseDirectory`, launching `updater.ps1` via `powershell.exe -ExecutionPolicy Bypass`.

Windows blocks `.ps1` on double-click; the shortcut works around it.

**Usage:**

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\shortcut.ps1
```

Run once, then double-click `update.lnk`.

## How it works

With no local executable, date comparison is skipped and the latest release installs.

1. **Validate**: check paths, stop running apps
2. **Fetch metadata**: latest release info from GitHub
3. **Select targets**: release dates against local timestamps
4. **Download**: fetch selected assets
5. **Verify**: SHA256 against `digest`; `[NONE]` when absent, skip on mismatch
6. **Extract**: unpack archives in the temp directory
7. **Install**: remove the previous install if full, then move files in
8. **Cleanup**: remove the download directory, optionally clear cache

## settings.json

> [!CAUTION]
> A full update deletes everything in `BaseDirectory` except `UpdateDirectory` and `ExcludedNames` matches. `AppCache.Clear` also wipes `AppCache.Directories`. ***Incorrect paths may cause data loss.***

### `Paths`

| Key | Description |
|-----|-------------|
| `BaseDirectory` | App install path |
| `UpdateDirectory` | Script path; downloads land in `download\` under it. Skipped by the full-update deletion |

### `UpdateRules`

| Key | Description |
|-----|-------------|
| `ForceUpdate` | Update regardless of date |
| `LocalTimestampOffsetMinutes` | Minutes added to local `LastWriteTime`, offsetting the build-to-publish gap |
| `AssetTypes.Executable` | Installed as a single file; `LastWriteTime` set to the release date |
| `AssetTypes.Archive` | Extracted before install; original `LastWriteTime` kept. Compressed tarballs unpack in one pass |
| `ExcludedNames` | Names kept during full-update deletion (exact match) |

### `Api`

| Key | Description |
|-----|-------------|
| `Endpoint` | GitHub release API endpoint |
| `Token` | For the metadata request. Empty = 60 req/hour, set = 5000. Not used for downloads |

> [!NOTE]
> `Token` is plain text. Never commit one. Public repositories need none; otherwise use a read-only, minimal-scope token.

### `Apps`

| Key | Description |
|-----|-------------|
| `Executable` | Name used to read `LastWriteTime` |
| `UpdateTargets` | Repository and asset filter pairs |
| `InstallFilters` | Items to install from an archive. Empty = all |

### `UpdateTargets`

| Key | Description |
|-----|-------------|
| `Preferred` | Prefer over the app's other targets |
| `Force` | Update regardless of date |
| `Repository` | GitHub repository as `owner/repo` |
| `AssetFilter` | Substring matched against asset names |

### Misc options

| Key | Description |
|-----|-------------|
| `AppCache.Clear` | Clear them on full update |
| `AppCache.ClearOnPartialUpdate` | Clear on partial updates too |
| `AppCache.Directories` | Cache directories emptied after update |
| `StartMenu.Create` | Run the Start Menu script after a successful update |
| `StartMenu.Script` | Script file name, resolved beside the updater |
| `ErrorActionPreference` | PowerShell error handling (`Continue` / `Stop`) |
| `ProgressPreference` | Progress bar visibility (`SilentlyContinue` to hide) |
