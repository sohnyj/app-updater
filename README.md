# app-updater

Updates local apps from GitHub Releases. Configured through `settings.json`.

Scripts are app-agnostic. For another app, copy the folder with its own `settings.json`.

## Requirements

- PowerShell 5.1+ (built-in on Windows 10+)
- `tar.exe` for extraction — [built into Windows](https://learn.microsoft.com/en-us/windows/tar/) since Windows 10 1803

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

1. **Pre-flight**: stop running apps, check paths and tools
2. **Fetch metadata**: latest release info from GitHub
3. **Select targets**: release dates against local timestamps
4. **Download**: fetch selected assets
5. **Verify**: SHA256 against `digest`; `[NA]` when absent, skip on mismatch
6. **Deploy**: extract archives, move files in
7. **Cleanup**: remove temp directories, optionally clear cache

## settings.json

> [!CAUTION]
> A full update deletes everything in `BaseDirectory` except `UpdateDirectory` and `ExcludeList` matches. `AppCache.Clear` also wipes `AppCacheDirectories`. ***Incorrect paths may cause data loss.***

### `Environment`

| Key | Description |
|-----|-------------|
| `Paths.BaseDirectory` | App install path |
| `Paths.UpdateDirectory` | Script and temp path. Skipped by the full-update deletion |
| `Paths.AppCacheDirectories` | Cache directories emptied after update |
| `TarExecutablePath` | Path to `tar.exe`. Defaults to the `System32` copy |

### `GlobalUpdateRules`

| Key | Description |
|-----|-------------|
| `VersionComparison.ForceUpdate` | Update regardless of date |
| `VersionComparison.OffsetMinutes` | Minutes added to local `LastWriteTime`, offsetting the build-to-publish gap |
| `FileTypes.Executable` | Deployed as a single file; `LastWriteTime` set to the release date |
| `FileTypes.Archive` | Extracted before deploy; original `LastWriteTime` kept. Compressed tarballs unpack in one pass |
| `ExcludeList` | Names kept during full-update deletion (exact match) |
| `ApiEndpoint` | GitHub release API endpoint |
| `ApiToken` | For the metadata request. Empty = 60 req/hour, set = 5000. Not used for downloads |

> [!NOTE]
> `ApiToken` is plain text. Never commit one. Public repositories need none; otherwise use a read-only, minimal-scope token.

### `Apps`

| Key | Description |
|-----|-------------|
| `Executable` | Name used to read `LastWriteTime` |
| `UpdateTargets` | Repository and filter pairs |
| `DeployFilters` | Items to deploy from an archive. Empty = all |

### `UpdateTargets`

| Key | Description |
|-----|-------------|
| `Pin` | Prefer over the app's other targets |
| `Force` | Update regardless of date |
| `Path` | Repository as `owner/repo` |
| `Filter` | Substring matched against asset names |

### Misc options

| Key | Description |
|-----|-------------|
| `AppCache.Clear` | Clear `AppCacheDirectories` on full update |
| `AppCache.ForceOnPartial` | Clear on partial updates too |
| `ErrorActionPreference` | PowerShell error handling (`Continue` / `Stop`) |
| `ProgressPreference` | Progress bar visibility (`SilentlyContinue` to hide) |
