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
        $this.AssetFilter = $Definition.AssetFilter
        $this.FilterPattern = if ([WildcardPattern]::ContainsWildcardCharacters($this.AssetFilter)) {
            $this.AssetFilter
        } else {
            "*$($this.AssetFilter)*"
        }
        $this.Preferred = $Definition.Preferred
        $this.Force = $Definition.Force
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
    [string]$AppDownloadDirectory
    [string]$FilePath
    [string]$ExtractDirectory

    UpdateAsset(
        [App]$App,
        [UpdateTarget]$Target,
        [DateTime]$PublishedAt,
        [Asset]$Asset,
        [AssetType]$Type,
        [string]$DownloadDirectory
    ) {
        $this.App = $App
        $this.Target = $Target
        $this.PublishedAt = $PublishedAt
        $this.Asset = $Asset
        $this.Type = $Type
        $this.AppDownloadDirectory = Join-Path -Path $DownloadDirectory -ChildPath $App.Name
        $this.FilePath = Join-Path -Path $this.AppDownloadDirectory -ChildPath $Asset.Name
        $this.ExtractDirectory = Join-Path -Path $this.AppDownloadDirectory -ChildPath "extracted"
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
    param ([Parameter(Mandatory)] [string]$FilePath)

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw "Not found: $FilePath"
    }
    try {
        return Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
    } catch {
        throw "Failed to parse: $FilePath ($($_.Exception.Message))"
    }
}

function Resolve-ConfiguredPath {
    param ([Parameter(Mandatory)] [string]$Path)

    $ExpandedPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
    $RootPath = [System.IO.Path]::GetPathRoot($ExpandedPath)
    if ($ExpandedPath.Length -le $RootPath.Length) { return $ExpandedPath }
    $Separators = [System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar
    return $ExpandedPath.TrimEnd($Separators)
}

# Console
function Write-UiMessage {
    param (
        [Parameter(Mandatory)] [string]$UiKey,
        [object[]]$FormatArgs,
        [switch]$NoNewline
    )

    $UiTemplate = $UiTemplates.$UiKey
    $DisplayText = $UiTemplate.Template
    if ($FormatArgs.Count -gt 0) {
        $DisplayText = $DisplayText -f $FormatArgs
    }
    Write-Host $DisplayText -ForegroundColor $UiTemplate.Color -NoNewline:$NoNewline
}

function Exit-Script {
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
        if ([string]::IsNullOrWhiteSpace($AppProperty.Value.Executable)) {
            throw [UpdateException]::new("NoExecutable", $AppProperty.Name)
        }
        [App]::new($AppProperty.Name, $AppProperty.Value, $BaseDirectory)
    })
}

function Get-AppProcess {
    param ([App[]]$Apps)

    return @(foreach ($App in $Apps) {
        foreach ($Process in Get-Process -Name $App.ProcessName -ErrorAction SilentlyContinue) {
            if ([string]::IsNullOrEmpty($Process.Path)) { continue }
            if (-not (Test-PathUnderDirectory -Path $Process.Path -Directory $BaseDirectory)) { continue }
            [AppProcess]::new($App, $Process)
        }
    })
}

function Stop-AppProcess {
    param ([Parameter(Mandatory)] [AppProcess[]]$AppProcesses)

    [System.Media.SystemSounds]::Beep.Play()
    Write-UiMessage -UiKey "AppRunning"
    foreach ($AppProcess in $AppProcesses) {
        Write-UiMessage -UiKey "AppRunningItem" -FormatArgs $AppProcess.App.Name
    }
    Write-UiMessage -UiKey "AppContinuePrompt" -NoNewline
    if ((Read-Host) -notmatch "^y$") {
        throw [UpdateException]::new("UserCanceled")
    }
    foreach ($AppProcess in $AppProcesses) {
        Stop-Process -Id $AppProcess.Process.Id -Force
    }
    Write-UiMessage -UiKey "ProcessesStopped"
}

function Get-Release {
    param ([Parameter(Mandatory)] [string[]]$Repositories)

    $RequestHeaders = @{}
    if (-not [string]::IsNullOrWhiteSpace($Settings.Api.Token)) {
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
            $Reason = $_.Exception.GetBaseException().Message
            Write-UiMessage -UiKey "ApiRequestFail" -FormatArgs $Repository, $Reason
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
    return $null
}

function Select-CandidateAsset {
    param (
        [Parameter(Mandatory)] [App[]]$Apps,
        [Parameter(Mandatory)] [Release[]]$Releases
    )

    return @(foreach ($App in $Apps) {
        $MatchedAssets = @(foreach ($Target in $App.UpdateTargets) {
            if ([string]::IsNullOrWhiteSpace($Target.AssetFilter)) {
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
        $PreferredAssets = @($MatchedAssets | Where-Object { $_.Target.Preferred })
        $EligibleAssets = if ($PreferredAssets.Count -gt 0) { $PreferredAssets } else { $MatchedAssets }
        $EligibleAssets | Sort-Object -Property PublishedAt -Descending | Select-Object -First 1
    })
}

function Select-ApplicableAsset {
    param ([Parameter(Mandatory)] [UpdateAsset[]]$UpdateAssets)

    return @(foreach ($UpdateAsset in $UpdateAssets) {
        $App = $UpdateAsset.App
        $Target = $UpdateAsset.Target
        $PublishedAt = $UpdateAsset.PublishedAt
        $ThresholdTime = [DateTime]::MinValue
        $InstalledExecutable = Get-Item -LiteralPath $App.ExecutablePath -ErrorAction SilentlyContinue
        if ($null -ne $InstalledExecutable) {
            $ThresholdTime = $InstalledExecutable.LastWriteTime.AddMinutes($UpdateRules.LocalTimestampOffsetMinutes)
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
    param ([Parameter(Mandatory)] [UpdateAsset[]]$UpdateAssets)

    $null = Remove-DownloadDirectory
    return @(foreach ($UpdateAsset in $UpdateAssets) {
        $null = New-Item -ItemType Directory -Path $UpdateAsset.AppDownloadDirectory -Force
        Write-UiMessage -UiKey "DownloadItem" -FormatArgs $UpdateAsset.App.Name, $UpdateAsset.Asset.Name -NoNewline
        $CurlErrorMessage = & $CurlExecutablePath --silent --show-error --location --proto =https --fail --stderr - --output $UpdateAsset.FilePath $UpdateAsset.Asset.DownloadUrl
        if ($LASTEXITCODE -ne 0) {
            Write-UiMessage -UiKey "StatusFail"
            Write-UiMessage -UiKey "DownloadFail" -FormatArgs "$CurlErrorMessage"
            continue
        }
        Write-UiMessage -UiKey "StatusOk"
        $UpdateAsset
    })
}

function Select-VerifiedAsset {
    param ([UpdateAsset[]]$UpdateAssets)

    return @(foreach ($UpdateAsset in $UpdateAssets) {
        Write-UiMessage -UiKey "VerifyItem" -FormatArgs $UpdateAsset.App.Name, $UpdateAsset.Asset.Name
        $FileHash = Get-FileHash -LiteralPath $UpdateAsset.FilePath -Algorithm SHA256
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
    param ([Parameter(Mandatory)] [UpdateAsset[]]$UpdateAssets)

    return @(foreach ($UpdateAsset in $UpdateAssets) {
        if ($UpdateAsset.Type -eq [AssetType]::Archive) {
            Write-UiMessage -UiKey "ExtractItem" -FormatArgs $UpdateAsset.App.Name, $UpdateAsset.Asset.Name -NoNewline
            $null = New-Item -ItemType Directory -Path $UpdateAsset.ExtractDirectory -Force
            $null = & $TarExecutablePath -x -f $UpdateAsset.FilePath -C $UpdateAsset.ExtractDirectory
            if ($LASTEXITCODE -ne 0) { continue }
            Write-UiMessage -UiKey "StatusOk"
        }
        $UpdateAsset
    })
}

function Remove-InstalledContent {
    param ([Parameter(Mandatory)] [string]$Directory)

    try {
        $InstalledItems = @(Get-ChildItem -LiteralPath $Directory -Force -ErrorAction Stop)
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
            Remove-Item -LiteralPath $ItemPath -Recurse -Force -ErrorAction Stop
        } catch {
            Write-UiMessage -UiKey "RemoveFail" -FormatArgs $RelativePath, $_.Exception.Message
            $FailureCount++
        }
    }
    return $FailureCount
}

function Install-Executable {
    param ([Parameter(Mandatory)] [UpdateAsset]$UpdateAsset)

    $DestinationPath = Join-Path -Path $BaseDirectory -ChildPath $UpdateAsset.Asset.Name
    Move-Item -LiteralPath $UpdateAsset.FilePath -Destination $DestinationPath -Force -ErrorAction Stop
    Write-UiMessage -UiKey "Moved" -FormatArgs $UpdateAsset.Asset.Name
    (Get-Item -LiteralPath $DestinationPath -ErrorAction Stop).LastWriteTime = $UpdateAsset.PublishedAt
    Write-UiMessage -UiKey "TimestampSet" -FormatArgs $UpdateAsset.PublishedAt
}

function Install-ExtractedContent {
    param ([Parameter(Mandatory)] [UpdateAsset]$UpdateAsset)

    $InstallSourceDirectory = $UpdateAsset.ExtractDirectory
    $ExtractedItems = @(Get-ChildItem -LiteralPath $InstallSourceDirectory)
    if ($ExtractedItems.Count -eq 1 -and $ExtractedItems[0].PSIsContainer) {
        $InstallSourceDirectory = $ExtractedItems[0].FullName
    }

    $InstallFilters = $UpdateAsset.App.InstallFilters
    if ($InstallFilters.Count -gt 0) {
        $MovedUiKey = "MovedFiltered"
        $InstallItems = @(foreach ($InstallFilter in $InstallFilters) {
            Get-ChildItem -LiteralPath $InstallSourceDirectory -Filter $InstallFilter
        })
    } else {
        $MovedUiKey = "MovedFullStructure"
        $InstallItems = @(Get-ChildItem -LiteralPath $InstallSourceDirectory)
    }
    foreach ($InstallItem in $InstallItems) {
        $DestinationPath = Join-Path -Path $BaseDirectory -ChildPath $InstallItem.Name
        if (Test-Path -LiteralPath $DestinationPath) {
            Remove-Item -LiteralPath $DestinationPath -Recurse -Force -ErrorAction Stop
        }
        Move-Item -LiteralPath $InstallItem.FullName -Destination $DestinationPath -Force -ErrorAction Stop
        Write-UiMessage -UiKey $MovedUiKey -FormatArgs $InstallItem.Name
    }
}

function Test-FullUpdate {
    param (
        [Parameter(Mandatory)] [App[]]$Apps,
        [Parameter(Mandatory)] [UpdateAsset[]]$InstallableAssets
    )

    $InstallableApps = $InstallableAssets.App
    if (@($Apps | Where-Object { $_ -notin $InstallableApps }).Count -eq 0) { return $true }
    foreach ($App in $Apps) {
        if (Test-Path -LiteralPath $App.ExecutablePath) { return $false }
    }
    return $true
}

function Install-Asset {
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
        try {
            if ($UpdateAsset.Type -eq [AssetType]::Executable) {
                Write-UiMessage -UiKey "InstallExecutableItem" -FormatArgs $UpdateAsset.Asset.Name
                Install-Executable -UpdateAsset $UpdateAsset
            } else {
                Write-UiMessage -UiKey "InstallArchiveItem" -FormatArgs $UpdateAsset.Asset.Name
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
    if (-not (Test-Path -LiteralPath $DownloadDirectory -PathType Container)) { return $false }
    Remove-Item -LiteralPath $DownloadDirectory -Recurse -Force
    return $true
}

function Clear-AppCache {
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
        if (-not (Test-Path -LiteralPath $AppCacheDirectory -PathType Container)) { continue }
        Get-ChildItem -LiteralPath $AppCacheDirectory -Force | Remove-Item -Recurse -Force
        Write-UiMessage -UiKey "CacheCleared" -FormatArgs (Split-Path -Path $AppCacheDirectory -Leaf)
    }
}

function Invoke-Update {
    $Apps = Get-ConfiguredApp
    if (-not (Test-Path -LiteralPath $BaseDirectory -PathType Container)) {
        throw [UpdateException]::new("NoBaseDirectory", $BaseDirectory)
    }
    if (-not (Test-Path -LiteralPath $UpdateDirectory -PathType Container)) {
        throw [UpdateException]::new("NoUpdateDirectory", $UpdateDirectory)
    }
    $AppProcesses = Get-AppProcess -Apps $Apps
    if ($AppProcesses.Count -gt 0) {
        Stop-AppProcess -AppProcesses $AppProcesses
    }
    $Repositories = @($Apps.UpdateTargets.Repository |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique)
    if ($Repositories.Count -eq 0) { throw [UpdateException]::new("NoUpdateTargets") }

    Write-UiMessage -UiKey "StepFetchMetadata"
    $Releases = Get-Release -Repositories $Repositories
    if ($Releases.Count -eq 0) { throw [UpdateException]::new("NoMetadata") }
    Write-UiMessage -UiKey "FetchedRepositories"
    foreach ($Release in $Releases) {
        Write-UiMessage -UiKey "FetchedRepositoryItem" -FormatArgs $Release.Repository, $Release.PublishedAt
    }

    Write-UiMessage -UiKey "StepSelectAssets"
    $CandidateAssets = Select-CandidateAsset -Apps $Apps -Releases $Releases
    if ($CandidateAssets.Count -eq 0) { throw [UpdateException]::new("NoMatchedAssets") }
    $ApplicableAssets = Select-ApplicableAsset -UpdateAssets $CandidateAssets
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
        $IsFullUpdate = Test-FullUpdate -Apps $Apps -InstallableAssets $InstallableAssets
        $InstallFailureCount = Install-Asset -UpdateAssets $InstallableAssets -FullUpdate:$IsFullUpdate
    } finally {
        Write-UiMessage -UiKey "StepRemoveDownload"
        if (Remove-DownloadDirectory) {
            $DownloadDirectoryName = Split-Path -Path $DownloadDirectory -Leaf
            Write-UiMessage -UiKey "RemovedDownloadDirectory" -FormatArgs $DownloadDirectoryName
        }
    }
    if ($InstallFailureCount -gt 0) { throw [UpdateException]::new("InstallFail", $InstallFailureCount) }

    Write-UiMessage -UiKey "StepClearCache"
    Clear-AppCache -FullUpdate:$IsFullUpdate
    if ($Settings.StartMenu.Create) {
        $StartMenuScriptPath = Join-Path -Path $PSScriptRoot -ChildPath $Settings.StartMenu.Script
        & $StartMenuScriptPath
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
$CurlExecutablePath = Join-Path -Path $env:SystemRoot -ChildPath "System32\curl.exe"
$TarExecutablePath = Join-Path -Path $env:SystemRoot -ChildPath "System32\tar.exe"
$AppCacheDirectories = @(foreach ($Directory in $Settings.AppCache.Directories) {
    Resolve-ConfiguredPath -Path $Directory
})
$ErrorActionPreference = $Settings.ErrorActionPreference
$ProgressPreference = $Settings.ProgressPreference

try {
    Invoke-Update
} catch [UpdateException] {
    Write-UiMessage -UiKey $_.Exception.UiKey -FormatArgs $_.Exception.FormatArgs
    Exit-Script -Fail
} catch {
    $ScriptFileName = [System.IO.Path]::GetFileName($_.InvocationInfo.ScriptName)
    Write-UiMessage -UiKey "UnexpectedFail" -FormatArgs $_.Exception.Message, $ScriptFileName, $_.InvocationInfo.ScriptLineNumber
    Exit-Script -Fail
}
Exit-Script
