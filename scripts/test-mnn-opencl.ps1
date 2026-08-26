param(
    [string]$SshHost = "rk3588",
    [switch]$Cleanup
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$ArtifactDirectory = Join-Path $ProjectRoot "data\video-development\mnn-opencl-cross\output"
$ReportDirectory = Join-Path $ProjectRoot "benchmarks\mnn-opencl-smoke"
$OutputReport = Join-Path $ReportDirectory "latest.txt"
$RemoteRoot = "/userdata/photo-restore-v2/data/video-development/mnn-opencl-smoke"
$SshOptions = @("-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3")

foreach ($Command in @("ssh", "scp")) {
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) { throw "Required command is unavailable: $Command" }
}

if ($Cleanup) {
    Write-Output "Removing only the isolated MNN OpenCL smoke directory..."
    & ssh @SshOptions $SshHost "case '$RemoteRoot' in /userdata/photo-restore-v2/data/video-development/mnn-opencl-smoke) rm -rf -- '$RemoteRoot' ;; *) exit 91 ;; esac"
    if ($LASTEXITCODE -ne 0) { throw "Cleaning the isolated MNN OpenCL directory failed with exit code $LASTEXITCODE" }
    Write-Output "RESULT=PASS_MNN_OPENCL_SMOKE_CLEANUP"
    exit 0
}

$Artifacts = @("libMNN.so", "mnn-opencl-smoke", "mnn-opencl-smoke.mnn", "build-record.json")
foreach ($Name in $Artifacts) {
    $Path = Join-Path $ArtifactDirectory $Name
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required cross-build artifact is missing: $Path. Run scripts\build-mnn-opencl-cross.ps1 first."
    }
}
New-Item -ItemType Directory -Force -Path $ReportDirectory | Out-Null
$ManifestPath = Join-Path $ReportDirectory "SHA256SUMS-upload"
$ManifestLines = foreach ($Name in @("libMNN.so", "mnn-opencl-smoke", "mnn-opencl-smoke.mnn")) {
    $LocalPath = Join-Path $ArtifactDirectory $Name
    $Hash = (Get-FileHash -LiteralPath $LocalPath -Algorithm SHA256).Hash.ToLowerInvariant()
    "$Hash  $Name"
}
# The manifest is uploaded to Linux.  Set-Content emits CRLF on Windows,
# which makes sha256sum treat the trailing carriage return as part of each
# filename.  Write an explicit LF-only ASCII file instead.
$ManifestText = ($ManifestLines -join "`n") + "`n"
[System.IO.File]::WriteAllText(
    $ManifestPath,
    $ManifestText,
    [System.Text.UTF8Encoding]::new($false)
)

Write-Output "Checking production services before isolated MNN OpenCL inference..."
$Safety = @(& ssh @SshOptions $SshHost "printf 'api='; systemctl is-active photo-restore-api.service; printf 'tunnel='; systemctl is-active cloudflared.service; printf 'workers='; pgrep -fc '/userdata/photo-restore-v2.*([r]estore_image.py|[r]ife|[m]nn-opencl-smoke)' || true" 2>&1)
if ($LASTEXITCODE -ne 0) { throw "Reading the production safety state failed.`n$($Safety -join "`n")" }
$SafetyText = ($Safety | ForEach-Object { "$_" }) -join "`n"
if ($SafetyText -notmatch '(?m)^api=active$' -or $SafetyText -notmatch '(?m)^tunnel=active$') {
    throw "Production services are not healthy; MNN inference was not started.`n$SafetyText"
}
if ($SafetyText -match '(?m)^workers=(?<count>\d+)$' -and [int]$Matches.count -gt 0) {
    throw "A media worker is active; MNN inference was not started.`n$SafetyText"
}

Write-Output "Preparing the isolated board directory and uploading verified artifacts..."
& ssh @SshOptions $SshHost "umask 077; mkdir -p '$RemoteRoot'; find '$RemoteRoot' -mindepth 1 -maxdepth 1 -type f -delete"
if ($LASTEXITCODE -ne 0) { throw "Preparing the isolated board directory failed with exit code $LASTEXITCODE" }
foreach ($Name in $Artifacts) {
    & scp @SshOptions (Join-Path $ArtifactDirectory $Name) "${SshHost}:${RemoteRoot}/${Name}" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Uploading $Name failed with exit code $LASTEXITCODE" }
}
& scp @SshOptions $ManifestPath "${SshHost}:${RemoteRoot}/SHA256SUMS" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Uploading the generated checksum manifest failed with exit code $LASTEXITCODE" }

Write-Output "Running MNN with the Mali OpenCL backend..."
$RemoteCommand = @"
set -eu
cd '$RemoteRoot'
sha256sum --strict -c SHA256SUMS
chmod 700 mnn-opencl-smoke
# Keep this safe under `set -u`: the board service environment may not define
# LD_LIBRARY_PATH before the isolated test starts.
export LD_LIBRARY_PATH='$RemoteRoot':`${LD_LIBRARY_PATH:-}
export MNN_OPENCL_BUFFER_CLOSED=0
./mnn-opencl-smoke ./mnn-opencl-smoke.mnn
printf 'api_after='; systemctl is-active photo-restore-api.service
printf 'tunnel_after='; systemctl is-active cloudflared.service
"@
$PreviousPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    $Lines = @(& ssh @SshOptions $SshHost $RemoteCommand 2>&1)
    $Code = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $PreviousPreference
}
$Text = ($Lines | ForEach-Object { "$_" }) -join "`n"
$Text | Set-Content -LiteralPath $OutputReport -Encoding utf8
if ($Code -ne 0) { throw "The MNN OpenCL framework smoke test failed with exit code $Code.`n$Text" }
foreach ($Required in @(
    'BACKEND=OPENCL',
    'MISMATCHES=0',
    'RESULT=PASS_MNN_OPENCL_FRAMEWORK_SMOKE',
    'api_after=active',
    'tunnel_after=active'
)) {
    if ($Text -notmatch "(?m)^$([regex]::Escape($Required))$") {
        throw "The MNN OpenCL smoke output is missing '$Required'.`n$Text"
    }
}

Write-Output $Text
Write-Output "Report: $OutputReport"
Write-Output "Board packages changed: False"
Write-Output "RESULT=PASS_MNN_OPENCL_FRAMEWORK_SMOKE_DEPLOY"
