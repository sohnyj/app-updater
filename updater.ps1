#Requires -Version 5.1

# Data Model
enum AssetType {
    Executable
    Archive
}

class UpdateFailure : System.Exception {
    [string]$UiKey
    [object[]]$FormatArgs

    UpdateFailure([string]$UiKey) : base($UiKey) {
        $this.UiKey = $UiKey
    }

    UpdateFailure([string]$UiKey, [object[]]$FormatArgs) : base($UiKey) {
        $this.UiKey = $UiKey
        $this.FormatArgs = $FormatArgs
    }
}

class UpdateTarget {
    [string]$Repository
    [string]$AssetFilter
    [string]$FilterPattern
    [bool]$Preferred
    [bool]$Force

    UpdateTarget([PSCustomObject]$Definition) {
        $this.Repository = $Definition.Repository
        $this.AssetFilter = [string]$Definition.AssetFilter
        $this.FilterPattern = if ($this.AssetFilter.Contains('*')) { $this.AssetFilter } else { "*$($this.AssetFilter)*" }
        $this.Preferred = [bool]$Definition.Preferred
        $this.Force = [bool]$Definition.Force
    }
}

class App {
    [string]$Name
    [string]$ExecutablePath
    [string]$ProcessName
    [string[]]$InstallFilters
    [UpdateTarget[]]$UpdateTargets

    App([string]$Name, [PSCustomObject]$Definition, [string]$BaseDirectory) {
        $this.Name = $Name
        $this.ExecutablePath = Join-Path -Path $BaseDirectory -ChildPath $Definition.Executable
        $this.ProcessName = [System.IO.Path]::GetFileNameWithoutExtension($Definition.Executable)
        $this.InstallFilters = $Definition.InstallFilters
        $this.UpdateTargets = @(foreach ($Target in $Definition.UpdateTargets) { [UpdateTarget]::new($Target) })
    }
}

class ReleaseAsset {
    [string]$Name
    [string]$DownloadUrl
    [string]$Digest

    ReleaseAsset([PSCustomObject]$ApiAsset) {
        $this.Name = $ApiAsset.name
        $this.DownloadUrl = $ApiAsset.browser_download_url
        $this.Digest = $ApiAsset.digest
    }
}

class Release {
    [string]$Repository
    [DateTime]$PublishedAt
    [ReleaseAsset[]]$Assets

    Release([string]$Repository, [DateTime]$PublishedAt, [object[]]$ApiAssets) {
        $this.Repository = $Repository
        $this.PublishedAt = $PublishedAt
        $this.Assets = @(foreach ($ApiAsset in $ApiAssets) { [ReleaseAsset]::new($ApiAsset) })
    }
}

class RunningProcess {
    [App]$App
    [System.Diagnostics.Process]$Process

    RunningProcess([App]$App, [System.Diagnostics.Process]$Process) {
        $this.App = $App
        $this.Process = $Process
    }
}

class SelectedAsset {
    [App]$App
    [UpdateTarget]$Target
    [DateTime]$PublishedAt
    [ReleaseAsset]$ReleaseAsset
    [AssetType]$Type
    [string]$AssetDirectory
    [string]$FilePath

    SelectedAsset([App]$App, [UpdateTarget]$Target, [DateTime]$PublishedAt, [ReleaseAsset]$ReleaseAsset, [AssetType]$Type, [string]$DownloadDirectory) {
        $this.App = $App
        $this.Target = $Target
        $this.PublishedAt = $PublishedAt
        $this.ReleaseAsset = $ReleaseAsset
        $this.Type = $Type
        $this.AssetDirectory = Join-Path -Path $DownloadDirectory -ChildPath $App.Name
        $this.FilePath = Join-Path -Path $this.AssetDirectory -ChildPath $ReleaseAsset.Name
    }
}

# Configuration & Environment
function Import-JsonFile {
    param ([Parameter(Mandatory)] [string]$FilePath)

    if (-not (Test-Path -Path $FilePath -PathType Leaf)) {
        Write-Host " [X] Not found: $FilePath" -ForegroundColor Red
        $null = Read-Host
        exit 1
    }
    try {
        return Get-Content -Path $FilePath -Raw | ConvertFrom-Json
    } catch {
        Write-Host " [X] Failed to parse: $FilePath" -ForegroundColor Red
        Write-Host "     $($_.Exception.Message)" -ForegroundColor Red
        $null = Read-Host
        exit 1
    }
}

function Resolve-ConfiguredPath {
    param ([Parameter(Mandatory)] [string]$Path)

    $ExpandedPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
    $RootPath = [System.IO.Path]::GetPathRoot($ExpandedPath)
    if ($ExpandedPath.Length -le $RootPath.Length) { return $ExpandedPath }
    return $ExpandedPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
}

$Settings = Import-JsonFile -FilePath (Join-Path -Path $PSScriptRoot -ChildPath "settings.json")
$UiTemplates = Import-JsonFile -FilePath (Join-Path -Path $PSScriptRoot -ChildPath "ui.json")

$UpdateRules = $Settings.UpdateRules
$BaseDirectory = Resolve-ConfiguredPath -Path $Settings.Paths.BaseDirectory
$UpdateDirectory = Resolve-ConfiguredPath -Path $Settings.Paths.UpdateDirectory
$TarExecutablePath = Join-Path -Path $env:SystemRoot -ChildPath "System32\tar.exe"
$DownloadDirectory = Join-Path -Path $UpdateDirectory -ChildPath "download"
$AppCacheDirectories = @($Settings.AppCache.Directories) | ForEach-Object { Resolve-ConfiguredPath -Path $_ }

$ErrorActionPreference = $Settings.ErrorActionPreference
$ProgressPreference = $Settings.ProgressPreference

# Functions
function Write-UiMessage {
    param (
        [Parameter(Mandatory)] [string]$UiKey,
        [object[]]$FormatArgs,
        [switch]$NoNewline
    )

    $UiTemplate = $UiTemplates.$UiKey
    $DisplayText = if ($null -ne $FormatArgs -and $FormatArgs.Count -gt 0) {
        $UiTemplate.Template -f $FormatArgs
    } else {
        $UiTemplate.Template
    }
    Write-Host $DisplayText -ForegroundColor $UiTemplate.Color -NoNewline:$NoNewline
}

function Exit-WithMessage {
    param ([switch]$Fail)

    if ($Fail) {
        [System.Media.SystemSounds]::Hand.Play()
    } else {
        [System.Media.SystemSounds]::Asterisk.Play()
    }
    Write-UiMessage -UiKey "PressEnterExit"
    $null = Read-Host
    if ($Fail) { exit 1 } else { exit 0 }
}

function Test-ExcludedName {
    param ([Parameter(Mandatory)] [string]$Name)

    return $UpdateRules.ExcludedNames -contains $Name
}

function Test-PathUnderDirectory {
    param (
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Directory
    )

    $DirectoryPrefix = $Directory + [System.IO.Path]::DirectorySeparatorChar
    return $Path.StartsWith($DirectoryPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-ConfiguredApp {
    return @(foreach ($AppProperty in $Settings.Apps.PSObject.Properties) {
        if ([string]::IsNullOrEmpty($AppProperty.Value.Executable)) {
            throw [UpdateFailure]::new("NoExecutable", @($AppProperty.Name))
        }
        [App]::new($AppProperty.Name, $AppProperty.Value, $BaseDirectory)
    })
}

function Stop-RunningProcess {
    param ([App[]]$Apps)

    $RunningProcesses = @(foreach ($App in $Apps) {
        foreach ($Process in @(Get-Process -Name $App.ProcessName -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrEmpty($Process.Path) -or
                -not (Test-PathUnderDirectory -Path $Process.Path -Directory $BaseDirectory)) {
                continue
            }
            [RunningProcess]::new($App, $Process)
        }
    })
    if ($RunningProcesses.Count -gt 0) {
        [System.Media.SystemSounds]::Beep.Play()
        Write-UiMessage -UiKey "AppRunning"
        foreach ($RunningProcess in $RunningProcesses) {
            Write-UiMessage -UiKey "AppRunningItem" -FormatArgs @($RunningProcess.App.Name)
        }
        Write-UiMessage -UiKey "AppContinuePrompt" -NoNewline
        $UserChoice = Read-Host
        if ($UserChoice -notmatch "^[yY]$") {
            throw [UpdateFailure]::new("UserCancel")
        }
        foreach ($RunningProcess in $RunningProcesses) {
            Stop-Process -Id $RunningProcess.Process.Id -Force
        }
        Write-UiMessage -UiKey "ProcessesStopped"
    }
}

function Get-Release {
    param ([Parameter(Mandatory)] [string[]]$Repositories)

    $RequestHeaders = @{}
    if (-not [string]::IsNullOrEmpty($Settings.Api.Token)) {
        $RequestHeaders["Authorization"] = "Bearer $($Settings.Api.Token)"
    }
    return @(foreach ($Repository in $Repositories) {
        try {
            $ApiEndpointUri = $Settings.Api.Endpoint -f $Repository
            $ApiResponse = Invoke-RestMethod -Uri $ApiEndpointUri -TimeoutSec 15 -Headers $RequestHeaders
            $PublishedAt = ([DateTime]::Parse($ApiResponse.published_at, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal)).ToLocalTime()
            [Release]::new($Repository, $PublishedAt, $ApiResponse.assets)
        } catch {
            $StatusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($StatusCode -eq 401) {
                throw [UpdateFailure]::new("ApiTokenError")
            } elseif ($StatusCode -eq 403 -or $StatusCode -eq 429) {
                throw [UpdateFailure]::new("ApiRateLimitError")
            } else {
                Write-UiMessage -UiKey "ApiRequestError" -FormatArgs @($Repository, $_.Exception.Message)
            }
        }
    })
}

function Get-AssetType {
    param ([Parameter(Mandatory)] [string]$AssetName)

    foreach ($Type in [Enum]::GetValues([AssetType])) {
        foreach ($Extension in $UpdateRules.AssetTypes."$Type") {
            if ($AssetName -like "*$Extension") { return $Type }
        }
    }
}

function Select-LatestAsset {
    param (
        [Parameter(Mandatory)] [App[]]$Apps,
        [Parameter(Mandatory)] [Release[]]$Releases
    )

    return @(foreach ($App in $Apps) {
        $MatchedAssets = @(foreach ($Target in $App.UpdateTargets) {
            if ([string]::IsNullOrEmpty($Target.AssetFilter)) {
                Write-UiMessage -UiKey "EmptyAssetFilter" -FormatArgs @($Target.Repository, $App.Name)
                continue
            }
            $Release = $Releases | Where-Object { $_.Repository -eq $Target.Repository }
            $TargetAssets = @(foreach ($ReleaseAsset in $Release.Assets) {
                if ($ReleaseAsset.Name -notlike $Target.FilterPattern) { continue }
                $Type = Get-AssetType -AssetName $ReleaseAsset.Name
                if ($null -eq $Type) { continue }
                [SelectedAsset]::new($App, $Target, $Release.PublishedAt, $ReleaseAsset, $Type, $DownloadDirectory)
            })
            if ($TargetAssets.Count -eq 0) {
                Write-UiMessage -UiKey "AssetNotFound" -FormatArgs @($Target.Repository, $Target.AssetFilter)
            }
            $TargetAssets
        })
        if ($MatchedAssets.Count -eq 0) { continue }
        $PreferredAssets = @($MatchedAssets | Where-Object { $_.Target.Preferred })
        $EligibleAssets = if ($PreferredAssets.Count -gt 0) { $PreferredAssets } else { $MatchedAssets }
        $EligibleAssets | Sort-Object -Property PublishedAt -Descending | Select-Object -First 1
    })
}

function Select-ApplicableAsset {
    param ([Parameter(Mandatory)] [SelectedAsset[]]$Candidates)

    return @(foreach ($Candidate in $Candidates) {
        $InstalledExecutable = Get-Item -Path $Candidate.App.ExecutablePath -ErrorAction SilentlyContinue
        $ThresholdTime = if ($InstalledExecutable -is [System.IO.FileInfo]) {
            $InstalledExecutable.LastWriteTime.AddMinutes($UpdateRules.LocalTimestampOffsetMinutes)
        } else {
            [DateTime]::MinValue
        }
        $ShouldApply = $UpdateRules.ForceUpdate -or $Candidate.Target.Force -or
                       $Candidate.PublishedAt -gt $ThresholdTime
        if ($ShouldApply) {
            Write-UiMessage -UiKey "SelectedAsset" -FormatArgs @($Candidate.App.Name, $Candidate.Target.Repository) -NoNewline
        } else {
            Write-UiMessage -UiKey "NoNewRelease" -FormatArgs @($Candidate.Target.Repository, $Candidate.PublishedAt) -NoNewline
        }
        if ($Candidate.Target.Preferred) { Write-UiMessage -UiKey "PreferredTag" -NoNewline }
        if ($Candidate.Target.Force) { Write-UiMessage -UiKey "ForceTag" -NoNewline }
        Write-UiMessage -UiKey "EndLine"
        if ($ShouldApply) {
            Write-UiMessage -UiKey "SelectedAssetItem" -FormatArgs @($Candidate.ReleaseAsset.Name, $Candidate.PublishedAt)
            $Candidate
        }
    })
}

function Invoke-AssetDownload {
    param ([Parameter(Mandatory)] [SelectedAsset[]]$ApplicableAssets)

    if (Test-Path -Path $DownloadDirectory -PathType Container) {
        Remove-Item -Path $DownloadDirectory -Recurse -Force
    }
    return @(foreach ($ApplicableAsset in $ApplicableAssets) {
        New-Item -ItemType Directory -Path $ApplicableAsset.AssetDirectory -Force | Out-Null
        $IsSuccess = $true
        try {
            Invoke-WebRequest -Uri $ApplicableAsset.ReleaseAsset.DownloadUrl -OutFile $ApplicableAsset.FilePath -ErrorAction Stop
        } catch {
            $IsSuccess = $false
            Write-UiMessage -UiKey "DownloadFail" -FormatArgs @($ApplicableAsset.ReleaseAsset.Name)
        }
        Write-UiMessage -UiKey "DownloadItem" -FormatArgs @($ApplicableAsset.App.Name, $ApplicableAsset.ReleaseAsset.Name) -NoNewline
        if ($IsSuccess) {
            Write-UiMessage -UiKey "StatusOk"
            $ApplicableAsset
        } else {
            Write-UiMessage -UiKey "StatusFail"
        }
    })
}

function Select-VerifiedAsset {
    param ([SelectedAsset[]]$DownloadedAssets)

    return @(foreach ($DownloadedAsset in $DownloadedAssets) {
        Write-UiMessage -UiKey "VerifyAsset" -FormatArgs @($DownloadedAsset.ReleaseAsset.Name)
        $CalculatedDigest = "sha256:$((Get-FileHash -Path $DownloadedAsset.FilePath -Algorithm SHA256).Hash.ToLower())"
        Write-UiMessage -UiKey "VerifyAssetDigest" -FormatArgs @($CalculatedDigest) -NoNewline
        $IsDigestMatched = if ([string]::IsNullOrEmpty($DownloadedAsset.ReleaseAsset.Digest)) {
            Write-UiMessage -UiKey "DigestNotProvided"
            $true
        } elseif ($CalculatedDigest -eq $DownloadedAsset.ReleaseAsset.Digest) {
            Write-UiMessage -UiKey "DigestMatch"
            $true
        } else {
            Write-UiMessage -UiKey "DigestMismatch"
            $false
        }
        if ($IsDigestMatched) { $DownloadedAsset }
    })
}

function Expand-AssetArchive {
    param ([Parameter(Mandatory)] [SelectedAsset[]]$VerifiedAssets)

    return @(foreach ($VerifiedAsset in $VerifiedAssets) {
        if ($VerifiedAsset.Type -ne [AssetType]::Archive) {
            $VerifiedAsset
            continue
        }
        Write-UiMessage -UiKey "ExtractItem" -FormatArgs @($VerifiedAsset.ReleaseAsset.Name)
        & $TarExecutablePath -x -f $VerifiedAsset.FilePath -C $VerifiedAsset.AssetDirectory | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $VerifiedAsset
        } else {
            Write-UiMessage -UiKey "ExtractFail" -FormatArgs @($VerifiedAsset.ReleaseAsset.Name)
        }
    })
}

function Remove-InstalledContent {
    param ([Parameter(Mandatory)] [string]$Directory)

    $FailureCount = 0
    try {
        $InstalledItems = @(Get-ChildItem -Path $Directory -Force -ErrorAction Stop)
    } catch {
        Write-UiMessage -UiKey "RemoveFail" -FormatArgs @((Split-Path -Path $Directory -Leaf), $_.Exception.Message)
        return 1
    }
    foreach ($InstalledItem in $InstalledItems) {
        $RelativePath = $InstalledItem.FullName.Substring($BaseDirectory.Length + 1)
        if ($InstalledItem.FullName -eq $UpdateDirectory -or (Test-ExcludedName -Name $InstalledItem.Name)) {
            Write-UiMessage -UiKey "SkipExcluded" -FormatArgs @($RelativePath)
            continue
        }
        if (Test-PathUnderDirectory -Path $UpdateDirectory -Directory $InstalledItem.FullName) {
            $FailureCount += Remove-InstalledContent -Directory $InstalledItem.FullName
            continue
        }
        try {
            Remove-Item -Path $InstalledItem.FullName -Recurse -Force -ErrorAction Stop
        } catch {
            Write-UiMessage -UiKey "RemoveFail" -FormatArgs @($RelativePath, $_.Exception.Message)
            $FailureCount++
        }
    }
    return $FailureCount
}

function Install-Executable {
    param ([Parameter(Mandatory)] [SelectedAsset]$Asset)

    $DestinationPath = Join-Path -Path $BaseDirectory -ChildPath $Asset.ReleaseAsset.Name
    Move-Item -Path $Asset.FilePath -Destination $DestinationPath -Force -ErrorAction Stop
    Write-UiMessage -UiKey "Moved" -FormatArgs @($Asset.ReleaseAsset.Name)
    (Get-Item -Path $DestinationPath -ErrorAction Stop).LastWriteTime = $Asset.PublishedAt
    Write-UiMessage -UiKey "TimestampSet" -FormatArgs @($Asset.PublishedAt)
}

function Install-ExtractedContent {
    param ([Parameter(Mandatory)] [SelectedAsset]$Asset)

    $Filters = $Asset.App.InstallFilters
    $AssetName = $Asset.ReleaseAsset.Name
    $InstallSourceDirectory = $Asset.AssetDirectory
    $AssetDirectoryItems = @(Get-ChildItem -Path $Asset.AssetDirectory)
    $ChildDirectories = @($AssetDirectoryItems | Where-Object { $_.PSIsContainer })
    $ChildFiles = @($AssetDirectoryItems | Where-Object { -not $_.PSIsContainer -and $_.Name -ne $AssetName })
    if ($ChildDirectories.Count -eq 1 -and $ChildFiles.Count -eq 0) {
        $InstallSourceDirectory = $ChildDirectories.FullName
    }
    $HasFilters = $Filters.Count -gt 0
    $InstallItems = if ($HasFilters) {
        foreach ($Filter in $Filters) {
            Get-ChildItem -Path $InstallSourceDirectory -Filter $Filter
        }
    } else {
        Get-ChildItem -Path $InstallSourceDirectory
    }
    foreach ($InstallItem in $InstallItems) {
        if ($InstallItem.Name -eq $AssetName) { continue }
        if (Test-ExcludedName -Name $InstallItem.Name) {
            Write-UiMessage -UiKey "SkipExcluded" -FormatArgs @($InstallItem.Name)
            continue
        }
        $DestinationItemPath = Join-Path -Path $BaseDirectory -ChildPath $InstallItem.Name
        if (Test-Path -Path $DestinationItemPath) {
            Remove-Item -Path $DestinationItemPath -Recurse -Force -ErrorAction Stop
        }
        Move-Item -Path $InstallItem.FullName -Destination $DestinationItemPath -Force -ErrorAction Stop
        if ($HasFilters) {
            Write-UiMessage -UiKey "MovedFiltered" -FormatArgs @($InstallItem.Name)
        } else {
            Write-UiMessage -UiKey "MovedFullStructure" -FormatArgs @($InstallItem.Name)
        }
    }
}

function Test-FullUpdate {
    param (
        [Parameter(Mandatory)] [App[]]$Apps,
        [Parameter(Mandatory)] [int]$InstallableAssetCount
    )

    foreach ($App in $Apps) {
        if (Test-Path -Path $App.ExecutablePath -PathType Leaf) {
            return ($InstallableAssetCount -eq $Apps.Count)
        }
    }
    return $true
}

function Install-Asset {
    param (
        [Parameter(Mandatory)] [SelectedAsset[]]$InstallableAssets,
        [Parameter(Mandatory)] [bool]$IsFullUpdate
    )

    $FailureCount = 0
    if ($IsFullUpdate) {
        Write-UiMessage -UiKey "FullUpdate"
        Write-UiMessage -UiKey "RemovePreviousHeader" -FormatArgs @($BaseDirectory)
        $FailureCount += Remove-InstalledContent -Directory $BaseDirectory
    } else {
        Write-UiMessage -UiKey "PartialUpdate"
    }
    Write-UiMessage -UiKey "InstallHeader"
    foreach ($InstallableAsset in $InstallableAssets) {
        Write-UiMessage -UiKey "InstallItem" -FormatArgs @($InstallableAsset.Type, $InstallableAsset.ReleaseAsset.Name)
        try {
            if ($InstallableAsset.Type -eq [AssetType]::Executable) {
                Install-Executable -Asset $InstallableAsset
            } else {
                Install-ExtractedContent -Asset $InstallableAsset
            }
        } catch {
            Write-UiMessage -UiKey "InstallItemFail" -FormatArgs @($_.Exception.Message)
            $FailureCount++
        }
    }
    return $FailureCount
}

function Remove-DownloadDirectory {
    Write-UiMessage -UiKey "StepCleanDownload"
    if (Test-Path -Path $DownloadDirectory -PathType Container) {
        Remove-Item -Path $DownloadDirectory -Recurse -Force
        Write-UiMessage -UiKey "RemovedDownloadDirectory" -FormatArgs @(Split-Path -Path $DownloadDirectory -Leaf)
    }
}

function Clear-AppCache {
    param ([Parameter(Mandatory)] [bool]$IsFullUpdate)

    if (-not $Settings.AppCache.Clear) { Write-UiMessage -UiKey "CacheClearOff"; return }
    if (-not $IsFullUpdate) {
        if (-not $Settings.AppCache.ClearOnPartialUpdate) { Write-UiMessage -UiKey "CacheClearSkipped"; return }
        Write-UiMessage -UiKey "CacheClearForced"
    }
    foreach ($AppCacheDirectory in $AppCacheDirectories) {
        if (Test-Path -Path $AppCacheDirectory -PathType Container) {
            Get-ChildItem -Path $AppCacheDirectory -Force | Remove-Item -Recurse -Force
            Write-UiMessage -UiKey "CacheCleared" -FormatArgs @(Split-Path -Path $AppCacheDirectory -Leaf)
        }
    }
}

function Invoke-Update {
    # Validate configuration and paths
    $Apps = Get-ConfiguredApp
    if (-not (Test-Path -Path $BaseDirectory -PathType Container)) {
        throw [UpdateFailure]::new("NoBaseDirectory", @($BaseDirectory))
    }
    if (-not (Test-Path -Path $UpdateDirectory -PathType Container)) {
        throw [UpdateFailure]::new("NoUpdateDirectory", @($UpdateDirectory))
    }
    Stop-RunningProcess -Apps $Apps
    $Repositories = @($Apps.UpdateTargets.Repository | Select-Object -Unique)
    if ($Repositories.Count -eq 0) { throw [UpdateFailure]::new("NoUpdateTargets") }

    # Fetch Release Metadata
    Write-UiMessage -UiKey "StepFetchMetadata"
    $Releases = Get-Release -Repositories $Repositories
    if ($Releases.Count -eq 0) { throw [UpdateFailure]::new("NoMetadata") }
    Write-UiMessage -UiKey "FetchedRepositories"
    foreach ($Release in $Releases) {
        Write-UiMessage -UiKey "FetchedRepositoryItem" -FormatArgs @($Release.Repository, $Release.PublishedAt)
    }

    # Select Update Targets
    Write-UiMessage -UiKey "StepSelectAssets"
    $Candidates = Select-LatestAsset -Apps $Apps -Releases $Releases
    if ($Candidates.Count -eq 0) { throw [UpdateFailure]::new("NoMatchedAssets") }
    $ApplicableAssets = Select-ApplicableAsset -Candidates $Candidates
    if ($ApplicableAssets.Count -eq 0) { Write-UiMessage -UiKey "NoUpdateRequired"; return }

    # Download, Verify & Install
    Write-UiMessage -UiKey "StepDownload"
    try {
        $DownloadedAssets = Invoke-AssetDownload -ApplicableAssets $ApplicableAssets
        Write-UiMessage -UiKey "StepVerify"
        $VerifiedAssets = Select-VerifiedAsset -DownloadedAssets $DownloadedAssets
        if ($VerifiedAssets.Count -eq 0) { throw [UpdateFailure]::new("NoVerifiedAssets") }
        Write-UiMessage -UiKey "StepExtract"
        $InstallableAssets = Expand-AssetArchive -VerifiedAssets $VerifiedAssets
        if ($InstallableAssets.Count -eq 0) { throw [UpdateFailure]::new("NoExtractedAssets") }
        Write-UiMessage -UiKey "StepInstall"
        $IsFullUpdate = Test-FullUpdate -Apps $Apps -InstallableAssetCount $InstallableAssets.Count
        $InstallFailureCount = Install-Asset -InstallableAssets $InstallableAssets -IsFullUpdate $IsFullUpdate
    } finally {
        Remove-DownloadDirectory
    }
    if ($InstallFailureCount -gt 0) { throw [UpdateFailure]::new("InstallFail", @($InstallFailureCount)) }

    # Cleanup
    Write-UiMessage -UiKey "StepCleanCache"
    Clear-AppCache -IsFullUpdate $IsFullUpdate
    if ($Settings.StartMenu.Create) {
        $StartMenuScriptPath = Join-Path -Path $PSScriptRoot -ChildPath $Settings.StartMenu.Script
        if (Test-Path -Path $StartMenuScriptPath -PathType Leaf) {
            & $StartMenuScriptPath
        }
    }
    Write-UiMessage -UiKey "RunComplete"
}

# Main
try {
    Invoke-Update
} catch [UpdateFailure] {
    Write-UiMessage -UiKey $_.Exception.UiKey -FormatArgs $_.Exception.FormatArgs
    Exit-WithMessage -Fail
}
Exit-WithMessage
