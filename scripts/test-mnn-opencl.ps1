param(
    [string]$SshHost = "rk3588",
    [string]$Distribution = "Ubuntu",
    [switch]$Cleanup
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$ArtifactDirectory = Join-Path $ProjectRoot "data\video-development\mnn-opencl-cross\output"
$OpenClLibrary = Join-Path $ProjectRoot "data\video-development\mnn-opencl-cross\libOpenCL.so.1.0.0"
$ReportDirectory = Join-Path $ProjectRoot "benchmarks\mnn-opencl-smoke"
$OutputReport = Join-Path $ReportDirectory "latest.txt"
$RuntimePackager = Join-Path $ProjectRoot "scripts\package-mnn-opencl-runtime.sh"
$RemoteRoot = "/userdata/photo-restore-v2/data/video-development/mnn-opencl-smoke"
$SshOptions = @("-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3")

foreach ($Command in @("ssh", "scp", "wsl.exe")) {
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
if (-not (Test-Path -LiteralPath $RuntimePackager -PathType Leaf)) {
    throw "Required runtime packager is missing: $RuntimePackager"
}
if (-not (Test-Path -LiteralPath $OpenClLibrary -PathType Leaf)) {
    throw "The cached board OpenCL loader is missing: $OpenClLibrary. Run scripts\build-mnn-opencl-cross.ps1 once to refresh it."
}

function Convert-ToWslPath([string]$WindowsPath) {
    if ($WindowsPath -notmatch '^(?<drive>[A-Za-z]):\\(?<path>.*)$') { throw "Unsupported Windows path: $WindowsPath" }
    return "/mnt/$($Matches.drive.ToLowerInvariant())/$($Matches.path.Replace('\', '/'))"
}

$RuntimeNames = @(
    "ld-linux-aarch64.so.1",
    "libc.so.6",
    "libm.so.6",
    "libmvec.so.1",
    "libstdc++.so.6",
    "libgcc_s.so.1",
    "libdl.so.2",
    "libpthread.so.0",
    "librt.so.1"
)
$RuntimeDirectory = Join-Path $ArtifactDirectory "runtime"
$RuntimeRecord = Join-Path $ArtifactDirectory "runtime-record.json"
$BuildRecordPath = Join-Path $ArtifactDirectory "build-record.json"
$BuildRecord = Get-Content -Raw -LiteralPath $BuildRecordPath | ConvertFrom-Json
if (-not $BuildRecord.opencl -or $BuildRecord.separate_backend) {
    throw "The existing MNN artifact does not contain the required embedded OpenCL backend. Rebuild it with scripts\build-mnn-opencl-cross.ps1."
}
$RuntimeMissing = -not (Test-Path -LiteralPath $RuntimeRecord -PathType Leaf)
foreach ($Name in $RuntimeNames) {
    if (-not (Test-Path -LiteralPath (Join-Path $RuntimeDirectory $Name) -PathType Leaf)) {
        $RuntimeMissing = $true
    }
}
if ($RuntimeMissing) {
    Write-Output "Packaging an isolated ARM64 runtime compatible with the existing cross-build..."
    $WslPackager = Convert-ToWslPath $RuntimePackager
    $WslArtifactDirectory = Convert-ToWslPath $ArtifactDirectory
    & wsl.exe -d $Distribution -- bash $WslPackager $WslArtifactDirectory
    if ($LASTEXITCODE -ne 0) { throw "Packaging the isolated ARM64 runtime failed with exit code $LASTEXITCODE" }
}

New-Item -ItemType Directory -Force -Path $ReportDirectory | Out-Null
$ManifestPath = Join-Path $ReportDirectory "SHA256SUMS-upload"
$UploadFiles = @(
    @{ Local = (Join-Path $ArtifactDirectory "libMNN.so"); Remote = "libMNN.so" },
    @{ Local = (Join-Path $ArtifactDirectory "mnn-opencl-smoke"); Remote = "mnn-opencl-smoke" },
    @{ Local = (Join-Path $ArtifactDirectory "mnn-opencl-smoke.mnn"); Remote = "mnn-opencl-smoke.mnn" },
    @{ Local = (Join-Path $ArtifactDirectory "build-record.json"); Remote = "build-record.json" },
    @{ Local = $RuntimeRecord; Remote = "runtime-record.json" },
    # MNN 3.0.0 only probes the unversioned Linux name.  The Debian board
    # exposes libOpenCL.so.1, so upload the same verified board library under
    # an isolated alias instead of creating a system-wide symlink.
    @{ Local = $OpenClLibrary; Remote = "libOpenCL.so" }
)
foreach ($Name in $RuntimeNames) {
    $UploadFiles += @{ Local = (Join-Path $RuntimeDirectory $Name); Remote = "runtime/$Name" }
}
$OpenClPlugin = Join-Path $ArtifactDirectory "libMNN_CL.so"
if (Test-Path -LiteralPath $OpenClPlugin -PathType Leaf) {
    $UploadFiles += @{ Local = $OpenClPlugin; Remote = "libMNN_CL.so" }
}
foreach ($File in $UploadFiles) {
    if (-not (Test-Path -LiteralPath $File.Local -PathType Leaf)) {
        throw "Required MNN OpenCL upload artifact is missing: $($File.Local)"
    }
}
$ManifestLines = foreach ($File in $UploadFiles | Where-Object { $_.Remote -ne "build-record.json" }) {
    $LocalPath = $File.Local
    $Hash = (Get-FileHash -LiteralPath $LocalPath -Algorithm SHA256).Hash.ToLowerInvariant()
    "$Hash  $($File.Remote)"
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
& ssh @SshOptions $SshHost "umask 077; mkdir -p '$RemoteRoot'; find '$RemoteRoot' -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; mkdir -p '$RemoteRoot/runtime'"
if ($LASTEXITCODE -ne 0) { throw "Preparing the isolated board directory failed with exit code $LASTEXITCODE" }
foreach ($File in $UploadFiles) {
    & scp @SshOptions $File.Local "${SshHost}:${RemoteRoot}/$($File.Remote)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Uploading $($File.Remote) failed with exit code $LASTEXITCODE" }
}
& scp @SshOptions $ManifestPath "${SshHost}:${RemoteRoot}/SHA256SUMS" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Uploading the generated checksum manifest failed with exit code $LASTEXITCODE" }

Write-Output "Running MNN with the Mali OpenCL backend..."
$RemoteCommand = @"
set -eu
cd '$RemoteRoot'
sha256sum --strict -c SHA256SUMS
chmod 700 mnn-opencl-smoke
chmod 755 runtime/ld-linux-aarch64.so.1
test -s libOpenCL.so
export MNN_OPENCL_BUFFER_CLOSED=0
if [ -f ./libMNN_CL.so ]; then
    export LD_PRELOAD='$RemoteRoot/libMNN_CL.so'
fi
./runtime/ld-linux-aarch64.so.1 \
    --library-path '${RemoteRoot}/runtime:${RemoteRoot}:/usr/lib/aarch64-linux-gnu:/lib/aarch64-linux-gnu' \
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
    'BACKEND_TYPE=3',
    'MISMATCHES=0',
    'NON_FINITE=0',
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
