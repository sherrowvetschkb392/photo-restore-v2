param(
    [string]$ArchivePath = "D:\atk_dlrk3588_linux6.12_sdk_release_v1.0.0_20260820.tar.gz",
    [string]$KnownIssuesPath = "D:\当前版本（v1.0.0）已知问题汇总.txt",
    [int]$RecommendedFreeSpaceGB = 150,
    [switch]$SkipWslCheck
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$ReportDirectory = Join-Path $ProjectRoot "benchmarks\linux612-sdk-preflight"
$JsonReport = Join-Path $ReportDirectory "latest.json"
$ExpectedRoot = "atk_dlrk3588_linux6.12/"
$ExpectedConfig = "device/rockchip/rk3588/06_atk_dlrk3588_ubuntu_panthor_auto2mipi_2hdmi_defconfig"
$ExpectedOldBoard = 'RK_TARGET_BOARD="ATK-DLRK3588"'
$ExpectedNewBoard = 'RK_TARGET_BOARD="ATK-DLRK3588-PANTHOR"'

foreach ($Path in @($ArchivePath, $KnownIssuesPath)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file is missing: $Path"
    }
}
if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
    throw "Required command is unavailable: tar"
}
if ($RecommendedFreeSpaceGB -lt 1) {
    throw "RecommendedFreeSpaceGB must be positive."
}

$Archive = Get-Item -LiteralPath $ArchivePath
$KnownIssues = Get-Content -LiteralPath $KnownIssuesPath -Raw
$KnownIssueMatches =
    $KnownIssues.Contains($ExpectedConfig) -and
    $KnownIssues.Contains($ExpectedOldBoard) -and
    $KnownIssues.Contains($ExpectedNewBoard)

Write-Output "Inspecting the Linux 6.12 SDK archive without extracting it..."
$ArchiveRootFound = $false
$ReadmeFound = $false
$RepoScriptFound = $false
$Ubuntu2404RootfsFound = $false
$Ubuntu2604RootfsFound = $false
$PrebuiltImages = [System.Collections.Generic.List[string]]::new()

& tar -tf $ArchivePath | ForEach-Object {
    $Entry = "$_"
    if ($Entry -eq $ExpectedRoot) { $ArchiveRootFound = $true }
    if ($Entry -eq "${ExpectedRoot}README.md") { $ReadmeFound = $true }
    if ($Entry -eq "${ExpectedRoot}repo.sh") { $RepoScriptFound = $true }
    if ($Entry -eq "${ExpectedRoot}ubuntu/ubuntu-desktop-24.04.4-arm64.tar.gz") { $Ubuntu2404RootfsFound = $true }
    if ($Entry -eq "${ExpectedRoot}ubuntu/ubuntu-desktop-26.04-arm64.tar.gz") { $Ubuntu2604RootfsFound = $true }
    if ($Entry -match '(?i)\.(img|img\.gz|wic|wic\.gz)$') { $PrebuiltImages.Add($Entry) }
}
if ($LASTEXITCODE -ne 0) {
    throw "Reading the SDK archive failed with exit code $LASTEXITCODE"
}

$Readme = if ($ReadmeFound) {
    (& tar -xOf $ArchivePath "${ExpectedRoot}README.md") -join "`n"
} else {
    ""
}
if ($LASTEXITCODE -ne 0) {
    throw "Reading README.md from the SDK archive failed with exit code $LASTEXITCODE"
}
$Linux612Declared = $Readme -match '(?i)RK3588 Linux 6\.12 SDK'
$LocalRepoCheckoutDeclared = $Readme -match '(?i)repo\.sh'

$ArchiveDrive = Split-Path -Qualifier $Archive.FullName
$ArchiveDriveName = $ArchiveDrive.TrimEnd('\').TrimEnd(':')
$ArchivePsDrive = Get-PSDrive -Name $ArchiveDriveName -PSProvider FileSystem -ErrorAction Stop
$ArchiveDriveFreeGB = [math]::Round($ArchivePsDrive.Free / 1GB, 2)
$ArchiveSizeGB = [math]::Round($Archive.Length / 1GB, 2)
$BuildSpaceReady = $ArchiveDriveFreeGB -ge $RecommendedFreeSpaceGB

$Wsl = [ordered]@{
    checked = -not $SkipWslCheck
    available = $false
    distributions = @()
    note = if ($SkipWslCheck) { "check_skipped" } else { "not_checked" }
}
if (-not $SkipWslCheck) {
    $WslCommand = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $WslCommand) {
        $Wsl.note = "wsl.exe_not_found"
    } else {
        $PreviousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $WslLines = @(& wsl.exe -l -q 2>&1 | ForEach-Object { "$_".Trim([char]0).Trim() } | Where-Object { $_ })
            $WslCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $PreviousPreference
        }
        if ($WslCode -eq 0) {
            $Wsl.available = $true
            $Wsl.distributions = $WslLines
            $Wsl.note = if ($WslLines.Count) { "ready_for_linux_build_environment_review" } else { "no_distribution_registered" }
        } else {
            $Wsl.note = "wsl_query_failed_exit_$WslCode"
        }
    }
}

$Blockers = [System.Collections.Generic.List[string]]::new()
if (-not $ArchiveRootFound -or -not $ReadmeFound -or -not $RepoScriptFound) { $Blockers.Add("unexpected_sdk_archive_layout") }
if (-not $Linux612Declared) { $Blockers.Add("linux612_identity_not_verified") }
if (-not $KnownIssueMatches) { $Blockers.Add("known_issue_document_does_not_match_expected_panthor_fix") }
if (-not $Ubuntu2604RootfsFound) { $Blockers.Add("ubuntu2604_rootfs_fixture_missing") }
if (-not $BuildSpaceReady) { $Blockers.Add("insufficient_free_space_for_full_sdk_build") }
if (-not $SkipWslCheck -and -not $Wsl.available) { $Blockers.Add("wsl_build_environment_unavailable") }

$Assessment = if ($Blockers.Count) {
    "BLOCKED_BEFORE_FULL_EXTRACTION"
} else {
    "READY_FOR_ISOLATED_SDK_CHECKOUT"
}

New-Item -ItemType Directory -Force -Path $ReportDirectory | Out-Null
$Report = [ordered]@{
    schema_version = 1
    checked_at_utc = [DateTime]::UtcNow.ToString("o")
    assessment = $Assessment
    board_changed = $false
    archive = [ordered]@{
        path = $Archive.FullName
        bytes = $Archive.Length
        size_gib = $ArchiveSizeGB
        expected_root_found = $ArchiveRootFound
        readme_found = $ReadmeFound
        repo_script_found = $RepoScriptFound
        declares_linux_6_12 = [bool]$Linux612Declared
        declares_local_repo_checkout = [bool]$LocalRepoCheckoutDeclared
        ubuntu_24_04_rootfs_found = $Ubuntu2404RootfsFound
        ubuntu_26_04_rootfs_found = $Ubuntu2604RootfsFound
        prebuilt_images = @($PrebuiltImages)
    }
    known_issue = [ordered]@{
        path = (Get-Item -LiteralPath $KnownIssuesPath).FullName
        matches_expected_panthor_fix = $KnownIssueMatches
        config = $ExpectedConfig
        replace = $ExpectedOldBoard
        with = $ExpectedNewBoard
    }
    storage = [ordered]@{
        archive_drive = $ArchiveDrive
        free_gib = $ArchiveDriveFreeGB
        recommended_free_gib = $RecommendedFreeSpaceGB
        ready = $BuildSpaceReady
        recommendation = "Use a native Linux/WSL ext4 filesystem with at least $RecommendedFreeSpaceGB GiB free; do not build under /mnt/c or /mnt/d."
    }
    wsl = $Wsl
    migration = [ordered]@{
        target = "Ubuntu 26.04 + Linux 6.12 + Panthor"
        destructive_actions_authorized = $false
        first_boot_target = "separate removable media"
        preserve_current_production_disk = $true
        validation_order = @("network_and_ssh", "vulkaninfo", "mali_g610_panthor", "ncnn_vulkan", "rife_ncnn_vulkan", "rknn2_realesrgan", "mpp_codec", "rga", "production_service_rehearsal")
    }
    blockers = @($Blockers)
}
$Report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $JsonReport -Encoding utf8

Write-Output "SDK: Linux 6.12 identity=$Linux612Declared; Ubuntu 26.04 rootfs=$Ubuntu2604RootfsFound"
Write-Output "Known Panthor fix: $KnownIssueMatches"
Write-Output "Prebuilt disk images in archive: $($PrebuiltImages.Count)"
Write-Output "Storage: $ArchiveDriveFreeGB GiB free on $ArchiveDrive; recommended=$RecommendedFreeSpaceGB GiB"
Write-Output "WSL: checked=$($Wsl.checked); available=$($Wsl.available); note=$($Wsl.note)"
Write-Output "Assessment: $Assessment"
if ($Blockers.Count) { Write-Output "Blockers: $($Blockers -join ', ')" }
Write-Output "Report: $JsonReport"
Write-Output "Board changed: False"
Write-Output "RESULT=PASS_LINUX612_SDK_PREFLIGHT"

