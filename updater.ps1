#Requires -Version 5.1

# Data Model
enum AssetCategory {
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
    [bool]$Preferred
    [bool]$Force

    UpdateTarget([PSCustomObject]$Definition) {
        $this.Repository = $Definition.Repository
        $this.AssetFilter = $Definition.AssetFilter
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

class UpdateAsset {
    [App]$App
    [UpdateTarget]$Target
    [Release]$Release
    [ReleaseAsset]$ReleaseAsset
    [AssetCategory]$Category
    [string]$AssetDirectory
    [string]$FilePath

    UpdateAsset([App]$App, [UpdateTarget]$Target, [Release]$Release, [ReleaseAsset]$ReleaseAsset, [AssetCategory]$Category, [string]$DownloadDirectory) {
        $this.App = $App
        $this.Target = $Target
        $this.Release = $Release
        $this.ReleaseAsset = $ReleaseAsset
        $this.Category = $Category
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
    if ($null -eq $UiTemplate) { return }
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

function Assert-RequiredDirectory {
    param (
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$UiKey
    )

    if (-not (Test-Path -Path $Path -PathType Container)) {
        throw [UpdateFailure]::new($UiKey, @($Path))
    }
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
            [PSCustomObject]@{ AppName = $App.Name; Process = $Process }
        }
    })
    if ($RunningProcesses.Count -gt 0) {
        [System.Media.SystemSounds]::Beep.Play()
        Write-UiMessage -UiKey "AppRunning"
        foreach ($RunningProcess in $RunningProcesses) {
            Write-UiMessage -UiKey "AppRunningItem" -FormatArgs @($RunningProcess.AppName)
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
    param ([Parameter(Mandatory)] [App[]]$Apps)

    $RequestHeaders = @{}
    if (-not [string]::IsNullOrEmpty($UpdateRules.ApiToken)) {
        $RequestHeaders["Authorization"] = "Bearer $($UpdateRules.ApiToken)"
    }
    $Releases = [ordered]@{}
    foreach ($Repository in @($Apps.UpdateTargets.Repository | Select-Object -Unique)) {
        try {
            $ApiEndpointUri = $UpdateRules.ApiEndpoint -f $Repository
            $ApiResponse = Invoke-RestMethod -Uri $ApiEndpointUri -TimeoutSec 15 -Headers $RequestHeaders
            $PublishedAt = ([DateTime]::Parse($ApiResponse.published_at, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal)).ToLocalTime()
            $Releases[$Repository] = [Release]::new($Repository, $PublishedAt, $ApiResponse.assets)
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
    }
    return $Releases
}

function Get-AssetCategory {
    param ([Parameter(Mandatory)] [string]$AssetName)

    foreach ($Category in [Enum]::GetValues([AssetCategory])) {
        foreach ($Extension in $UpdateRules.AssetTypes."$Category") {
            if ($AssetName -like "*$Extension") { return $Category }
        }
    }
}

function Select-LatestAsset {
    param (
        [Parameter(Mandatory)] [App[]]$Apps,
        [Parameter(Mandatory)] [System.Collections.Specialized.OrderedDictionary]$Releases
    )

    return @(foreach ($App in $Apps) {
        $MatchedAssets = @(foreach ($Target in $App.UpdateTargets) {
            if ([string]::IsNullOrEmpty($Target.AssetFilter)) {
                Write-UiMessage -UiKey "EmptyAssetFilter" -FormatArgs @($Target.Repository, $App.Name)
                continue
            }
            $FilterPattern = if ($Target.AssetFilter.Contains('*')) {
                $Target.AssetFilter
            } else {
                "*$($Target.AssetFilter)*"
            }
            $Release = $Releases[$Target.Repository]
            $TargetAssets = @(if ($null -ne $Release) {
                foreach ($ReleaseAsset in $Release.Assets) {
                    if ($ReleaseAsset.Name -notlike $FilterPattern) { continue }
                    $Category = Get-AssetCategory -AssetName $ReleaseAsset.Name
                    if ($null -eq $Category) { continue }
                    [UpdateAsset]::new($App, $Target, $Release, $ReleaseAsset, $Category, $DownloadDirectory)
                }
            })
            if ($TargetAssets.Count -eq 0) {
                Write-UiMessage -UiKey "AssetNotFound" -FormatArgs @($Target.Repository, $Target.AssetFilter)
            }
            $TargetAssets
        })
        if ($MatchedAssets.Count -eq 0) { continue }
        $PreferredAssets = @($MatchedAssets | Where-Object { $_.Target.Preferred })
        $EligibleAssets = if ($PreferredAssets.Count -gt 0) { $PreferredAssets } else { $MatchedAssets }
        $EligibleAssets | Sort-Object -Property { $_.Release.PublishedAt } -Descending | Select-Object -First 1
    })
}

function Select-ApplicableAsset {
    param ([Parameter(Mandatory)] [UpdateAsset[]]$Candidates)

    $ForceAllUpdates = $UpdateRules.ForceUpdate
    return @(foreach ($Candidate in $Candidates) {
        $InstalledExecutable = Get-Item -Path $Candidate.App.ExecutablePath -ErrorAction SilentlyContinue
        $ThresholdTime = if ($InstalledExecutable -is [System.IO.FileInfo]) {
            $InstalledExecutable.LastWriteTime.AddMinutes($UpdateRules.LocalTimestampOffsetMinutes)
        } else {
            [DateTime]::MinValue
        }
        $ShouldApply = $ForceAllUpdates -or $Candidate.Target.Force -or
                       $Candidate.Release.PublishedAt -gt $ThresholdTime
        if ($ShouldApply) {
            Write-UiMessage -UiKey "SelectedAsset" -FormatArgs @($Candidate.App.Name, $Candidate.Target.Repository) -NoNewline
        } else {
            Write-UiMessage -UiKey "NoNewRelease" -FormatArgs @($Candidate.Target.Repository, $Candidate.Release.PublishedAt) -NoNewline
        }
        if ($Candidate.Target.Preferred) { Write-UiMessage -UiKey "PreferredTag" -NoNewline }
        if ($Candidate.Target.Force) { Write-UiMessage -UiKey "ForceTag" -NoNewline }
        Write-UiMessage -UiKey "EndLine"
        if ($ShouldApply) {
            Write-UiMessage -UiKey "SelectedAssetItem" -FormatArgs @($Candidate.ReleaseAsset.Name, $Candidate.Release.PublishedAt)
            $Candidate
        }
    })
}

function Invoke-AssetDownload {
    param ([Parameter(Mandatory)] [UpdateAsset[]]$ApplicableAssets)

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

function Select-VerifiedDownload {
    param ([UpdateAsset[]]$Downloads)

    return @(foreach ($Download in $Downloads) {
        Write-UiMessage -UiKey "VerifyAsset" -FormatArgs @($Download.ReleaseAsset.Name)
        $CalculatedDigest = "sha256:$((Get-FileHash -Path $Download.FilePath -Algorithm SHA256).Hash.ToLower())"
        Write-UiMessage -UiKey "VerifyAssetDigest" -FormatArgs @($CalculatedDigest) -NoNewline
        $IsDigestMatched = if ([string]::IsNullOrEmpty($Download.ReleaseAsset.Digest)) {
            Write-UiMessage -UiKey "DigestNotProvided"
            $true
        } elseif ($CalculatedDigest -eq $Download.ReleaseAsset.Digest) {
            Write-UiMessage -UiKey "DigestMatch"
            $true
        } else {
            Write-UiMessage -UiKey "DigestMismatch"
            $false
        }
        if ($IsDigestMatched) { $Download }
    })
}

function Select-InstallableAsset {
    param ([Parameter(Mandatory)] [UpdateAsset[]]$VerifiedDownloads)

    return @(foreach ($VerifiedDownload in $VerifiedDownloads) {
        if ($VerifiedDownload.Category -ne [AssetCategory]::Archive) {
            $VerifiedDownload
            continue
        }
        Write-UiMessage -UiKey "ExtractItem" -FormatArgs @($VerifiedDownload.ReleaseAsset.Name)
        & $TarExecutablePath -x -f $VerifiedDownload.FilePath -C $VerifiedDownload.AssetDirectory | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $VerifiedDownload
        } else {
            Write-UiMessage -UiKey "ExtractFail" -FormatArgs @($VerifiedDownload.ReleaseAsset.Name)
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
    param ([Parameter(Mandatory)] [UpdateAsset]$Asset)

    $DestinationPath = Join-Path -Path $BaseDirectory -ChildPath $Asset.ReleaseAsset.Name
    Move-Item -Path $Asset.FilePath -Destination $DestinationPath -Force -ErrorAction Stop
    Write-UiMessage -UiKey "Moved" -FormatArgs @($Asset.ReleaseAsset.Name)
    (Get-Item -Path $DestinationPath -ErrorAction Stop).LastWriteTime = $Asset.Release.PublishedAt
    Write-UiMessage -UiKey "TimestampSet" -FormatArgs @($Asset.Release.PublishedAt)
}

function Install-ExtractedContent {
    param ([Parameter(Mandatory)] [UpdateAsset]$Asset)

    $Filters = $Asset.App.InstallFilters
    $AssetName = $Asset.ReleaseAsset.Name
    $SearchDirectory = $Asset.AssetDirectory
    $AssetDirectoryItems = @(Get-ChildItem -Path $Asset.AssetDirectory)
    $SubDirectories = @($AssetDirectoryItems | Where-Object { $_.PSIsContainer })
    $SubFiles = @($AssetDirectoryItems | Where-Object { -not $_.PSIsContainer -and $_.Name -ne $AssetName })
    if ($SubDirectories.Count -eq 1 -and $SubFiles.Count -eq 0) {
        $SearchDirectory = $SubDirectories.FullName
    }
    $HasFilters = $null -ne $Filters -and $Filters.Count -gt 0
    $InstallItems = if ($HasFilters) {
        foreach ($Filter in $Filters) {
            Get-ChildItem -Path $SearchDirectory -Filter $Filter
        }
    } else {
        Get-ChildItem -Path $SearchDirectory
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
        [Parameter(Mandatory)] [UpdateAsset[]]$InstallableAssets
    )

    foreach ($App in $Apps) {
        if (Test-Path -Path $App.ExecutablePath -PathType Leaf) {
            return ($InstallableAssets.Count -eq $Apps.Count)
        }
    }
    return $true
}

function Install-Asset {
    param (
        [Parameter(Mandatory)] [UpdateAsset[]]$InstallableAssets,
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
        Write-UiMessage -UiKey "InstallItem" -FormatArgs @($InstallableAsset.Category, $InstallableAsset.ReleaseAsset.Name)
        try {
            if ($InstallableAsset.Category -eq [AssetCategory]::Executable) {
                Install-Executable -Asset $InstallableAsset
            } elseif ($InstallableAsset.Category -eq [AssetCategory]::Archive) {
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
    Assert-RequiredDirectory -Path $BaseDirectory -UiKey "NoBaseDirectory"
    Assert-RequiredDirectory -Path $UpdateDirectory -UiKey "NoUpdateDirectory"
    Stop-RunningProcess -Apps $Apps
    if (@($Apps.UpdateTargets).Count -eq 0) { throw [UpdateFailure]::new("NoUpdateTargets") }

    # Fetch Release Metadata
    Write-UiMessage -UiKey "StepFetchMetadata"
    $Releases = Get-Release -Apps $Apps
    if ($Releases.Count -eq 0) { throw [UpdateFailure]::new("NoMetadata") }
    Write-UiMessage -UiKey "FetchedRepositories"
    foreach ($Release in $Releases.Values) {
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
        $Downloads = Invoke-AssetDownload -ApplicableAssets $ApplicableAssets
        Write-UiMessage -UiKey "StepVerify"
        $VerifiedDownloads = Select-VerifiedDownload -Downloads $Downloads
        if ($VerifiedDownloads.Count -eq 0) { throw [UpdateFailure]::new("NoVerifiedAssets") }
        Write-UiMessage -UiKey "StepExtract"
        $InstallableAssets = Select-InstallableAsset -VerifiedDownloads $VerifiedDownloads
        if ($InstallableAssets.Count -eq 0) { throw [UpdateFailure]::new("NoExtractedAssets") }
        Write-UiMessage -UiKey "StepInstall"
        $IsFullUpdate = Test-FullUpdate -Apps $Apps -InstallableAssets $InstallableAssets
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
