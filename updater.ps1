#Requires -Version 5.1

# Data Model
enum AssetType {
    Executable
    Archive
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
        $this.FilterPattern = if ($this.AssetFilter.Contains('*')) {
            $this.AssetFilter
        } else {
            "*$($this.AssetFilter)*"
        }
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

class Asset {
    [string]$Name
    [string]$DownloadUrl
    [string]$Digest

    Asset([PSCustomObject]$ApiAsset) {
        $this.Name = $ApiAsset.name
        $this.DownloadUrl = $ApiAsset.browser_download_url
        $this.Digest = $ApiAsset.digest
    }
}

class Release {
    [string]$Repository
    [DateTime]$PublishedAt
    [Asset[]]$Assets

    Release([string]$Repository, [PSCustomObject]$ApiRelease) {
        $this.Repository = $Repository
        $this.PublishedAt = [DateTime]::Parse(
            $ApiRelease.published_at,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal
        ).ToLocalTime()
        $this.Assets = @(foreach ($ApiAsset in $ApiRelease.assets) { [Asset]::new($ApiAsset) })
    }
}

class AppProcess {
    [App]$App
    [System.Diagnostics.Process]$Process

    AppProcess([App]$App, [System.Diagnostics.Process]$Process) {
        $this.App = $App
        $this.Process = $Process
    }
}

class UpdateAsset {
    [App]$App
    [UpdateTarget]$Target
    [DateTime]$PublishedAt
    [Asset]$Asset
    [AssetType]$Type
    [string]$DownloadDirectory
    [string]$FilePath

    UpdateAsset(
        [App]$App,
        [UpdateTarget]$Target,
        [DateTime]$PublishedAt,
        [Asset]$Asset,
        [AssetType]$Type,
        [string]$DownloadRootDirectory
    ) {
        $this.App = $App
        $this.Target = $Target
        $this.PublishedAt = $PublishedAt
        $this.Asset = $Asset
        $this.Type = $Type
        $this.DownloadDirectory = Join-Path -Path $DownloadRootDirectory -ChildPath $App.Name
        $this.FilePath = Join-Path -Path $this.DownloadDirectory -ChildPath $Asset.Name
    }
}

# Exception
class UpdateException : System.Exception {
    [string]$UiKey
    [object[]]$FormatArgs

    UpdateException([string]$UiKey) : base($UiKey) {
        $this.UiKey = $UiKey
    }

    UpdateException([string]$UiKey, [object[]]$FormatArgs) : base($UiKey) {
        $this.UiKey = $UiKey
        $this.FormatArgs = $FormatArgs
    }
}

# Configuration
function Import-JsonFile {
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [string]$FilePath)

    if (-not (Test-Path -Path $FilePath -PathType Leaf)) {
        throw "Not found: $FilePath"
    }
    try {
        return Get-Content -Path $FilePath -Raw | ConvertFrom-Json
    } catch {
        throw "Failed to parse: $FilePath ($($_.Exception.Message))"
    }
}

function Resolve-ConfiguredPath {
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [string]$Path)

    $ExpandedPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
    $RootPath = [System.IO.Path]::GetPathRoot($ExpandedPath)
    if ($ExpandedPath.Length -le $RootPath.Length) { return $ExpandedPath }
    $Separators = [System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar
    return $ExpandedPath.TrimEnd($Separators)
}

# Console
function Write-UiMessage {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string]$UiKey,
        [object[]]$FormatArgs,
        [switch]$NoNewline
    )

    $UiTemplate = $UiTemplates.$UiKey
    $DisplayText = $UiTemplate.Template
    if ($null -ne $FormatArgs -and $FormatArgs.Count -gt 0) {
        $DisplayText = $UiTemplate.Template -f $FormatArgs
    }
    Write-Host $DisplayText -ForegroundColor $UiTemplate.Color -NoNewline:$NoNewline
}

function Exit-Script {
    [CmdletBinding()]
    param ([switch]$Fail)

    $ExitSound = [System.Media.SystemSounds]::Asterisk
    $ExitCode = 0
    if ($Fail) {
        $ExitSound = [System.Media.SystemSounds]::Hand
        $ExitCode = 1
    }
    $ExitSound.Play()
    Write-UiMessage -UiKey "PressEnterExit"
    $null = Read-Host
    exit $ExitCode
}

# Pipeline
function Test-ExcludedName {
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [string]$Name)

    return $UpdateRules.ExcludedNames -contains $Name
}

function Test-PathUnderDirectory {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Directory
    )

    $DirectoryPrefix = $Directory + [System.IO.Path]::DirectorySeparatorChar
    return $Path.StartsWith($DirectoryPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-ConfiguredApp {
    [CmdletBinding()]
    param ()

    return @(foreach ($AppProperty in $Settings.Apps.PSObject.Properties) {
        if ([string]::IsNullOrEmpty($AppProperty.Value.Executable)) {
            throw [UpdateException]::new("NoExecutable", @($AppProperty.Name))
        }
        [App]::new($AppProperty.Name, $AppProperty.Value, $BaseDirectory)
    })
}

function Get-AppProcess {
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [AllowEmptyCollection()] [App[]]$Apps)

    return @(foreach ($App in $Apps) {
        foreach ($Process in @(Get-Process -Name $App.ProcessName -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrEmpty($Process.Path)) { continue }
            if (-not (Test-PathUnderDirectory -Path $Process.Path -Directory $BaseDirectory)) { continue }
            [AppProcess]::new($App, $Process)
        }
    })
}

function Stop-AppProcess {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [AppProcess[]]$AppProcesses)

    [System.Media.SystemSounds]::Beep.Play()
    Write-UiMessage -UiKey "AppRunning"
    foreach ($AppProcess in $AppProcesses) {
        Write-UiMessage -UiKey "AppRunningItem" -FormatArgs $AppProcess.App.Name
    }
    Write-UiMessage -UiKey "AppContinuePrompt" -NoNewline
    $UserChoice = Read-Host
    if ($UserChoice -notmatch "^[yY]$") {
        throw [UpdateException]::new("UserCanceled")
    }
    foreach ($AppProcess in $AppProcesses) {
        Stop-Process -Id $AppProcess.Process.Id -Force
    }
    Write-UiMessage -UiKey "ProcessesStopped"
}

function Get-Release {
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [string[]]$Repositories)

    $RequestHeaders = @{}
    if (-not [string]::IsNullOrEmpty($Settings.Api.Token)) {
        $RequestHeaders["Authorization"] = "Bearer $($Settings.Api.Token)"
    }
    return @(foreach ($Repository in $Repositories) {
        try {
            $ApiEndpointUri = $Settings.Api.Endpoint -f $Repository
            $ApiRelease = Invoke-RestMethod -Uri $ApiEndpointUri -TimeoutSec 15 -Headers $RequestHeaders
            [Release]::new($Repository, $ApiRelease)
        } catch {
            $StatusCode = 0
            if ($_.Exception.Response) {
                $StatusCode = [int]$_.Exception.Response.StatusCode
            }
            if ($StatusCode -eq 401) {
                throw [UpdateException]::new("ApiTokenFail")
            }
            if ($StatusCode -eq 403 -or $StatusCode -eq 429) {
                throw [UpdateException]::new("ApiRateLimitFail")
            }
            Write-UiMessage -UiKey "ApiRequestFail" -FormatArgs $Repository, $_.Exception.Message
        }
    })
}

function Get-AssetType {
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [string]$AssetName)

    foreach ($Type in [Enum]::GetValues([AssetType])) {
        foreach ($Extension in $UpdateRules.AssetTypes."$Type") {
            if ($AssetName -like "*$Extension") { return $Type }
        }
    }
    return $null
}

function Select-CandidateAsset {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [App[]]$Apps,
        [Parameter(Mandatory)] [Release[]]$Releases
    )

    return @(foreach ($App in $Apps) {
        $MatchedAssets = @(foreach ($Target in $App.UpdateTargets) {
            if ([string]::IsNullOrEmpty($Target.AssetFilter)) {
                Write-UiMessage -UiKey "EmptyAssetFilter" -FormatArgs $Target.Repository, $App.Name
                continue
            }
            $Release = $Releases | Where-Object { $_.Repository -eq $Target.Repository }
            if ($null -eq $Release) { continue }
            $TargetAssets = @(foreach ($Asset in $Release.Assets) {
                if ($Asset.Name -notlike $Target.FilterPattern) { continue }
                $Type = Get-AssetType -AssetName $Asset.Name
                if ($null -eq $Type) { continue }
                [UpdateAsset]::new($App, $Target, $Release.PublishedAt, $Asset, $Type, $DownloadDirectory)
            })
            if ($TargetAssets.Count -eq 0) {
                Write-UiMessage -UiKey "NoTargetAsset" -FormatArgs $Target.Repository, $Target.AssetFilter
            }
            $TargetAssets
        })
        if ($MatchedAssets.Count -eq 0) { continue }
        $EligibleAssets = $MatchedAssets
        $PreferredAssets = @($MatchedAssets | Where-Object { $_.Target.Preferred })
        if ($PreferredAssets.Count -gt 0) {
            $EligibleAssets = $PreferredAssets
        }
        $EligibleAssets | Sort-Object -Property PublishedAt -Descending | Select-Object -First 1
    })
}

function Select-ApplicableAsset {
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [UpdateAsset[]]$UpdateAssets)

    return @(foreach ($UpdateAsset in $UpdateAssets) {
        $App = $UpdateAsset.App
        $Target = $UpdateAsset.Target
        $PublishedAt = $UpdateAsset.PublishedAt
        $ThresholdTime = [DateTime]::MinValue
        $InstalledExecutable = Get-Item -Path $App.ExecutablePath -ErrorAction SilentlyContinue
        if ($InstalledExecutable -is [System.IO.FileInfo]) {
            $OffsetMinutes = $UpdateRules.LocalTimestampOffsetMinutes
            $ThresholdTime = $InstalledExecutable.LastWriteTime.AddMinutes($OffsetMinutes)
        }
        $IsApplicable = $UpdateRules.ForceUpdate -or $Target.Force -or $PublishedAt -gt $ThresholdTime
        if ($IsApplicable) {
            Write-UiMessage -UiKey "SelectedAsset" -FormatArgs $App.Name, $Target.Repository -NoNewline
        } else {
            Write-UiMessage -UiKey "NoNewRelease" -FormatArgs $Target.Repository, $PublishedAt -NoNewline
        }
        if ($Target.Preferred) { Write-UiMessage -UiKey "PreferredTag" -NoNewline }
        if ($Target.Force) { Write-UiMessage -UiKey "ForceTag" -NoNewline }
        Write-UiMessage -UiKey "EndLine"
        if (-not $IsApplicable) { continue }
        Write-UiMessage -UiKey "SelectedAssetItem" -FormatArgs $UpdateAsset.Asset.Name, $PublishedAt
        $UpdateAsset
    })
}

function Save-Asset {
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [UpdateAsset[]]$UpdateAssets)

    if (Test-Path -Path $DownloadDirectory -PathType Container) {
        Remove-Item -Path $DownloadDirectory -Recurse -Force
    }
    return @(foreach ($UpdateAsset in $UpdateAssets) {
        $null = New-Item -ItemType Directory -Path $UpdateAsset.DownloadDirectory -Force
        Write-UiMessage -UiKey "DownloadItem" -FormatArgs $UpdateAsset.App.Name, $UpdateAsset.Asset.Name -NoNewline
        try {
            Invoke-WebRequest -Uri $UpdateAsset.Asset.DownloadUrl -OutFile $UpdateAsset.FilePath -ErrorAction Stop
        } catch {
            Write-UiMessage -UiKey "StatusFail"
            Write-UiMessage -UiKey "DownloadFail" -FormatArgs $_.Exception.Message
            continue
        }
        Write-UiMessage -UiKey "StatusOk"
        $UpdateAsset
    })
}

function Select-VerifiedAsset {
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [AllowEmptyCollection()] [UpdateAsset[]]$UpdateAssets)

    return @(foreach ($UpdateAsset in $UpdateAssets) {
        Write-UiMessage -UiKey "VerifyItem" -FormatArgs $UpdateAsset.Asset.Name
        $FileHash = Get-FileHash -Path $UpdateAsset.FilePath -Algorithm SHA256
        $CalculatedDigest = "sha256:$($FileHash.Hash.ToLower())"
        Write-UiMessage -UiKey "VerifyItemDigest" -FormatArgs $CalculatedDigest -NoNewline
        if ([string]::IsNullOrEmpty($UpdateAsset.Asset.Digest)) {
            Write-UiMessage -UiKey "DigestNotProvided"
        } elseif ($CalculatedDigest -eq $UpdateAsset.Asset.Digest) {
            Write-UiMessage -UiKey "DigestMatch"
        } else {
            Write-UiMessage -UiKey "DigestMismatch"
            continue
        }
        $UpdateAsset
    })
}

function Expand-AssetArchive {
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [UpdateAsset[]]$UpdateAssets)

    return @(foreach ($UpdateAsset in $UpdateAssets) {
        if ($UpdateAsset.Type -eq [AssetType]::Archive) {
            Write-UiMessage -UiKey "ExtractItem" -FormatArgs $UpdateAsset.Asset.Name
            $null = & $TarExecutablePath -x -f $UpdateAsset.FilePath -C $UpdateAsset.DownloadDirectory
            if ($LASTEXITCODE -ne 0) {
                Write-UiMessage -UiKey "ExtractFail" -FormatArgs $UpdateAsset.Asset.Name
                continue
            }
        }
        $UpdateAsset
    })
}

function Remove-InstalledContent {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [string]$Directory)

    try {
        $InstalledItems = @(Get-ChildItem -Path $Directory -Force -ErrorAction Stop)
    } catch {
        Write-UiMessage -UiKey "RemoveFail" -FormatArgs (Split-Path -Path $Directory -Leaf), $_.Exception.Message
        return 1
    }
    $FailureCount = 0
    foreach ($InstalledItem in $InstalledItems) {
        $ItemPath = $InstalledItem.FullName
        $RelativePath = $ItemPath.Substring($BaseDirectory.Length + 1)
        if ($ItemPath -eq $UpdateDirectory -or (Test-ExcludedName -Name $InstalledItem.Name)) {
            Write-UiMessage -UiKey "SkipExcluded" -FormatArgs $RelativePath
            continue
        }
        if (Test-PathUnderDirectory -Path $UpdateDirectory -Directory $ItemPath) {
            $FailureCount += Remove-InstalledContent -Directory $ItemPath
            continue
        }
        try {
            Remove-Item -Path $ItemPath -Recurse -Force -ErrorAction Stop
        } catch {
            Write-UiMessage -UiKey "RemoveFail" -FormatArgs $RelativePath, $_.Exception.Message
            $FailureCount++
        }
    }
    return $FailureCount
}

function Install-Executable {
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [UpdateAsset]$UpdateAsset)

    $DestinationPath = Join-Path -Path $BaseDirectory -ChildPath $UpdateAsset.Asset.Name
    Move-Item -Path $UpdateAsset.FilePath -Destination $DestinationPath -Force -ErrorAction Stop
    Write-UiMessage -UiKey "Moved" -FormatArgs $UpdateAsset.Asset.Name
    (Get-Item -Path $DestinationPath -ErrorAction Stop).LastWriteTime = $UpdateAsset.PublishedAt
    Write-UiMessage -UiKey "TimestampSet" -FormatArgs $UpdateAsset.PublishedAt
}

function Install-ExtractedContent {
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [UpdateAsset]$UpdateAsset)

    $AssetName = $UpdateAsset.Asset.Name
    $InstallFilters = $UpdateAsset.App.InstallFilters
    $HasInstallFilters = $InstallFilters.Count -gt 0

    $InstallSourceDirectory = $UpdateAsset.DownloadDirectory
    $ExtractedItems = @(Get-ChildItem -Path $InstallSourceDirectory | Where-Object { $_.Name -ne $AssetName })
    if ($ExtractedItems.Count -eq 1 -and $ExtractedItems[0].PSIsContainer) {
        $InstallSourceDirectory = $ExtractedItems[0].FullName
    }

    $InstallItems = @(if ($HasInstallFilters) {
        foreach ($InstallFilter in $InstallFilters) {
            Get-ChildItem -Path $InstallSourceDirectory -Filter $InstallFilter
        }
    } else {
        Get-ChildItem -Path $InstallSourceDirectory
    })
    $MovedUiKey = "MovedFullStructure"
    if ($HasInstallFilters) {
        $MovedUiKey = "MovedFiltered"
    }
    foreach ($InstallItem in $InstallItems) {
        if ($InstallItem.Name -eq $AssetName) { continue }
        if (Test-ExcludedName -Name $InstallItem.Name) {
            Write-UiMessage -UiKey "SkipExcluded" -FormatArgs $InstallItem.Name
            continue
        }
        $DestinationPath = Join-Path -Path $BaseDirectory -ChildPath $InstallItem.Name
        if (Test-Path -Path $DestinationPath) {
            Remove-Item -Path $DestinationPath -Recurse -Force -ErrorAction Stop
        }
        Move-Item -Path $InstallItem.FullName -Destination $DestinationPath -Force -ErrorAction Stop
        Write-UiMessage -UiKey $MovedUiKey -FormatArgs $InstallItem.Name
    }
}

function Test-FullUpdate {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [App[]]$Apps,
        [Parameter(Mandatory)] [int]$InstallableAssetCount
    )

    $InstalledApps = @($Apps | Where-Object { Test-Path -Path $_.ExecutablePath -PathType Leaf })
    if ($InstalledApps.Count -eq 0) { return $true }
    return $InstallableAssetCount -eq $Apps.Count
}

function Install-Asset {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [UpdateAsset[]]$UpdateAssets,
        [switch]$FullUpdate
    )

    $FailureCount = 0
    if ($FullUpdate) {
        Write-UiMessage -UiKey "FullUpdate"
        Write-UiMessage -UiKey "RemovePreviousInstall" -FormatArgs $BaseDirectory
        $FailureCount += Remove-InstalledContent -Directory $BaseDirectory
    } else {
        Write-UiMessage -UiKey "PartialUpdate"
    }
    Write-UiMessage -UiKey "InstallAssets"
    foreach ($UpdateAsset in $UpdateAssets) {
        Write-UiMessage -UiKey "InstallItem" -FormatArgs $UpdateAsset.Type, $UpdateAsset.Asset.Name
        try {
            if ($UpdateAsset.Type -eq [AssetType]::Executable) {
                Install-Executable -UpdateAsset $UpdateAsset
            } else {
                Install-ExtractedContent -UpdateAsset $UpdateAsset
            }
        } catch {
            Write-UiMessage -UiKey "InstallItemFail" -FormatArgs $_.Exception.Message
            $FailureCount++
        }
    }
    return $FailureCount
}

function Remove-DownloadDirectory {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param ()

    Write-UiMessage -UiKey "StepRemoveDownload"
    if (-not (Test-Path -Path $DownloadDirectory -PathType Container)) { return }
    Remove-Item -Path $DownloadDirectory -Recurse -Force
    Write-UiMessage -UiKey "RemovedDownloadDirectory" -FormatArgs (Split-Path -Path $DownloadDirectory -Leaf)
}

function Clear-AppCache {
    [CmdletBinding()]
    param ([switch]$FullUpdate)

    if (-not $Settings.AppCache.Clear) {
        Write-UiMessage -UiKey "CacheClearOff"
        return
    }
    if (-not $FullUpdate) {
        if (-not $Settings.AppCache.ClearOnPartialUpdate) {
            Write-UiMessage -UiKey "CacheClearSkipped"
            return
        }
        Write-UiMessage -UiKey "CacheClearOnPartialUpdate"
    }
    foreach ($AppCacheDirectory in $AppCacheDirectories) {
        if (-not (Test-Path -Path $AppCacheDirectory -PathType Container)) { continue }
        Get-ChildItem -Path $AppCacheDirectory -Force | Remove-Item -Recurse -Force
        Write-UiMessage -UiKey "CacheCleared" -FormatArgs (Split-Path -Path $AppCacheDirectory -Leaf)
    }
}

function Invoke-Update {
    [CmdletBinding()]
    param ()

    $Apps = Get-ConfiguredApp
    if (-not (Test-Path -Path $BaseDirectory -PathType Container)) {
        throw [UpdateException]::new("NoBaseDirectory", @($BaseDirectory))
    }
    if (-not (Test-Path -Path $UpdateDirectory -PathType Container)) {
        throw [UpdateException]::new("NoUpdateDirectory", @($UpdateDirectory))
    }
    $AppProcesses = Get-AppProcess -Apps $Apps
    if ($AppProcesses.Count -gt 0) {
        Stop-AppProcess -AppProcesses $AppProcesses
    }
    $Repositories = @($Apps.UpdateTargets.Repository | Select-Object -Unique)
    if ($Repositories.Count -eq 0) { throw [UpdateException]::new("NoUpdateTargets") }

    Write-UiMessage -UiKey "StepFetchMetadata"
    $Releases = Get-Release -Repositories $Repositories
    if ($Releases.Count -eq 0) { throw [UpdateException]::new("NoMetadata") }
    Write-UiMessage -UiKey "FetchedRepositories"
    foreach ($Release in $Releases) {
        Write-UiMessage -UiKey "FetchedRepositoryItem" -FormatArgs $Release.Repository, $Release.PublishedAt
    }

    Write-UiMessage -UiKey "StepSelectAssets"
    $Candidates = Select-CandidateAsset -Apps $Apps -Releases $Releases
    if ($Candidates.Count -eq 0) { throw [UpdateException]::new("NoMatchedAssets") }
    $ApplicableAssets = Select-ApplicableAsset -UpdateAssets $Candidates
    if ($ApplicableAssets.Count -eq 0) {
        Write-UiMessage -UiKey "NoUpdateRequired"
        return
    }

    Write-UiMessage -UiKey "StepDownload"
    try {
        $DownloadedAssets = Save-Asset -UpdateAssets $ApplicableAssets
        Write-UiMessage -UiKey "StepVerify"
        $VerifiedAssets = Select-VerifiedAsset -UpdateAssets $DownloadedAssets
        if ($VerifiedAssets.Count -eq 0) { throw [UpdateException]::new("NoVerifiedAssets") }
        Write-UiMessage -UiKey "StepExtract"
        $InstallableAssets = Expand-AssetArchive -UpdateAssets $VerifiedAssets
        if ($InstallableAssets.Count -eq 0) { throw [UpdateException]::new("NoExtractedAssets") }
        Write-UiMessage -UiKey "StepInstall"
        $IsFullUpdate = Test-FullUpdate -Apps $Apps -InstallableAssetCount $InstallableAssets.Count
        $InstallFailureCount = Install-Asset -UpdateAssets $InstallableAssets -FullUpdate:$IsFullUpdate
    } finally {
        Remove-DownloadDirectory
    }
    if ($InstallFailureCount -gt 0) { throw [UpdateException]::new("InstallFail", @($InstallFailureCount)) }

    Write-UiMessage -UiKey "StepClearCache"
    Clear-AppCache -FullUpdate:$IsFullUpdate
    if ($Settings.StartMenu.Create) {
        $StartMenuScriptPath = Join-Path -Path $PSScriptRoot -ChildPath $Settings.StartMenu.Script
        if (Test-Path -Path $StartMenuScriptPath -PathType Leaf) {
            & $StartMenuScriptPath
        }
    }
    Write-UiMessage -UiKey "RunCompleted"
}

# Main
try {
    $Settings = Import-JsonFile -FilePath (Join-Path -Path $PSScriptRoot -ChildPath "settings.json")
    $UiTemplates = Import-JsonFile -FilePath (Join-Path -Path $PSScriptRoot -ChildPath "ui.json")
} catch {
    Write-Host " [X] $($_.Exception.Message)" -ForegroundColor Red
    $null = Read-Host
    exit 1
}

$UpdateRules = $Settings.UpdateRules
$BaseDirectory = Resolve-ConfiguredPath -Path $Settings.Paths.BaseDirectory
$UpdateDirectory = Resolve-ConfiguredPath -Path $Settings.Paths.UpdateDirectory
$DownloadDirectory = Join-Path -Path $UpdateDirectory -ChildPath "download"
$TarExecutablePath = Join-Path -Path $env:SystemRoot -ChildPath "System32\tar.exe"
$AppCacheDirectories = @($Settings.AppCache.Directories | ForEach-Object { Resolve-ConfiguredPath -Path $_ })
$ErrorActionPreference = $Settings.ErrorActionPreference
$ProgressPreference = $Settings.ProgressPreference

try {
    Invoke-Update
} catch [UpdateException] {
    Write-UiMessage -UiKey $_.Exception.UiKey -FormatArgs $_.Exception.FormatArgs
    Exit-Script -Fail
}
Exit-Script
