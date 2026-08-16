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

function Resolve-DeletablePath {
    param ([Parameter(Mandatory)] [string]$Path)

    $ExpandedPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
    $RootPath = [System.IO.Path]::GetPathRoot($ExpandedPath)
    if ($ExpandedPath.Length -le $RootPath.Length) { return $ExpandedPath }
    return $ExpandedPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
}

$Settings = Import-JsonFile -FilePath (Join-Path -Path $PSScriptRoot -ChildPath "settings.json")
$UiTemplates = Import-JsonFile -FilePath (Join-Path -Path $PSScriptRoot -ChildPath "ui_templates.json")

$Apps = $Settings.Apps
$GlobalUpdateRules = $Settings.GlobalUpdateRules
$BaseDirectory = Resolve-DeletablePath -Path $Settings.Environment.Paths.BaseDirectory
$UpdateDirectory = Resolve-DeletablePath -Path $Settings.Environment.Paths.UpdateDirectory
$AppCacheDirectories = @($Settings.Environment.Paths.AppCacheDirectories) | ForEach-Object { Resolve-DeletablePath -Path $_ }
$TarExecutablePath = [Environment]::ExpandEnvironmentVariables($Settings.Environment.TarExecutablePath)
$ErrorActionPreference = $Settings.ErrorActionPreference
$ProgressPreference = $Settings.ProgressPreference

$TimestampFormat = "yyyy-MM-dd HH:mm:ss"

# === Functions ===

function Write-UiMessage {
    param (
        [Parameter(Mandatory)] [string]$UiKey,
        [object[]]$FormatArgs,
        [switch]$NoNewline
    )

    $UiElement = $UiTemplates.$UiKey
    if ($null -eq $UiElement) { return }
    $DisplayText = if ($FormatArgs -and $FormatArgs.Count -gt 0) {
        $UiElement.Template -f $FormatArgs
    } else {
        $UiElement.Template
    }
    Write-Host $DisplayText -ForegroundColor $UiElement.Color -NoNewline:$NoNewline
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

    return $GlobalUpdateRules.ExcludeList -contains $ItemName
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

function Assert-AppExecutable {
    foreach ($AppName in $Apps.PSObject.Properties.Name) {
        if ([string]::IsNullOrEmpty($Apps.$AppName.Executable)) {
            Write-UiMessage -UiKey "NoExecutable" -FormatArgs @($AppName)
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
    if (-not [string]::IsNullOrEmpty($GlobalUpdateRules.ApiToken)) {
        $RequestHeaders["Authorization"] = "Bearer $($GlobalUpdateRules.ApiToken)"
    }
    $UniqueRepositoryPaths = @($UpdateTargets.Path) | Select-Object -Unique
    $ReleaseMetadata = @(foreach ($RepositoryPath in $UniqueRepositoryPaths) {
        try {
            $ApiEndpointUri = $GlobalUpdateRules.ApiEndpoint -f $RepositoryPath
            $ApiResponse = Invoke-RestMethod -Uri $ApiEndpointUri -TimeoutSec 15 -Headers $RequestHeaders
            foreach ($Asset in $ApiResponse.assets) {
                [PSCustomObject]@{
                    RepositoryPath = $RepositoryPath
                    PublishedAt    = ([DateTime]::Parse($ApiResponse.published_at, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal)).ToLocalTime()
                    TargetFileName = $Asset.name
                    DownloadUrl    = $Asset.browser_download_url
                    Sha256Hash     = $Asset.digest
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
                Write-UiMessage -UiKey "ApiRequestError" -FormatArgs @($RepositoryPath, $_.Exception.Message)
            }
        }
    })
    return $ReleaseMetadata
}

function Get-LocalFileTimestamp {
    param ([Parameter(Mandatory)] [string]$AppName)

    $LocalFilePath = Join-Path -Path $BaseDirectory -ChildPath $Apps.$AppName.Executable
    if (Test-Path -Path $LocalFilePath -PathType Leaf) {
        $LastWriteTime = (Get-Item -Path $LocalFilePath).LastWriteTime
        return $LastWriteTime.AddMinutes($GlobalUpdateRules.VersionComparison.OffsetMinutes)
    }
    return [DateTime]::MinValue
}

function Select-LatestBuildCandidate {
    param (
        [Parameter(Mandatory)] [array]$ReleaseMetadata,
        [Parameter(Mandatory)] [array]$UpdateTargets
    )

    $Candidates = foreach ($UpdateTarget in $UpdateTargets) {
        if ([string]::IsNullOrEmpty($UpdateTarget.Filter)) {
            Write-UiMessage -UiKey "EmptyFilter" -FormatArgs @($UpdateTarget.Path, $UpdateTarget.AppName)
            continue
        }
        $FilterPattern = if ($UpdateTarget.Filter.Contains('*')) {
            $UpdateTarget.Filter
        } else {
            "*$($UpdateTarget.Filter)*"
        }
        $MatchedBuilds = @(foreach ($Metadata in $ReleaseMetadata) {
            if ($Metadata.RepositoryPath -ne $UpdateTarget.Path -or $Metadata.TargetFileName -notlike $FilterPattern) { continue }
            $FileCategory = Get-FileCategory -FileName $Metadata.TargetFileName
            if ($null -eq $FileCategory) { continue }
            [PSCustomObject]@{
                AppName        = $UpdateTarget.AppName
                RepositoryPath = $Metadata.RepositoryPath
                TargetFileName = $Metadata.TargetFileName
                PublishedAt    = $Metadata.PublishedAt
                DownloadUrl    = $Metadata.DownloadUrl
                Sha256Hash     = $Metadata.Sha256Hash
                FileCategory   = $FileCategory
                Pin            = $UpdateTarget.Pin
                Force          = $UpdateTarget.Force
                FilePath       = $null
            }
        })
        if ($MatchedBuilds.Count -eq 0) {
            Write-UiMessage -UiKey "BuildNotFound" -FormatArgs @($UpdateTarget.Path, $UpdateTarget.Filter)
        }
        $MatchedBuilds
    }
    return @($Candidates | Group-Object -Property AppName | ForEach-Object {
        $Pinned = @($_.Group | Where-Object { $_.Pin })
        $SortSource = if ($Pinned.Count -gt 0) { $Pinned } else { $_.Group }
        $SortSource | Sort-Object -Property PublishedAt -Descending | Select-Object -First 1
    })
}

function Select-BuildChoice {
    param ([Parameter(Mandatory)] [array]$Candidates)

    $GlobalForceUpdate = $GlobalUpdateRules.VersionComparison.ForceUpdate -eq $true
    $BuildChoices = foreach ($Candidate in $Candidates) {
        $LocalFileTime = Get-LocalFileTimestamp -AppName $Candidate.AppName
        $ShouldApply = $LocalFileTime -eq [DateTime]::MinValue -or
                       $GlobalForceUpdate -or $Candidate.Force -or
                       $Candidate.PublishedAt -gt $LocalFileTime
        if ($ShouldApply) {
            Write-UiMessage -UiKey "SelectList" -FormatArgs @($Candidate.AppName, $Candidate.RepositoryPath) -NoNewline
        } else {
            Write-UiMessage -UiKey "NoNewBuild" -FormatArgs @($Candidate.RepositoryPath, $Candidate.PublishedAt.ToString($TimestampFormat)) -NoNewline
        }
        if ($Candidate.Pin) { Write-UiMessage -UiKey "PinTag" -NoNewline }
        if ($Candidate.Force) { Write-UiMessage -UiKey "ForceTag" -NoNewline }
        Write-UiMessage -UiKey "Newline"
        if ($ShouldApply) {
            Write-UiMessage -UiKey "SelectItem" -FormatArgs @($Candidate.TargetFileName, $Candidate.PublishedAt.ToString($TimestampFormat))
            $Candidate
        }
    }
    return @($BuildChoices)
}

function Invoke-FileDownload {
    param ([Parameter(Mandatory)] [array]$BuildChoices)

    $Downloads = foreach ($BuildChoice in $BuildChoices) {
        $TargetDirectory = Join-Path -Path $UpdateDirectory -ChildPath $BuildChoice.AppName
        New-Item -ItemType Directory -Path $TargetDirectory -Force | Out-Null
        $BuildChoice.FilePath = Join-Path -Path $TargetDirectory -ChildPath $BuildChoice.TargetFileName
        $IsSuccess = $true
        try {
            Invoke-WebRequest -Uri $BuildChoice.DownloadUrl -OutFile $BuildChoice.FilePath -ErrorAction Stop
        } catch {
            $IsSuccess = $false
            Write-UiMessage -UiKey "DownloadFail" -FormatArgs @($BuildChoice.TargetFileName)
        }
        Write-UiMessage -UiKey "DownloadListItem" -FormatArgs @($BuildChoice.AppName, $BuildChoice.TargetFileName) -NoNewline
        if ($IsSuccess) {
            Write-UiMessage -UiKey "StatusOk"
            $BuildChoice
        } else {
            Write-UiMessage -UiKey "StatusFail"
        }
    }
    return @($Downloads)
}

function Select-VerifiedDownload {
    param ([array]$Downloads)

    $VerifiedDownloads = foreach ($Download in $Downloads) {
        Write-UiMessage -UiKey "VerifyFileList" -FormatArgs @($Download.TargetFileName)
        $CalculatedFileHash = "sha256:$((Get-FileHash -Path $Download.FilePath -Algorithm SHA256).Hash.ToLower())"
        Write-UiMessage -UiKey "VerifyFileItem" -FormatArgs @($CalculatedFileHash) -NoNewline
        $IsHashMatched = if ([string]::IsNullOrEmpty($Download.Sha256Hash)) {
            Write-UiMessage -UiKey "HashNA"
            $true
        } elseif ($CalculatedFileHash -eq $Download.Sha256Hash) {
            Write-UiMessage -UiKey "HashMatch"
            $true
        } else {
            Write-UiMessage -UiKey "HashMismatch"
            $false
        }
        if ($IsHashMatched) { $Download }
    }
    return @($VerifiedDownloads)
}

function Get-FileCategory {
    param ([Parameter(Mandatory)] [string]$FileName)

    foreach ($Category in "Executable", "Archive") {
        foreach ($Extension in $GlobalUpdateRules.FileTypes.$Category) {
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
    Write-UiMessage -UiKey "Step51PreDeploy" -FormatArgs @($BaseDirectory)
    $CurrentItems = @(Get-ChildItem -Path $BaseDirectory -Force)
    foreach ($CurrentItem in $CurrentItems) {
        if ($CurrentItem.FullName -eq $UpdateDirectory -or (Test-ExcludedItem -ItemName $CurrentItem.Name)) {
            Write-UiMessage -UiKey "SkipExclude" -FormatArgs @($CurrentItem.Name)
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
    Write-UiMessage -UiKey "TimestampSync" -FormatArgs @($Timestamp.ToString($TimestampFormat))
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
            Write-UiMessage -UiKey "SkipExclude" -FormatArgs @($DeployItem.Name)
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
    Write-UiMessage -UiKey "Step52Apply"
    foreach ($VerifiedDownload in $VerifiedDownloads) {
        Write-UiMessage -UiKey "ApplyList" -FormatArgs @($VerifiedDownload.FileCategory, $VerifiedDownload.TargetFileName)
        if ($VerifiedDownload.FileCategory -eq "Executable") {
            Install-Executable -SourcePath $VerifiedDownload.FilePath -Timestamp $VerifiedDownload.PublishedAt
        } elseif ($VerifiedDownload.FileCategory -eq "Archive") {
            if (Expand-ArchiveFile -FilePath $VerifiedDownload.FilePath) {
                Install-ExtractedContent -SourceDirectory (Split-Path -Path $VerifiedDownload.FilePath) -Filters $Apps.($VerifiedDownload.AppName).DeployFilters -FileName $VerifiedDownload.TargetFileName
            } else {
                Write-UiMessage -UiKey "ExtractFail" -FormatArgs @($VerifiedDownload.TargetFileName)
            }
        }
    }
    return $IsFullUpdate
}

function Remove-TemporaryDirectory {
    param ([Parameter(Mandatory)] [array]$BuildChoices)

    $UniqueDirectories = @($BuildChoices | ForEach-Object { Join-Path -Path $UpdateDirectory -ChildPath $_.AppName } | Select-Object -Unique)
    foreach ($DirectoryToRemove in $UniqueDirectories) {
        if (Test-Path -Path $DirectoryToRemove -PathType Container) {
            Remove-Item -Path $DirectoryToRemove -Recurse -Force
            Write-UiMessage -UiKey "RemoveTempDir" -FormatArgs @(Split-Path -Path $DirectoryToRemove -Leaf)
        }
    }
}

function Clear-AppCache {
    param ([Parameter(Mandatory)] [bool]$IsFullUpdate)

    if ($Settings.AppCache.Clear -ne $true) { Write-UiMessage -UiKey "CacheClearOff"; return }
    if (-not $IsFullUpdate) {
        if ($Settings.AppCache.ForceOnPartial -ne $true) { Write-UiMessage -UiKey "CacheClearSkip"; return }
        Write-UiMessage -UiKey "CacheClearForce"
    }
    foreach ($AppCacheDirectory in $AppCacheDirectories) {
        if (Test-Path -Path $AppCacheDirectory -PathType Container) {
            Get-ChildItem -Path $AppCacheDirectory | Remove-Item -Recurse -Force
            Write-UiMessage -UiKey "CacheClearDir" -FormatArgs @(Split-Path -Path $AppCacheDirectory -Leaf)
        }
    }
}

# === Main ===

# [Phase 0] Pre-Flight
Assert-AppExecutable
Stop-RunningProcess
Assert-RequiredPath -Path $BaseDirectory -PathType Container -UiKey "NoBaseDir"
Assert-RequiredPath -Path $UpdateDirectory -PathType Container -UiKey "NoUpdateDir"
Assert-RequiredPath -Path $TarExecutablePath -PathType Leaf -UiKey "NoTar"

# [Phase 1] Flatten Update Targets
$UpdateTargets = @(foreach ($AppProperty in $Apps.PSObject.Properties) {
    foreach ($UpdateTarget in $AppProperty.Value.UpdateTargets) {
        [PSCustomObject]@{
            Pin     = $UpdateTarget.Pin -eq $true
            Path    = $UpdateTarget.Path
            AppName = $AppProperty.Name
            Filter  = $UpdateTarget.Filter
            Force   = $UpdateTarget.Force -eq $true
        }
    }
})

# [Phase 2] Fetch Release Metadata
Write-UiMessage -UiKey "Step1MetaData"
$ReleaseMetadata = Get-ReleaseMetadata -UpdateTargets $UpdateTargets
if ($ReleaseMetadata.Count -eq 0) { Write-UiMessage -UiKey "NoMetaData"; Exit-WithMessage -Fail }
Write-UiMessage -UiKey "FetchList"
$ReleaseMetadata | Select-Object -Property RepositoryPath, PublishedAt -Unique | ForEach-Object {
    Write-UiMessage -UiKey "FetchItem" -FormatArgs @($_.RepositoryPath, $_.PublishedAt.ToString($TimestampFormat))
}

# [Phase 3] Select Update Targets
Write-UiMessage -UiKey "Step2Comparison"
$Candidates = Select-LatestBuildCandidate -ReleaseMetadata $ReleaseMetadata -UpdateTargets $UpdateTargets
$BuildChoices = Select-BuildChoice -Candidates $Candidates
if ($BuildChoices.Count -eq 0) { Write-UiMessage -UiKey "NoUpdateRequired"; Exit-WithMessage -Success }

# [Phase 4] Download, Verify & Deploy
Write-UiMessage -UiKey "Step3Download"
$Downloads = Invoke-FileDownload -BuildChoices $BuildChoices
Write-UiMessage -UiKey "Step4Verification"
$VerifiedDownloads = @(Select-VerifiedDownload -Downloads $Downloads)
if ($VerifiedDownloads.Count -eq 0) {
    Write-UiMessage -UiKey "NoVerifiedBuilds"
    Write-UiMessage -UiKey "Step6TempClear"
    Remove-TemporaryDirectory -BuildChoices $BuildChoices
    Write-UiMessage -UiKey "DownloadAllFail"
    Exit-WithMessage -Fail
}
Write-UiMessage -UiKey "Step5Deploy"
$IsFullUpdate = Invoke-AppUpdate -VerifiedDownloads $VerifiedDownloads
Write-UiMessage -UiKey "Step6TempClear"
Remove-TemporaryDirectory -BuildChoices $BuildChoices
Write-UiMessage -UiKey "Step7CacheClear"
Clear-AppCache -IsFullUpdate $IsFullUpdate
if ($Settings.StartMenu.Create -eq $true) {
    $StartMenuScript = Join-Path -Path $PSScriptRoot -ChildPath $Settings.StartMenu.Script
    if (Test-Path -Path $StartMenuScript -PathType Leaf) {
        & $StartMenuScript
    }
}
Write-UiMessage -UiKey "ProcessDone"
Exit-WithMessage -Success
