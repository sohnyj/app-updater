# app-updater

Updates local apps from GitHub Releases. Configured through `settings.json`.

Scripts are app-agnostic. For another app, copy the folder with its own `settings.json`.

## Requirements

- PowerShell 5.1+ (built-in on Windows 10+)

## Installation

1. Click **Code** > **Download ZIP**
2. Extract to `%LOCALAPPDATA%\{APPNAME}\update`

## app_updater_shortcut.ps1

Creates `update.lnk` in `BaseDirectory`, launching `app_updater.ps1` via `powershell.exe -ExecutionPolicy Bypass`.

Windows blocks `.ps1` on double-click; the shortcut works around it.

**Usage:**

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\app_updater_shortcut.ps1
```

Run once, then double-click `update.lnk`.

## How it works

With no local executable, date comparison is skipped and the latest release installs.

1. **Validate**: stop running apps, check paths and tools
2. **Fetch metadata**: latest release info from GitHub
3. **Select targets**: release dates against local timestamps
4. **Download**: fetch selected assets
5. **Verify**: SHA256 against `digest`; `[NONE]` when absent, skip on mismatch
6. **Deploy**: extract archives, move files in
7. **Cleanup**: remove temp directories, optionally clear cache

## settings.json

> [!CAUTION]
> A full update deletes everything in `BaseDirectory` except `UpdateDirectory` and `ExcludedNames` matches. `AppCache.Clear` also wipes `AppCacheDirectories`. ***Incorrect paths may cause data loss.***

### `Paths`

| Key | Description |
|-----|-------------|
| `BaseDirectory` | App install path |
| `UpdateDirectory` | Script and temp path. Skipped by the full-update deletion |
| `AppCacheDirectories` | Cache directories emptied after update |

### `UpdateRules`

| Key | Description |
|-----|-------------|
| `VersionComparison.ForceUpdate` | Update regardless of date |
| `VersionComparison.LocalTimestampOffsetMinutes` | Minutes added to local `LastWriteTime`, offsetting the build-to-publish gap |
| `FileTypes.Executable` | Deployed as a single file; `LastWriteTime` set to the release date |
| `FileTypes.Archive` | Extracted before deploy; original `LastWriteTime` kept. Compressed tarballs unpack in one pass |
| `ExcludedNames` | Names kept during full-update deletion (exact match) |
| `ApiEndpoint` | GitHub release API endpoint |
| `ApiToken` | For the metadata request. Empty = 60 req/hour, set = 5000. Not used for downloads |

> [!NOTE]
> `ApiToken` is plain text. Never commit one. Public repositories need none; otherwise use a read-only, minimal-scope token.

### `Apps`

| Key | Description |
|-----|-------------|
| `Executable` | Name used to read `LastWriteTime` |
| `UpdateTargets` | Repository and asset filter pairs |
| `DeployFilters` | Items to deploy from an archive. Empty = all |

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
| `AppCache.Clear` | Clear `AppCacheDirectories` on full update |
| `AppCache.ClearOnPartialUpdate` | Clear on partial updates too |
| `ErrorActionPreference` | PowerShell error handling (`Continue` / `Stop`) |
| `ProgressPreference` | Progress bar visibility (`SilentlyContinue` to hide) |
