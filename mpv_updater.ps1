# ==============================================================================
# SECTION 1. Configuration & Environment
# ==============================================================================

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

$Settings = Import-JsonFile -FilePath (Join-Path -Path $PSScriptRoot -ChildPath "settings.json")
$UiTemplates = Import-JsonFile -FilePath (Join-Path -Path $PSScriptRoot -ChildPath "ui_templates.json")

$Apps = $Settings.Apps
$GlobalUpdateRules = $Settings.GlobalUpdateRules
$BaseDirectory = [Environment]::ExpandEnvironmentVariables($Settings.Environment.Paths.BaseDirectory)
$UpdateDirectory = [Environment]::ExpandEnvironmentVariables($Settings.Environment.Paths.UpdateDirectory)
$AppCacheDirectories = @($Settings.Environment.Paths.AppCacheDirectories) | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_) }
$ZipExecutablePath = [Environment]::ExpandEnvironmentVariables($Settings.Environment.ZipExecutablePath)
$FileExtensions = $GlobalUpdateRules.FileTypes.Executable + $GlobalUpdateRules.FileTypes.Archive
$ExtensionPattern = ($FileExtensions | ForEach-Object { [Regex]::Escape($_) }) -join '|'

$ErrorActionPreference = $Settings.ErrorActionPreference
$ProgressPreference = $Settings.ProgressPreference

# ==============================================================================
# SECTION 2. Functions
# ==============================================================================

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
    param ([string]$UiKey)

    if ($UiKey) { Write-UiMessage -UiKey $UiKey }
    [System.Media.SystemSounds]::Hand.Play()
    Write-UiMessage -UiKey "PressEnterExit"
    $null = Read-Host
    exit
}

function Test-IsExcludedItem {
    param ([Parameter(Mandatory)] [string]$ItemName)

    foreach ($Pattern in $GlobalUpdateRules.ExcludeList) {
        if ($ItemName -like "*$Pattern*") { return $true }
    }
    return $false
}

function Test-RequiredPath {
    param (
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$PathType,
        [Parameter(Mandatory)] [string]$UiKey
    )

    if (-not (Test-Path -Path $Path -PathType $PathType)) {
        Write-UiMessage -UiKey $UiKey -FormatArgs @($Path)
        Exit-WithMessage
    }
}

function Test-RunningProcess {
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
            Exit-WithMessage
        }
        foreach ($RunningProcess in $RunningProcesses) {
            Stop-Process -Id $RunningProcess.Process.Id -Force
        }
        Write-UiMessage -UiKey "ProceedUpdate"
    }
}

function Get-ReleaseMetadata {
    param ([Parameter(Mandatory)] [array]$UpdateTargets)

    $UniqueRepositoryPaths = @($UpdateTargets.Path) | Select-Object -Unique
    $ReleaseMetadata = @(foreach ($RepositoryPath in $UniqueRepositoryPaths) {
        try {
            $ApiEndpointUri = $GlobalUpdateRules.ApiEndpoint -f $RepositoryPath
            $ApiResponse = Invoke-RestMethod -Uri $ApiEndpointUri -Method Get -TimeoutSec 15
            if ($null -eq $ApiResponse.assets) { continue }
            foreach ($Asset in $ApiResponse.assets) {
                [PSCustomObject]@{
                    RepoPath       = $RepositoryPath
                    PublishedAt    = [DateTime]::Parse($ApiResponse.published_at, [System.Globalization.CultureInfo]::InvariantCulture)
                    TargetFileName = $Asset.name
                    DownloadUrl    = $Asset.browser_download_url
                    Sha256Hash     = $Asset.digest
                }
            }
        } catch {
            if ($_.Exception.Response.StatusCode -eq [System.Net.HttpStatusCode]::Forbidden) {
                Exit-WithMessage -UiKey "ApiLimitError"
            } else {
                Write-UiMessage -UiKey "ApiRequestError" -FormatArgs @($RepositoryPath, $_.Exception.Message)
            }
        }
    })
    return $ReleaseMetadata
}

function Get-LocalBuildTimestamp {
    param ([Parameter(Mandatory)] [string]$Category)

    if ([string]::IsNullOrEmpty($Apps.$Category.Executable)) {
        Write-UiMessage -UiKey "NoExecutable" -FormatArgs @($Category)
        Exit-WithMessage
    }
    $LocalFilePath = Join-Path -Path $BaseDirectory -ChildPath $Apps.$Category.Executable
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

    if ($null -eq $ReleaseMetadata -or $ReleaseMetadata.Count -eq 0) { return @() }
    $Candidates = foreach ($UpdateTarget in $UpdateTargets) {
        $MatchedBuilds = @($ReleaseMetadata) | Where-Object {
            $_.RepoPath -eq $UpdateTarget.Path -and
            $_.TargetFileName -like "*$($UpdateTarget.Filter)*" -and
            $_.TargetFileName -match "($ExtensionPattern)$"
        }
        if ($MatchedBuilds.Count -eq 0) {
            Write-UiMessage -UiKey "BuildNotFound" -FormatArgs @($UpdateTarget.Path, $UpdateTarget.Filter)
        }
        foreach ($MatchedBuild in $MatchedBuilds) {
            $MatchedBuild | Select-Object -Property *,
                @{Name="Category";Expression={$UpdateTarget.Category}},
                @{Name="Pin";Expression={$UpdateTarget.Pin}},
                @{Name="Force";Expression={$UpdateTarget.Force}}
        }
    }
    return @($Candidates | Group-Object -Property Category | ForEach-Object {
        $Pinned = @($_.Group | Where-Object { $_.Pin })
        $SortSource = if ($Pinned.Count -gt 0) { $Pinned } else { $_.Group }
        $SortSource | Sort-Object -Property PublishedAt -Descending | Select-Object -First 1
    })
}

function Select-UpdateTarget {
    param ([Parameter(Mandatory)] [array]$Candidates)

    $GlobalForceUpdate = $GlobalUpdateRules.VersionComparison.ForceUpdate -eq $true
    $FinalSelection = foreach ($Candidate in $Candidates) {
        $LocalFileTime = Get-LocalBuildTimestamp -Category $Candidate.Category
        $ShouldApply = $LocalFileTime -eq [DateTime]::MinValue -or
                       $GlobalForceUpdate -or $Candidate.Force -or
                       $Candidate.PublishedAt -gt $LocalFileTime
        if ($ShouldApply) {
            Write-UiMessage -UiKey "SelectList" -FormatArgs @($Candidate.Category, $Candidate.RepoPath) -NoNewline
        } else {
            Write-UiMessage -UiKey "NoNewBuild" -FormatArgs @($Candidate.RepoPath, $Candidate.PublishedAt.ToString("yyyy-MM-dd HH:mm:ss")) -NoNewline
        }
        if ($Candidate.Pin) { Write-UiMessage -UiKey "PinTag" -NoNewline }
        if ($Candidate.Force) { Write-UiMessage -UiKey "ForceTag" -NoNewline }
        Write-UiMessage -UiKey "Newline"
        if ($ShouldApply) {
            Write-UiMessage -UiKey "SelectItem" -FormatArgs @($Candidate.TargetFileName, $Candidate.PublishedAt.ToString("yyyy-MM-dd HH:mm:ss"))
            $Candidate
        }
    }
    return @($FinalSelection)
}

function Invoke-FileDownload {
    param ([Parameter(Mandatory)] [array]$BuildChoices)

    $DownloadResults = foreach ($BuildChoice in $BuildChoices) {
        $TargetDirectory = Join-Path -Path $UpdateDirectory -ChildPath $BuildChoice.Category
        if (-not (Test-Path -Path $TargetDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $TargetDirectory -Force | Out-Null
        }
        $FullFilePath = Join-Path -Path $TargetDirectory -ChildPath $BuildChoice.TargetFileName
        $TaskStatus = [PSCustomObject]@{
            Path         = $FullFilePath
            ExpectedHash = $BuildChoice.Sha256Hash
            Category     = $BuildChoice.Category
            Info         = $BuildChoice
            IsSuccess    = $false
            FileName     = $BuildChoice.TargetFileName
        }
        try {
            Invoke-WebRequest -Uri $BuildChoice.DownloadUrl -OutFile $FullFilePath -ErrorAction Stop
            $TaskStatus.IsSuccess = $true
        } catch {
            Write-UiMessage -UiKey "DownloadFail" -FormatArgs @($BuildChoice.TargetFileName)
        }
        Write-UiMessage -UiKey "DownloadListItem" -FormatArgs @($TaskStatus.Category, $TaskStatus.FileName) -NoNewline
        if ($TaskStatus.IsSuccess) { Write-UiMessage -UiKey "StatusOk" } else { Write-UiMessage -UiKey "StatusFail" }
        $TaskStatus
    }
    return @($DownloadResults)
}

function Test-FileIntegrity {
    param ([Parameter(Mandatory)] [array]$DownloadTasks)

    $VerifiedTasks = foreach ($DownloadTask in ($DownloadTasks | Where-Object { $_.IsSuccess })) {
        Write-UiMessage -UiKey "VerifyFileList" -FormatArgs @($DownloadTask.FileName)
        $CalculatedFileHash = "sha256:$((Get-FileHash -Path $DownloadTask.Path -Algorithm SHA256).Hash.ToLower())"
        Write-UiMessage -UiKey "VerifyFileItem" -FormatArgs @($CalculatedFileHash) -NoNewline
        $IsHashMatched = if ([string]::IsNullOrEmpty($DownloadTask.ExpectedHash)) {
            Write-UiMessage -UiKey "HashNA"
            $true
        } elseif ($CalculatedFileHash -eq $DownloadTask.ExpectedHash) {
            Write-UiMessage -UiKey "HashMatch"
            $true
        } else {
            Write-UiMessage -UiKey "HashMismatch"
            $false
        }
        if ($IsHashMatched) { $DownloadTask }
    }
    return @($VerifiedTasks)
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
    & $ZipExecutablePath x "$FilePath" "-o$ParentDirectory" -y -bb0 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Remove-PreviousInstallation {
    Write-UiMessage -UiKey "Step51PreDeploy" -FormatArgs @($BaseDirectory)
    $CurrentItems = @(Get-ChildItem -Path $BaseDirectory -Force)
    foreach ($CurrentItem in $CurrentItems) {
        if ($CurrentItem.FullName -eq $UpdateDirectory -or (Test-IsExcludedItem -ItemName $CurrentItem.Name)) {
            Write-UiMessage -UiKey "SkipExclude" -FormatArgs @($CurrentItem.Name)
            continue
        }
        Remove-Item -Path $CurrentItem.FullName -Recurse -Force
    }
}

function Install-SingleExecutable {
    param (
        [Parameter(Mandatory)] [string]$SourcePath,
        [Parameter(Mandatory)] [DateTime]$Timestamp
    )

    $FileName = Split-Path -Path $SourcePath -Leaf
    $DestinationPath = Join-Path -Path $BaseDirectory -ChildPath $FileName
    Move-Item -Path $SourcePath -Destination $DestinationPath -Force
    Write-UiMessage -UiKey "Moved" -FormatArgs @($FileName)
    (Get-Item -Path $DestinationPath).LastWriteTime = $Timestamp
    Write-UiMessage -UiKey "TimestampSync" -FormatArgs @($Timestamp.ToString("yyyy-MM-dd HH:mm:ss"))
}

function Install-ExtractedContent {
    param (
        [Parameter(Mandatory)] [string]$SourceDirectory,
        [array]$Filters,
        [string]$FileName
    )

    $SearchDirectory = $SourceDirectory
    $SubDirectories = @(Get-ChildItem -Path $SourceDirectory -Directory)
    $SubFiles = @(Get-ChildItem -Path $SourceDirectory -File) | Where-Object { $_.Name -ne $FileName }
    if ($SubDirectories.Count -eq 1 -and $SubFiles.Count -eq 0) {
        $SearchDirectory = $SubDirectories.FullName
    }
    $DeployItems = if ($Filters -and $Filters.Count -gt 0) {
        foreach ($Filter in $Filters) {
            @(Get-ChildItem -Path $SearchDirectory -Filter $Filter -Recurse)
        }
    } else {
        @(Get-ChildItem -Path $SearchDirectory) | Where-Object { $_.Name -ne $FileName }
    }
    foreach ($DeployItem in $DeployItems) {
        if (Test-IsExcludedItem -ItemName $DeployItem.Name) {
            Write-UiMessage -UiKey "SkipExclude" -FormatArgs @($DeployItem.Name)
            continue
        }
        $DestinationItemPath = Join-Path -Path $BaseDirectory -ChildPath $DeployItem.Name
        if (Test-Path -Path $DestinationItemPath) {
            Remove-Item -Path $DestinationItemPath -Recurse -Force
        }
        Move-Item -Path $DeployItem.FullName -Destination $DestinationItemPath -Force
        if ($Filters -and $Filters.Count -gt 0) {
            Write-UiMessage -UiKey "MovedFiltered" -FormatArgs @($DeployItem.Name)
        } else {
            Write-UiMessage -UiKey "MovedFullStructure" -FormatArgs @($DeployItem.Name)
        }
    }
}

function Invoke-AppUpdate {
    [OutputType([bool])]
    param ([Parameter(Mandatory)] [array]$VerifiedTasks)

    $ExistingExecutableCount = 0
    foreach ($CategoryName in $Apps.PSObject.Properties.Name) {
        $ExecutablePath = Join-Path -Path $BaseDirectory -ChildPath $Apps.$CategoryName.Executable
        if (Test-Path -Path $ExecutablePath -PathType Leaf) { $ExistingExecutableCount++ }
    }
    $IsFullUpdate = (($VerifiedTasks.Count -eq $Apps.PSObject.Properties.Name.Count) -or ($ExistingExecutableCount -eq 0))
    if ($IsFullUpdate) {
        Write-UiMessage -UiKey "FullUpdate"
        Remove-PreviousInstallation
    } else {
        Write-UiMessage -UiKey "PartialUpdate"
    }
    Write-UiMessage -UiKey "Step52Apply"
    foreach ($VerifiedTask in $VerifiedTasks) {
        $FileCategory = Get-FileCategory -FileName $VerifiedTask.FileName
        $Filters = $Apps.($VerifiedTask.Info.Category).DeployFilters
        if ($FileCategory -eq "Executable") {
            Write-UiMessage -UiKey "ApplyList" -FormatArgs @("File", $VerifiedTask.FileName)
            Install-SingleExecutable -SourcePath $VerifiedTask.Path -Timestamp $VerifiedTask.Info.PublishedAt
        } elseif ($FileCategory -eq "Archive") {
            Write-UiMessage -UiKey "ApplyList" -FormatArgs @("Archive", $VerifiedTask.FileName)
            if (Expand-ArchiveFile -FilePath $VerifiedTask.Path) {
                Install-ExtractedContent -SourceDirectory (Split-Path -Path $VerifiedTask.Path) -Filters $Filters -FileName $VerifiedTask.FileName
            } else {
                Write-UiMessage -UiKey "ExtractFail" -FormatArgs @($VerifiedTask.FileName)
            }
        }
    }
    return $IsFullUpdate
}

function Remove-TemporaryDirectory {
    param ([array]$DownloadTasks)

    if ($null -eq $DownloadTasks) { return }
    $UniqueDirectories = @($DownloadTasks | ForEach-Object { Split-Path -Path $_.Path -Parent } | Select-Object -Unique)
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

# ==============================================================================
# SECTION 3. Main
# ==============================================================================

# [Phase 0] Pre-Flight
Test-RunningProcess
Test-RequiredPath -Path $BaseDirectory -PathType Container -UiKey "NoBaseDir"
Test-RequiredPath -Path $UpdateDirectory -PathType Container -UiKey "NoUpdateDir"
Test-RequiredPath -Path $ZipExecutablePath -PathType Leaf -UiKey "NoZip"

# [Phase 1] Flatten Update Targets
$UpdateTargets = @(foreach ($AppProperty in $Apps.PSObject.Properties) {
    foreach ($UpdateTarget in $AppProperty.Value.UpdateTargets) {
        [PSCustomObject]@{
            Pin      = $UpdateTarget.Pin -eq $true
            Path     = $UpdateTarget.Path
            Category = $AppProperty.Name
            Filter   = $UpdateTarget.Filter
            Force    = $UpdateTarget.Force -eq $true
        }
    }
})

# [Phase 2] Fetch Release Metadata
Write-UiMessage -UiKey "Step1MetaData"
$ReleaseMetadata = Get-ReleaseMetadata -UpdateTargets $UpdateTargets
if ($ReleaseMetadata.Count -eq 0) { Exit-WithMessage -UiKey "NoMetaData" }
Write-UiMessage -UiKey "FetchList"
$ReleaseMetadata | Select-Object -Property RepoPath, PublishedAt -Unique | ForEach-Object {
    Write-UiMessage -UiKey "FetchItem" -FormatArgs @($_.RepoPath, $_.PublishedAt.ToString("yyyy-MM-dd HH:mm:ss"))
}

# [Phase 3] Select Update Targets
Write-UiMessage -UiKey "Step2Comparison"
$Candidates = Select-LatestBuildCandidate -ReleaseMetadata $ReleaseMetadata -UpdateTargets $UpdateTargets
$BuildChoices = Select-UpdateTarget -Candidates $Candidates
if ($BuildChoices.Count -eq 0) { Exit-WithMessage -UiKey "NoUpdateRequired" }

# [Phase 4] Download, Verify & Deploy
Write-UiMessage -UiKey "Step3Download"
$DownloadTasks = Invoke-FileDownload -BuildChoices $BuildChoices
Write-UiMessage -UiKey "Step4Verification"
$VerifiedTasks = @(Test-FileIntegrity -DownloadTasks $DownloadTasks)
$IsFullUpdate = $false
if ($VerifiedTasks.Count -gt 0) {
    Write-UiMessage -UiKey "Step5Deploy"
    $IsFullUpdate = Invoke-AppUpdate -VerifiedTasks $VerifiedTasks
} else {
    Write-UiMessage -UiKey "NoVerifiedBuilds"
}
Write-UiMessage -UiKey "Step6TempClear"
Remove-TemporaryDirectory -DownloadTasks $DownloadTasks
if ($VerifiedTasks.Count -gt 0) {
    Write-UiMessage -UiKey "Step7CacheClear"
    Clear-AppCache -IsFullUpdate $IsFullUpdate
    Write-UiMessage -UiKey "ProcessDone"
} else {
    Write-UiMessage -UiKey "DownloadAllFail"
}

# [Phase 5] Exit
Exit-WithMessage
