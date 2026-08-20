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

$Apps = $Settings.Apps
$UpdateRules = $Settings.UpdateRules
$BaseDirectory = Resolve-ConfiguredPath -Path $Settings.Paths.BaseDirectory
$UpdateDirectory = Resolve-ConfiguredPath -Path $Settings.Paths.UpdateDirectory
$TarExecutablePath = Join-Path -Path $env:SystemRoot -ChildPath "System32\tar.exe"
$DownloadDirectory = Join-Path -Path $UpdateDirectory -ChildPath "download"
$AppCacheDirectories = @($Settings.AppCache.Directories) | ForEach-Object { Resolve-ConfiguredPath -Path $_ }

$ErrorActionPreference = $Settings.ErrorActionPreference
$ProgressPreference = $Settings.ProgressPreference

$TimestampFormat = "yyyy-MM-dd HH:mm:ss"

# Functions
function Write-UiMessage {
    param (
        [Parameter(Mandatory)] [string]$UiKey,
        [object[]]$FormatArgs,
        [switch]$NoNewline
    )

    $UiTemplate = $UiTemplates.$UiKey
    if ($null -eq $UiTemplate) { return }
    $DisplayText = if ($FormatArgs -and $FormatArgs.Count -gt 0) {
        $UiTemplate.Template -f $FormatArgs
    } else {
        $UiTemplate.Template
    }
    Write-Host $DisplayText -ForegroundColor $UiTemplate.Color -NoNewline:$NoNewline
}

function Exit-WithMessage {
    param (
        [switch]$Success,
        [switch]$Fail
    )

    if ($Success) {
        [System.Media.SystemSounds]::Asterisk.Play()
    } elseif ($Fail) {
        [System.Media.SystemSounds]::Hand.Play()
    }
    Write-UiMessage -UiKey "PressEnterExit"
    $null = Read-Host
    if ($Fail) { exit 1 } else { exit 0 }
}

function Test-ExcludedName {
    param ([Parameter(Mandatory)] [string]$Name)

    return $UpdateRules.ExcludedNames -contains $Name
}

function Assert-RequiredDirectory {
    param (
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$UiKey
    )

    if (-not (Test-Path -Path $Path -PathType Container)) {
        Write-UiMessage -UiKey $UiKey -FormatArgs @($Path)
        Exit-WithMessage -Fail
    }
}

function Assert-ConfiguredExecutable {
    foreach ($AppName in $Apps.PSObject.Properties.Name) {
        if ([string]::IsNullOrEmpty($Apps.$AppName.Executable)) {
            Write-UiMessage -UiKey "NoExecutable" -FormatArgs @($AppName)
            Exit-WithMessage -Fail
        }
    }
}

function Stop-RunningProcess {
    $BaseDirectoryPrefix = $BaseDirectory + [System.IO.Path]::DirectorySeparatorChar
    $RunningProcesses = @(foreach ($AppName in $Apps.PSObject.Properties.Name) {
        $ExecutableName = [System.IO.Path]::GetFileNameWithoutExtension($Apps.$AppName.Executable)
        foreach ($Process in @(Get-Process -Name $ExecutableName -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrEmpty($Process.Path) -or
                -not $Process.Path.StartsWith($BaseDirectoryPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            [PSCustomObject]@{ AppName = $AppName; Process = $Process }
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
            Write-UiMessage -UiKey "UserCancel"
            Exit-WithMessage -Fail
        }
        foreach ($RunningProcess in $RunningProcesses) {
            Stop-Process -Id $RunningProcess.Process.Id -Force
        }
        Write-UiMessage -UiKey "ProceedUpdate"
    }
}

function Get-ReleaseMetadata {
    param ([Parameter(Mandatory)] [array]$UpdateTargets)

    $RequestHeaders = @{}
    if (-not [string]::IsNullOrEmpty($UpdateRules.ApiToken)) {
        $RequestHeaders["Authorization"] = "Bearer $($UpdateRules.ApiToken)"
    }
    $UniqueRepositories = @($UpdateTargets.Repository) | Select-Object -Unique
    $ReleaseMetadata = @(foreach ($Repository in $UniqueRepositories) {
        try {
            $ApiEndpointUri = $UpdateRules.ApiEndpoint -f $Repository
            $ApiResponse = Invoke-RestMethod -Uri $ApiEndpointUri -TimeoutSec 15 -Headers $RequestHeaders
            foreach ($Asset in $ApiResponse.assets) {
                [PSCustomObject]@{
                    Repository  = $Repository
                    PublishedAt = ([DateTime]::Parse($ApiResponse.published_at, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal)).ToLocalTime()
                    AssetName   = $Asset.name
                    DownloadUrl = $Asset.browser_download_url
                    Digest      = $Asset.digest
                }
            }
        } catch {
            $StatusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($StatusCode -eq 401) {
                Write-UiMessage -UiKey "ApiTokenError"
                Exit-WithMessage -Fail
            } elseif ($StatusCode -eq 403 -or $StatusCode -eq 429) {
                Write-UiMessage -UiKey "ApiRateLimitError"
                Exit-WithMessage -Fail
            } else {
                Write-UiMessage -UiKey "ApiRequestError" -FormatArgs @($Repository, $_.Exception.Message)
            }
        }
    })
    return $ReleaseMetadata
}

function Get-UpdateThresholdTime {
    param ([Parameter(Mandatory)] [string]$AppName)

    $InstalledExecutablePath = Join-Path -Path $BaseDirectory -ChildPath $Apps.$AppName.Executable
    if (Test-Path -Path $InstalledExecutablePath -PathType Leaf) {
        $LastWriteTime = (Get-Item -Path $InstalledExecutablePath).LastWriteTime
        return $LastWriteTime.AddMinutes($UpdateRules.LocalTimestampOffsetMinutes)
    }
    return [DateTime]::MinValue
}

function Select-LatestAsset {
    param (
        [Parameter(Mandatory)] [array]$ReleaseMetadata,
        [Parameter(Mandatory)] [array]$UpdateTargets
    )

    $Candidates = foreach ($UpdateTarget in $UpdateTargets) {
        if ([string]::IsNullOrEmpty($UpdateTarget.AssetFilter)) {
            Write-UiMessage -UiKey "EmptyAssetFilter" -FormatArgs @($UpdateTarget.Repository, $UpdateTarget.AppName)
            continue
        }
        $FilterPattern = if ($UpdateTarget.AssetFilter.Contains('*')) {
            $UpdateTarget.AssetFilter
        } else {
            "*$($UpdateTarget.AssetFilter)*"
        }
        $MatchedAssets = @(foreach ($Metadata in $ReleaseMetadata) {
            if ($Metadata.Repository -ne $UpdateTarget.Repository -or $Metadata.AssetName -notlike $FilterPattern) { continue }
            $AssetCategory = Get-AssetCategory -AssetName $Metadata.AssetName
            if ($null -eq $AssetCategory) { continue }
            [PSCustomObject]@{
                AppName        = $UpdateTarget.AppName
                Repository     = $Metadata.Repository
                AssetName      = $Metadata.AssetName
                PublishedAt    = $Metadata.PublishedAt
                DownloadUrl    = $Metadata.DownloadUrl
                Digest         = $Metadata.Digest
                AssetCategory  = $AssetCategory
                Preferred      = $UpdateTarget.Preferred
                Force          = $UpdateTarget.Force
                AssetDirectory = $null
                FilePath       = $null
            }
        })
        if ($MatchedAssets.Count -eq 0) {
            Write-UiMessage -UiKey "AssetNotFound" -FormatArgs @($UpdateTarget.Repository, $UpdateTarget.AssetFilter)
        }
        $MatchedAssets
    }
    return @($Candidates | Group-Object -Property AppName | ForEach-Object {
        $PreferredAssets = @($_.Group | Where-Object { $_.Preferred })
        $EligibleAssets = if ($PreferredAssets.Count -gt 0) { $PreferredAssets } else { $_.Group }
        $EligibleAssets | Sort-Object -Property PublishedAt -Descending | Select-Object -First 1
    })
}

function Select-ApplicableAsset {
    param ([Parameter(Mandatory)] [array]$Candidates)

    $ForceAllUpdates = $UpdateRules.ForceUpdate
    $ApplicableAssets = foreach ($Candidate in $Candidates) {
        $ThresholdTime = Get-UpdateThresholdTime -AppName $Candidate.AppName
        $ShouldApply = $ForceAllUpdates -or $Candidate.Force -or
                       $Candidate.PublishedAt -gt $ThresholdTime
        if ($ShouldApply) {
            Write-UiMessage -UiKey "SelectedAsset" -FormatArgs @($Candidate.AppName, $Candidate.Repository) -NoNewline
        } else {
            Write-UiMessage -UiKey "NoNewRelease" -FormatArgs @($Candidate.Repository, $Candidate.PublishedAt.ToString($TimestampFormat)) -NoNewline
        }
        if ($Candidate.Preferred) { Write-UiMessage -UiKey "PreferredTag" -NoNewline }
        if ($Candidate.Force) { Write-UiMessage -UiKey "ForceTag" -NoNewline }
        Write-UiMessage -UiKey "EndLine"
        if ($ShouldApply) {
            Write-UiMessage -UiKey "SelectedAssetItem" -FormatArgs @($Candidate.AssetName, $Candidate.PublishedAt.ToString($TimestampFormat))
            $Candidate
        }
    }
    return @($ApplicableAssets)
}

function Invoke-AssetDownload {
    param ([Parameter(Mandatory)] [array]$ApplicableAssets)

    if (Test-Path -Path $DownloadDirectory -PathType Container) {
        Remove-Item -Path $DownloadDirectory -Recurse -Force
    }
    $Downloads = foreach ($ApplicableAsset in $ApplicableAssets) {
        $ApplicableAsset.AssetDirectory = Join-Path -Path $DownloadDirectory -ChildPath $ApplicableAsset.AppName
        New-Item -ItemType Directory -Path $ApplicableAsset.AssetDirectory -Force | Out-Null
        $ApplicableAsset.FilePath = Join-Path -Path $ApplicableAsset.AssetDirectory -ChildPath $ApplicableAsset.AssetName
        $IsSuccess = $true
        try {
            Invoke-WebRequest -Uri $ApplicableAsset.DownloadUrl -OutFile $ApplicableAsset.FilePath -ErrorAction Stop
        } catch {
            $IsSuccess = $false
            Write-UiMessage -UiKey "DownloadFail" -FormatArgs @($ApplicableAsset.AssetName)
        }
        Write-UiMessage -UiKey "DownloadItem" -FormatArgs @($ApplicableAsset.AppName, $ApplicableAsset.AssetName) -NoNewline
        if ($IsSuccess) {
            Write-UiMessage -UiKey "StatusOk"
            $ApplicableAsset
        } else {
            Write-UiMessage -UiKey "StatusFail"
        }
    }
    return @($Downloads)
}

function Select-VerifiedDownload {
    param ([array]$Downloads)

    $VerifiedDownloads = foreach ($Download in $Downloads) {
        Write-UiMessage -UiKey "VerifyAsset" -FormatArgs @($Download.AssetName)
        $CalculatedDigest = "sha256:$((Get-FileHash -Path $Download.FilePath -Algorithm SHA256).Hash.ToLower())"
        Write-UiMessage -UiKey "VerifyAssetDigest" -FormatArgs @($CalculatedDigest) -NoNewline
        $IsDigestMatched = if ([string]::IsNullOrEmpty($Download.Digest)) {
            Write-UiMessage -UiKey "DigestNotProvided"
            $true
        } elseif ($CalculatedDigest -eq $Download.Digest) {
            Write-UiMessage -UiKey "DigestMatch"
            $true
        } else {
            Write-UiMessage -UiKey "DigestMismatch"
            $false
        }
        if ($IsDigestMatched) { $Download }
    }
    return @($VerifiedDownloads)
}

function Get-AssetCategory {
    param ([Parameter(Mandatory)] [string]$AssetName)

    foreach ($Category in "Executable", "Archive") {
        foreach ($Extension in $UpdateRules.AssetTypes.$Category) {
            if ($AssetName -like "*$Extension") { return $Category }
        }
    }
}

function Expand-ArchiveFile {
    param ([Parameter(Mandatory)] [string]$FilePath)

    $ParentDirectory = Split-Path -Path $FilePath -Parent
    & $TarExecutablePath -x -f "$FilePath" -C "$ParentDirectory" | Out-Null
    return $LASTEXITCODE -eq 0
}

function Select-ExtractedAsset {
    param ([Parameter(Mandatory)] [array]$VerifiedDownloads)

    $ExtractedAssets = @(foreach ($VerifiedDownload in $VerifiedDownloads) {
        if ($VerifiedDownload.AssetCategory -ne "Archive") {
            $VerifiedDownload
            continue
        }
        Write-UiMessage -UiKey "ExtractItem" -FormatArgs @($VerifiedDownload.AssetName)
        if (Expand-ArchiveFile -FilePath $VerifiedDownload.FilePath) {
            $VerifiedDownload
        } else {
            Write-UiMessage -UiKey "ExtractFail" -FormatArgs @($VerifiedDownload.AssetName)
        }
    })
    return @($ExtractedAssets)
}

function Remove-PreviousInstallation {
    [OutputType([int])]
    param ()

    Write-UiMessage -UiKey "RemovePreviousHeader" -FormatArgs @($BaseDirectory)
    return (Remove-InstalledContent -Directory $BaseDirectory)
}

function Remove-InstalledContent {
    [OutputType([int])]
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
        $InstalledItemPrefix = $InstalledItem.FullName + [System.IO.Path]::DirectorySeparatorChar
        if ($UpdateDirectory.StartsWith($InstalledItemPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
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
    param ([Parameter(Mandatory)] [PSCustomObject]$Asset)

    $DestinationPath = Join-Path -Path $BaseDirectory -ChildPath $Asset.AssetName
    Move-Item -Path $Asset.FilePath -Destination $DestinationPath -Force -ErrorAction Stop
    Write-UiMessage -UiKey "Moved" -FormatArgs @($Asset.AssetName)
    (Get-Item -Path $DestinationPath -ErrorAction Stop).LastWriteTime = $Asset.PublishedAt
    Write-UiMessage -UiKey "TimestampSet" -FormatArgs @($Asset.PublishedAt.ToString($TimestampFormat))
}

function Install-ExtractedContent {
    param ([Parameter(Mandatory)] [PSCustomObject]$Asset)

    $Filters = $Apps.($Asset.AppName).InstallFilters
    $SearchDirectory = $Asset.AssetDirectory
    $SubDirectories = @(Get-ChildItem -Path $Asset.AssetDirectory -Directory)
    $SubFiles = @(Get-ChildItem -Path $Asset.AssetDirectory -File | Where-Object { $_.Name -ne $Asset.AssetName })
    if ($SubDirectories.Count -eq 1 -and $SubFiles.Count -eq 0) {
        $SearchDirectory = $SubDirectories.FullName
    }
    $HasFilters = $Filters -and $Filters.Count -gt 0
    $InstallItems = if ($HasFilters) {
        foreach ($Filter in $Filters) {
            @(Get-ChildItem -Path $SearchDirectory -Filter $Filter)
        }
    } else {
        @(Get-ChildItem -Path $SearchDirectory | Where-Object { $_.Name -ne $Asset.AssetName })
    }
    foreach ($InstallItem in $InstallItems) {
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
    [OutputType([bool])]
    param ([Parameter(Mandatory)] [array]$ExtractedAssets)

    $AppNames = @($Apps.PSObject.Properties.Name)
    foreach ($AppName in $AppNames) {
        $ExecutablePath = Join-Path -Path $BaseDirectory -ChildPath $Apps.$AppName.Executable
        if (Test-Path -Path $ExecutablePath -PathType Leaf) {
            return ($ExtractedAssets.Count -eq $AppNames.Count)
        }
    }
    return $true
}

function Install-Asset {
    [OutputType([int])]
    param (
        [Parameter(Mandatory)] [array]$ExtractedAssets,
        [Parameter(Mandatory)] [bool]$IsFullUpdate
    )

    $FailureCount = 0
    if ($IsFullUpdate) {
        Write-UiMessage -UiKey "FullUpdate"
        $FailureCount += Remove-PreviousInstallation
    } else {
        Write-UiMessage -UiKey "PartialUpdate"
    }
    Write-UiMessage -UiKey "InstallHeader"
    foreach ($ExtractedAsset in $ExtractedAssets) {
        Write-UiMessage -UiKey "InstallItem" -FormatArgs @($ExtractedAsset.AssetCategory, $ExtractedAsset.AssetName)
        try {
            if ($ExtractedAsset.AssetCategory -eq "Executable") {
                Install-Executable -Asset $ExtractedAsset
            } elseif ($ExtractedAsset.AssetCategory -eq "Archive") {
                Install-ExtractedContent -Asset $ExtractedAsset
            }
        } catch {
            Write-UiMessage -UiKey "InstallItemFail" -FormatArgs @($_.Exception.Message)
            $FailureCount++
        }
    }
    return $FailureCount
}

function Remove-DownloadDirectory {
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

# Main
# Validate configuration and paths
Assert-ConfiguredExecutable
Assert-RequiredDirectory -Path $BaseDirectory -UiKey "NoBaseDirectory"
Assert-RequiredDirectory -Path $UpdateDirectory -UiKey "NoUpdateDirectory"
Stop-RunningProcess

# Flatten Update Targets
$UpdateTargets = @(foreach ($AppProperty in $Apps.PSObject.Properties) {
    foreach ($UpdateTarget in $AppProperty.Value.UpdateTargets) {
        [PSCustomObject]@{
            Preferred   = $UpdateTarget.Preferred
            Repository  = $UpdateTarget.Repository
            AppName     = $AppProperty.Name
            AssetFilter = $UpdateTarget.AssetFilter
            Force       = $UpdateTarget.Force
        }
    }
})
if ($UpdateTargets.Count -eq 0) { Write-UiMessage -UiKey "NoUpdateTargets"; Exit-WithMessage -Fail }

# Fetch Release Metadata
Write-UiMessage -UiKey "StepFetchMetadata"
$ReleaseMetadata = Get-ReleaseMetadata -UpdateTargets $UpdateTargets
if ($ReleaseMetadata.Count -eq 0) { Write-UiMessage -UiKey "NoMetadata"; Exit-WithMessage -Fail }
Write-UiMessage -UiKey "FetchedRepositories"
$ReleaseMetadata | Select-Object -Property Repository, PublishedAt -Unique | ForEach-Object {
    Write-UiMessage -UiKey "FetchedRepositoryItem" -FormatArgs @($_.Repository, $_.PublishedAt.ToString($TimestampFormat))
}

# Select Update Targets
Write-UiMessage -UiKey "StepSelectAssets"
$Candidates = Select-LatestAsset -ReleaseMetadata $ReleaseMetadata -UpdateTargets $UpdateTargets
if ($Candidates.Count -eq 0) { Write-UiMessage -UiKey "NoMatchedAssets"; Exit-WithMessage -Fail }
$ApplicableAssets = Select-ApplicableAsset -Candidates $Candidates
if ($ApplicableAssets.Count -eq 0) { Write-UiMessage -UiKey "NoUpdateRequired"; Exit-WithMessage -Success }

# Download, Verify & Install
Write-UiMessage -UiKey "StepDownload"
$Downloads = Invoke-AssetDownload -ApplicableAssets $ApplicableAssets
Write-UiMessage -UiKey "StepVerify"
$VerifiedDownloads = @(Select-VerifiedDownload -Downloads $Downloads)
if ($VerifiedDownloads.Count -eq 0) {
    Write-UiMessage -UiKey "NoVerifiedAssets"
    Write-UiMessage -UiKey "StepCleanDownload"
    Remove-DownloadDirectory
    Exit-WithMessage -Fail
}
Write-UiMessage -UiKey "StepExtract"
$ExtractedAssets = @(Select-ExtractedAsset -VerifiedDownloads $VerifiedDownloads)
if ($ExtractedAssets.Count -eq 0) {
    Write-UiMessage -UiKey "NoExtractedAssets"
    Write-UiMessage -UiKey "StepCleanDownload"
    Remove-DownloadDirectory
    Exit-WithMessage -Fail
}
Write-UiMessage -UiKey "StepInstall"
$IsFullUpdate = Test-FullUpdate -ExtractedAssets $ExtractedAssets
$InstallFailureCount = Install-Asset -ExtractedAssets $ExtractedAssets -IsFullUpdate $IsFullUpdate
Write-UiMessage -UiKey "StepCleanDownload"
Remove-DownloadDirectory
if ($InstallFailureCount -gt 0) { Write-UiMessage -UiKey "InstallFail" -FormatArgs @($InstallFailureCount); Exit-WithMessage -Fail }
Write-UiMessage -UiKey "StepCleanCache"
Clear-AppCache -IsFullUpdate $IsFullUpdate
if ($Settings.StartMenu.Create) {
    $StartMenuScriptPath = Join-Path -Path $PSScriptRoot -ChildPath $Settings.StartMenu.Script
    if (Test-Path -Path $StartMenuScriptPath -PathType Leaf) {
        & $StartMenuScriptPath
    }
}
Write-UiMessage -UiKey "RunComplete"
Exit-WithMessage -Success
