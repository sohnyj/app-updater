# === Configuration & Environment ===

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
$UiTemplates = Import-JsonFile -FilePath (Join-Path -Path $PSScriptRoot -ChildPath "ui_templates.json")

$Apps = $Settings.Apps
$SharedUpdateRules = $Settings.SharedUpdateRules
$BaseDirectory = Resolve-ConfiguredPath -Path $Settings.Environment.Paths.BaseDirectory
$UpdateDirectory = Resolve-ConfiguredPath -Path $Settings.Environment.Paths.UpdateDirectory
$AppCacheDirectories = @($Settings.Environment.Paths.AppCacheDirectories) | ForEach-Object { Resolve-ConfiguredPath -Path $_ }
$ErrorActionPreference = $Settings.ErrorActionPreference
$ProgressPreference = $Settings.ProgressPreference

$TimestampFormat = "yyyy-MM-dd HH:mm:ss"
$TarExecutablePath = Join-Path -Path $env:SystemRoot -ChildPath "System32\tar.exe"

# === Functions ===

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

function Test-ExcludedItem {
    param ([Parameter(Mandatory)] [string]$ItemName)

    return $SharedUpdateRules.ExcludedNames -contains $ItemName
}

function Assert-RequiredPath {
    param (
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$PathType,
        [Parameter(Mandatory)] [string]$UiKey
    )

    if (-not (Test-Path -Path $Path -PathType $PathType)) {
        Write-UiMessage -UiKey $UiKey -FormatArgs @($Path)
        Exit-WithMessage -Fail
    }
}

function Assert-ConfiguredExecutable {
    foreach ($AppName in $Apps.PSObject.Properties.Name) {
        if ([string]::IsNullOrEmpty($Apps.$AppName.Executable)) {
            Write-UiMessage -UiKey "NoConfiguredExecutable" -FormatArgs @($AppName)
            Exit-WithMessage -Fail
        }
    }
}

function Stop-RunningProcess {
    $RunningProcesses = @(foreach ($AppName in $Apps.PSObject.Properties.Name) {
        $ExecutableName = [System.IO.Path]::GetFileNameWithoutExtension($Apps.$AppName.Executable)
        foreach ($Process in @(Get-Process -Name $ExecutableName -ErrorAction SilentlyContinue)) {
            [PSCustomObject]@{ AppName = $AppName; Process = $Process }
        }
    })
    if ($RunningProcesses.Count -gt 0) {
        [System.Media.SystemSounds]::Beep.Play()
        Write-UiMessage -UiKey "AppRunning"
        foreach ($RunningProcess in $RunningProcesses) {
            Write-UiMessage -UiKey "AppRunningItem" -FormatArgs @($RunningProcess.AppName)
        }
        Write-UiMessage -UiKey "AppContinueQuery" -NoNewline
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
    if (-not [string]::IsNullOrEmpty($SharedUpdateRules.ApiToken)) {
        $RequestHeaders["Authorization"] = "Bearer $($SharedUpdateRules.ApiToken)"
    }
    $UniqueRepositories = @($UpdateTargets.Repository) | Select-Object -Unique
    $ReleaseMetadata = @(foreach ($Repository in $UniqueRepositories) {
        try {
            $ApiEndpointUri = $SharedUpdateRules.ApiEndpoint -f $Repository
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
            $StatusCode = if ($_.Exception.Response) { $_.Exception.Response.StatusCode } else { $null }
            if ($StatusCode -eq [System.Net.HttpStatusCode]::Unauthorized) {
                Write-UiMessage -UiKey "ApiTokenError"
                Exit-WithMessage -Fail
            } elseif ($StatusCode -eq [System.Net.HttpStatusCode]::Forbidden) {
                Write-UiMessage -UiKey "ApiLimitError"
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

    $LocalFilePath = Join-Path -Path $BaseDirectory -ChildPath $Apps.$AppName.Executable
    if (Test-Path -Path $LocalFilePath -PathType Leaf) {
        $LastWriteTime = (Get-Item -Path $LocalFilePath).LastWriteTime
        return $LastWriteTime.AddMinutes($SharedUpdateRules.VersionComparison.LocalTimestampOffsetMinutes)
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
            $FileCategory = Get-FileCategory -FileName $Metadata.AssetName
            if ($null -eq $FileCategory) { continue }
            [PSCustomObject]@{
                AppName      = $UpdateTarget.AppName
                Repository   = $Metadata.Repository
                AssetName    = $Metadata.AssetName
                PublishedAt  = $Metadata.PublishedAt
                DownloadUrl  = $Metadata.DownloadUrl
                Digest       = $Metadata.Digest
                FileCategory = $FileCategory
                Preferred    = $UpdateTarget.Preferred
                Force        = $UpdateTarget.Force
                FilePath     = $null
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

    $ForceAllUpdates = $SharedUpdateRules.VersionComparison.ForceUpdate -eq $true
    $ApplicableAssets = foreach ($Candidate in $Candidates) {
        $ThresholdTime = Get-UpdateThresholdTime -AppName $Candidate.AppName
        $ShouldApply = $ThresholdTime -eq [DateTime]::MinValue -or
                       $ForceAllUpdates -or $Candidate.Force -or
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

function Invoke-FileDownload {
    param ([Parameter(Mandatory)] [array]$ApplicableAssets)

    $Downloads = foreach ($ApplicableAsset in $ApplicableAssets) {
        $DownloadDirectory = Join-Path -Path $UpdateDirectory -ChildPath $ApplicableAsset.AppName
        New-Item -ItemType Directory -Path $DownloadDirectory -Force | Out-Null
        $ApplicableAsset.FilePath = Join-Path -Path $DownloadDirectory -ChildPath $ApplicableAsset.AssetName
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
        Write-UiMessage -UiKey "VerifyFile" -FormatArgs @($Download.AssetName)
        $CalculatedDigest = "sha256:$((Get-FileHash -Path $Download.FilePath -Algorithm SHA256).Hash.ToLower())"
        Write-UiMessage -UiKey "VerifyFileDigest" -FormatArgs @($CalculatedDigest) -NoNewline
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

function Get-FileCategory {
    param ([Parameter(Mandatory)] [string]$FileName)

    foreach ($Category in "Executable", "Archive") {
        foreach ($Extension in $SharedUpdateRules.FileTypes.$Category) {
            if ($FileName -like "*$Extension") { return $Category }
        }
    }
}

function Expand-ArchiveFile {
    param ([Parameter(Mandatory)] [string]$FilePath)

    $ParentDirectory = Split-Path -Path $FilePath -Parent
    & $TarExecutablePath -x -f "$FilePath" -C "$ParentDirectory" | Out-Null
    return $LASTEXITCODE -eq 0
}

function Remove-PreviousInstallation {
    Write-UiMessage -UiKey "RemovePreviousHeader" -FormatArgs @($BaseDirectory)
    $CurrentItems = @(Get-ChildItem -Path $BaseDirectory -Force)
    foreach ($CurrentItem in $CurrentItems) {
        if ($CurrentItem.FullName -eq $UpdateDirectory -or (Test-ExcludedItem -ItemName $CurrentItem.Name)) {
            Write-UiMessage -UiKey "SkipExcluded" -FormatArgs @($CurrentItem.Name)
            continue
        }
        Remove-Item -Path $CurrentItem.FullName -Recurse -Force
    }
}

function Install-Executable {
    param (
        [Parameter(Mandatory)] [string]$SourcePath,
        [Parameter(Mandatory)] [DateTime]$Timestamp
    )

    $FileName = Split-Path -Path $SourcePath -Leaf
    $DestinationPath = Join-Path -Path $BaseDirectory -ChildPath $FileName
    Move-Item -Path $SourcePath -Destination $DestinationPath -Force
    Write-UiMessage -UiKey "Moved" -FormatArgs @($FileName)
    (Get-Item -Path $DestinationPath).LastWriteTime = $Timestamp
    Write-UiMessage -UiKey "TimestampSet" -FormatArgs @($Timestamp.ToString($TimestampFormat))
}

function Install-ExtractedContent {
    param (
        [Parameter(Mandatory)] [string]$SourceDirectory,
        [array]$Filters,
        [string]$FileName
    )

    $SearchDirectory = $SourceDirectory
    $SubDirectories = @(Get-ChildItem -Path $SourceDirectory -Directory)
    $SubFiles = @(Get-ChildItem -Path $SourceDirectory -File | Where-Object { $_.Name -ne $FileName })
    if ($SubDirectories.Count -eq 1 -and $SubFiles.Count -eq 0) {
        $SearchDirectory = $SubDirectories.FullName
    }
    $HasFilters = $Filters -and $Filters.Count -gt 0
    $DeployItems = if ($HasFilters) {
        foreach ($Filter in $Filters) {
            @(Get-ChildItem -Path $SearchDirectory -Filter $Filter)
        }
    } else {
        @(Get-ChildItem -Path $SearchDirectory | Where-Object { $_.Name -ne $FileName })
    }
    foreach ($DeployItem in $DeployItems) {
        if (Test-ExcludedItem -ItemName $DeployItem.Name) {
            Write-UiMessage -UiKey "SkipExcluded" -FormatArgs @($DeployItem.Name)
            continue
        }
        $DestinationItemPath = Join-Path -Path $BaseDirectory -ChildPath $DeployItem.Name
        if (Test-Path -Path $DestinationItemPath) {
            Remove-Item -Path $DestinationItemPath -Recurse -Force
        }
        Move-Item -Path $DeployItem.FullName -Destination $DestinationItemPath -Force
        if ($HasFilters) {
            Write-UiMessage -UiKey "MovedFiltered" -FormatArgs @($DeployItem.Name)
        } else {
            Write-UiMessage -UiKey "MovedFullStructure" -FormatArgs @($DeployItem.Name)
        }
    }
}

function Invoke-AppUpdate {
    [OutputType([bool])]
    param ([Parameter(Mandatory)] [array]$VerifiedDownloads)

    $ExistingExecutableCount = 0
    foreach ($AppName in $Apps.PSObject.Properties.Name) {
        $ExecutablePath = Join-Path -Path $BaseDirectory -ChildPath $Apps.$AppName.Executable
        if (Test-Path -Path $ExecutablePath -PathType Leaf) { $ExistingExecutableCount++ }
    }
    $IsFullUpdate = (($VerifiedDownloads.Count -eq $Apps.PSObject.Properties.Name.Count) -or ($ExistingExecutableCount -eq 0))
    if ($IsFullUpdate) {
        Write-UiMessage -UiKey "FullUpdate"
        Remove-PreviousInstallation
    } else {
        Write-UiMessage -UiKey "PartialUpdate"
    }
    Write-UiMessage -UiKey "ApplyHeader"
    foreach ($VerifiedDownload in $VerifiedDownloads) {
        Write-UiMessage -UiKey "ApplyItem" -FormatArgs @($VerifiedDownload.FileCategory, $VerifiedDownload.AssetName)
        if ($VerifiedDownload.FileCategory -eq "Executable") {
            Install-Executable -SourcePath $VerifiedDownload.FilePath -Timestamp $VerifiedDownload.PublishedAt
        } elseif ($VerifiedDownload.FileCategory -eq "Archive") {
            if (Expand-ArchiveFile -FilePath $VerifiedDownload.FilePath) {
                Install-ExtractedContent -SourceDirectory (Split-Path -Path $VerifiedDownload.FilePath) -Filters $Apps.($VerifiedDownload.AppName).DeployFilters -FileName $VerifiedDownload.AssetName
            } else {
                Write-UiMessage -UiKey "ExtractFail" -FormatArgs @($VerifiedDownload.AssetName)
            }
        }
    }
    return $IsFullUpdate
}

function Remove-TemporaryDirectory {
    param ([Parameter(Mandatory)] [array]$ApplicableAssets)

    $UniqueDirectories = @($ApplicableAssets | ForEach-Object { Join-Path -Path $UpdateDirectory -ChildPath $_.AppName } | Select-Object -Unique)
    foreach ($DirectoryToRemove in $UniqueDirectories) {
        if (Test-Path -Path $DirectoryToRemove -PathType Container) {
            Remove-Item -Path $DirectoryToRemove -Recurse -Force
            Write-UiMessage -UiKey "RemovedTemporaryDirectory" -FormatArgs @(Split-Path -Path $DirectoryToRemove -Leaf)
        }
    }
}

function Clear-AppCache {
    param ([Parameter(Mandatory)] [bool]$IsFullUpdate)

    if ($Settings.AppCache.Clear -ne $true) { Write-UiMessage -UiKey "CacheClearOff"; return }
    if (-not $IsFullUpdate) {
        if ($Settings.AppCache.ClearOnPartialUpdate -ne $true) { Write-UiMessage -UiKey "CacheClearSkipped"; return }
        Write-UiMessage -UiKey "CacheClearForced"
    }
    foreach ($AppCacheDirectory in $AppCacheDirectories) {
        if (Test-Path -Path $AppCacheDirectory -PathType Container) {
            Get-ChildItem -Path $AppCacheDirectory | Remove-Item -Recurse -Force
            Write-UiMessage -UiKey "CacheCleared" -FormatArgs @(Split-Path -Path $AppCacheDirectory -Leaf)
        }
    }
}

# === Main ===

# [Phase 0] Validate configuration and paths
Assert-ConfiguredExecutable
Stop-RunningProcess
Assert-RequiredPath -Path $BaseDirectory -PathType Container -UiKey "NoBaseDirectory"
Assert-RequiredPath -Path $UpdateDirectory -PathType Container -UiKey "NoUpdateDirectory"

# [Phase 1] Flatten Update Targets
$UpdateTargets = @(foreach ($AppProperty in $Apps.PSObject.Properties) {
    foreach ($UpdateTarget in $AppProperty.Value.UpdateTargets) {
        [PSCustomObject]@{
            Preferred   = $UpdateTarget.Preferred -eq $true
            Repository  = $UpdateTarget.Repository
            AppName     = $AppProperty.Name
            AssetFilter = $UpdateTarget.AssetFilter
            Force       = $UpdateTarget.Force -eq $true
        }
    }
})

# [Phase 2] Fetch Release Metadata
Write-UiMessage -UiKey "StepFetchMetadata"
$ReleaseMetadata = Get-ReleaseMetadata -UpdateTargets $UpdateTargets
if ($ReleaseMetadata.Count -eq 0) { Write-UiMessage -UiKey "NoMetadata"; Exit-WithMessage -Fail }
Write-UiMessage -UiKey "FetchedRepositories"
$ReleaseMetadata | Select-Object -Property Repository, PublishedAt -Unique | ForEach-Object {
    Write-UiMessage -UiKey "FetchedRepositoryItem" -FormatArgs @($_.Repository, $_.PublishedAt.ToString($TimestampFormat))
}

# [Phase 3] Select Update Targets
Write-UiMessage -UiKey "StepSelectAssets"
$Candidates = Select-LatestAsset -ReleaseMetadata $ReleaseMetadata -UpdateTargets $UpdateTargets
$ApplicableAssets = Select-ApplicableAsset -Candidates $Candidates
if ($ApplicableAssets.Count -eq 0) { Write-UiMessage -UiKey "NoUpdateRequired"; Exit-WithMessage -Success }

# [Phase 4] Download, Verify & Deploy
Write-UiMessage -UiKey "StepDownload"
$Downloads = Invoke-FileDownload -ApplicableAssets $ApplicableAssets
Write-UiMessage -UiKey "StepVerify"
$VerifiedDownloads = @(Select-VerifiedDownload -Downloads $Downloads)
if ($VerifiedDownloads.Count -eq 0) {
    Write-UiMessage -UiKey "NoVerifiedAssets"
    Write-UiMessage -UiKey "StepCleanTemporary"
    Remove-TemporaryDirectory -ApplicableAssets $ApplicableAssets
    Write-UiMessage -UiKey "DownloadAllFail"
    Exit-WithMessage -Fail
}
Write-UiMessage -UiKey "StepDeploy"
$IsFullUpdate = Invoke-AppUpdate -VerifiedDownloads $VerifiedDownloads
Write-UiMessage -UiKey "StepCleanTemporary"
Remove-TemporaryDirectory -ApplicableAssets $ApplicableAssets
Write-UiMessage -UiKey "StepCleanCache"
Clear-AppCache -IsFullUpdate $IsFullUpdate
if ($Settings.StartMenu.Create -eq $true) {
    $StartMenuScript = Join-Path -Path $PSScriptRoot -ChildPath $Settings.StartMenu.Script
    if (Test-Path -Path $StartMenuScript -PathType Leaf) {
        & $StartMenuScript
    }
}
Write-UiMessage -UiKey "RunComplete"
Exit-WithMessage -Success
