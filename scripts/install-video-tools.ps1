param(
    [string]$SshHost = "rk3588",
    [string]$RemoteRoot = "/userdata/photo-restore-v2",
    [string]$SimulationInputFile,
    [switch]$Install,
    [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$SafeFixture = Join-Path $ProjectRoot "tests\fixtures\apt-ffmpeg-simulate-safe.txt"
$UnsafeFixture = Join-Path $ProjectRoot "tests\fixtures\apt-ffmpeg-simulate-unsafe.txt"
$ProtectedChangeFixture = Join-Path $ProjectRoot "tests\fixtures\apt-ffmpeg-simulate-protected-change.txt"
$ReportDirectory = Join-Path $ProjectRoot "benchmarks\video-preflight"
$PlanReportPath = Join-Path $ReportDirectory "ffmpeg-install-plan.json"
$DpkgVersionFormat = '${Version}'
$ProtectedPackageNames = @(
    "gstreamer1.0-rockchip1",
    "librockchip-mpp1",
    "librockchip-mpp-dev"
)
$SshOptions = @(
    "-o", "ConnectTimeout=10",
    "-o", "ServerAliveInterval=15",
    "-o", "ServerAliveCountMax=3"
)

function Assert-SafeRemoteRoot {
    param([string]$Path)
    if ($Path -ne "/userdata/photo-restore-v2") {
        throw "RemoteRoot must remain the isolated project root: /userdata/photo-restore-v2"
    }
}

function Invoke-SshCapture {
    param([string]$RemoteCommand, [string]$Description)
    if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
        throw "Required command is unavailable: ssh"
    }
    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $Lines = @(& ssh @SshOptions $SshHost $RemoteCommand 2>&1)
        $Code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $Previous
    }
    if ($Code -ne 0) {
        throw "$Description failed with exit code $Code`n$($Lines -join "`n")"
    }
    return (($Lines | ForEach-Object { "$_" }) -join "`n").Trim()
}

function ConvertFrom-AptSimulation {
    param([string]$Text, [string]$Source)

    $Installed = [System.Collections.Generic.List[string]]::new()
    $Removed = [System.Collections.Generic.List[string]]::new()
    $Configured = [System.Collections.Generic.List[string]]::new()
    foreach ($Line in $Text -split "`r?`n") {
        if ($Line -match '^Inst\s+(?<package>[A-Za-z0-9.+:-]+)(?:\s|$)') {
            $Installed.Add($Matches.package)
        } elseif ($Line -match '^Remv\s+(?<package>[A-Za-z0-9.+:-]+)(?:\s|$)') {
            $Removed.Add($Matches.package)
        } elseif ($Line -match '^Conf\s+(?<package>[A-Za-z0-9.+:-]+)(?:\s|$)') {
            $Configured.Add($Matches.package)
        }
    }
    $Summary = $null
    foreach ($Line in $Text -split "`r?`n") {
        if ($Line -match '^\d+ upgraded, \d+ newly installed, \d+ to remove') {
            $Summary = $Line.Trim()
        }
    }
    $UniqueInstalled = @($Installed | Select-Object -Unique)
    $UniqueRemoved = @($Removed | Select-Object -Unique)
    $HasFfmpeg = @($UniqueInstalled | Where-Object { $_ -eq "ffmpeg" }).Count -gt 0
    $ProtectedChanges = @($UniqueInstalled | Where-Object { $ProtectedPackageNames -contains $_ })
    $Safe = $UniqueRemoved.Count -eq 0 -and $ProtectedChanges.Count -eq 0
    $Blockers = [System.Collections.Generic.List[string]]::new()
    if (-not $HasFfmpeg) { $Blockers.Add("ffmpeg_not_in_install_plan") }
    if ($UniqueRemoved.Count -gt 0) { $Blockers.Add("apt_plan_removes_packages") }
    if ($ProtectedChanges.Count -gt 0) { $Blockers.Add("apt_plan_changes_protected_packages") }

    return [ordered]@{
        schema_version = 1
        checked_at_utc = [DateTime]::UtcNow.ToString("o")
        source = $Source
        safe = $Safe -and $HasFfmpeg
        ffmpeg_planned = $HasFfmpeg
        summary = $Summary
        install_or_upgrade_packages = $UniqueInstalled
        configure_packages = @($Configured | Select-Object -Unique)
        remove_packages = $UniqueRemoved
        protected_package_changes = $ProtectedChanges
        blockers = @($Blockers)
    }
}

function Test-ProtectedPackages {
    param([string]$Text)
    $Values = [ordered]@{}
    foreach ($Line in $Text -split "`r?`n") {
        if ($Line -match '^(?<key>[a-z0-9_]+)=(?<value>.*)$') {
            $Values[$Matches.key] = $Matches.value.Trim()
        }
    }
    foreach ($Key in @("gstreamer_rockchip", "rockchip_mpp", "rockchip_mpp_dev")) {
        if (-not $Values.Contains($Key) -or $Values[$Key] -eq "missing") {
            throw "Protected Rockchip package is missing before installation: $Key"
        }
    }
    return $Values
}

Assert-SafeRemoteRoot $RemoteRoot
if ($ValidateOnly -and ($Install -or $SimulationInputFile)) {
    throw "-ValidateOnly cannot be combined with -Install or -SimulationInputFile"
}
if ($Install -and $SimulationInputFile) {
    throw "-Install cannot be combined with -SimulationInputFile"
}

if ($ValidateOnly) {
    $SafePlan = ConvertFrom-AptSimulation (Get-Content -LiteralPath $SafeFixture -Raw) "fixture:safe"
    if (-not $SafePlan.safe -or -not $SafePlan.ffmpeg_planned -or $SafePlan.remove_packages.Count -ne 0) {
        throw "Safe apt fixture was not accepted"
    }
    $UnsafePlan = ConvertFrom-AptSimulation (Get-Content -LiteralPath $UnsafeFixture -Raw) "fixture:unsafe"
    if ($UnsafePlan.safe -or $UnsafePlan.remove_packages.Count -lt 1 -or -not ($UnsafePlan.blockers -contains "apt_plan_removes_packages")) {
        throw "Unsafe apt fixture was not rejected"
    }
    $ProtectedChangePlan = ConvertFrom-AptSimulation (Get-Content -LiteralPath $ProtectedChangeFixture -Raw) "fixture:protected-change"
    if ($ProtectedChangePlan.safe -or $ProtectedChangePlan.protected_package_changes.Count -lt 1 -or -not ($ProtectedChangePlan.blockers -contains "apt_plan_changes_protected_packages")) {
        throw "Protected-package change fixture was not rejected"
    }
    Write-Output "RESULT=PASS_VIDEO_TOOLS_INSTALLER_VALIDATION"
    return
}

if ($SimulationInputFile) {
    $ResolvedInput = (Resolve-Path -LiteralPath $SimulationInputFile).Path
    $Plan = ConvertFrom-AptSimulation (Get-Content -LiteralPath $ResolvedInput -Raw) "file:$ResolvedInput"
    Write-Output "Source: $ResolvedInput"
    Write-Output "Safe: $($Plan.safe); ffmpeg planned=$($Plan.ffmpeg_planned); removals=$($Plan.remove_packages.Count)"
    if ($Plan.remove_packages.Count) { Write-Output "Remove packages: $($Plan.remove_packages -join ', ')" }
    Write-Output "RESULT=PASS_VIDEO_TOOLS_PLAN_PARSE"
    return
}

Write-Output "Checking whether ffmpeg and ffprobe are already installed..."
$Existing = Invoke-SshCapture `
    "export LC_ALL=C LANG=C; if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then printf 'installed=true\n'; ffmpeg -version | sed -n '1p'; ffprobe -version | sed -n '1p'; else printf 'installed=false\n'; fi" `
    "Checking existing video tools"
if ($Existing -match '(?m)^installed=true$') {
    Write-Output $Existing
    Write-Output "Video tools are already installed; no package operation is required."
    & (Join-Path $PSScriptRoot "video-preflight.ps1") -SshHost $SshHost -RemoteRoot $RemoteRoot
    if ($LASTEXITCODE -ne 0) { throw "Video preflight failed after detecting existing tools" }
    Write-Output "RESULT=PASS_VIDEO_TOOLS_ALREADY_INSTALLED"
    return
}

Write-Output "Recording protected Rockchip package versions..."
$ProtectedBeforeText = Invoke-SshCapture `
    "export LC_ALL=C LANG=C; printf 'gstreamer_rockchip='; dpkg-query -W -f='$DpkgVersionFormat' gstreamer1.0-rockchip1 2>/dev/null || printf missing; printf '\nrockchip_mpp='; dpkg-query -W -f='$DpkgVersionFormat' librockchip-mpp1 2>/dev/null || printf missing; printf '\nrockchip_mpp_dev='; dpkg-query -W -f='$DpkgVersionFormat' librockchip-mpp-dev 2>/dev/null || printf missing; printf '\n'" `
    "Checking protected Rockchip packages"
$ProtectedBefore = Test-ProtectedPackages $ProtectedBeforeText

Write-Output "Simulating the Debian ffmpeg package transaction..."
$Simulation = Invoke-SshCapture `
    "export LC_ALL=C LANG=C DEBIAN_FRONTEND=noninteractive; sudo -n apt-get -s --no-remove install ffmpeg" `
    "Simulating the ffmpeg installation"
$Plan = ConvertFrom-AptSimulation $Simulation "ssh:$SshHost"
New-Item -ItemType Directory -Force -Path $ReportDirectory | Out-Null
$Plan | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $PlanReportPath -Encoding utf8

Write-Output "APT plan: $($Plan.summary)"
Write-Output "Install/upgrade packages: $($Plan.install_or_upgrade_packages -join ', ')"
Write-Output "Remove packages: $(if ($Plan.remove_packages.Count) { $Plan.remove_packages -join ', ' } else { 'none' })"
Write-Output "Protected package changes: $(if ($Plan.protected_package_changes.Count) { $Plan.protected_package_changes -join ', ' } else { 'none' })"
Write-Output "Plan report: $PlanReportPath"
if (-not $Plan.safe) {
    throw "The simulated apt transaction is unsafe: $($Plan.blockers -join ', '). No packages were changed."
}

if (-not $Install) {
    Write-Output "Simulation is safe. Review the plan above, then rerun with -Install to perform the package installation."
    Write-Output "RESULT=PASS_VIDEO_TOOLS_INSTALL_PLAN"
    return
}

Write-Output "Installing the Debian ffmpeg package after the verified no-removal simulation..."
Invoke-SshCapture `
    "export LC_ALL=C LANG=C DEBIAN_FRONTEND=noninteractive; sudo -n apt-get --no-remove -y install ffmpeg" `
    "Installing ffmpeg"
Write-Output "Verifying ffmpeg, ffprobe and protected Rockchip packages..."
$Verification = Invoke-SshCapture `
    "export LC_ALL=C LANG=C; command -v ffmpeg; command -v ffprobe; ffmpeg -version | sed -n '1p'; ffprobe -version | sed -n '1p'; printf 'gstreamer_rockchip='; dpkg-query -W -f='$DpkgVersionFormat' gstreamer1.0-rockchip1; printf '\nrockchip_mpp='; dpkg-query -W -f='$DpkgVersionFormat' librockchip-mpp1; printf '\nrockchip_mpp_dev='; dpkg-query -W -f='$DpkgVersionFormat' librockchip-mpp-dev; printf '\n'" `
    "Verifying installed video tools"
Write-Output $Verification
$ProtectedAfter = Test-ProtectedPackages $Verification
foreach ($Key in @("gstreamer_rockchip", "rockchip_mpp", "rockchip_mpp_dev")) {
    if ($ProtectedAfter[$Key] -ne $ProtectedBefore[$Key]) {
        throw "Protected Rockchip package version changed unexpectedly: $Key ($($ProtectedBefore[$Key]) -> $($ProtectedAfter[$Key]))"
    }
}

Write-Output "Rerunning the read-only video capability preflight..."
& (Join-Path $PSScriptRoot "video-preflight.ps1") -SshHost $SshHost -RemoteRoot $RemoteRoot
if ($LASTEXITCODE -ne 0) { throw "Video preflight failed after installing ffmpeg" }
Write-Output "RESULT=PASS_VIDEO_TOOLS_INSTALL"
