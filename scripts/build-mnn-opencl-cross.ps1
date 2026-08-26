param(
    [string]$Distribution = "Ubuntu",
    [string]$SshHost = "rk3588",
    [string]$MnnRef = "3.0.0",
    [string]$WslWorkRoot = "/mnt/d/photo-restore-mnn-opencl",
    [string]$PythonBin = "/home/ljd/miniconda3/envs/photo-restore-videoexport/bin/python",
    [switch]$InstallBuildTools
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$BuildScript = Join-Path $ProjectRoot "scripts\build-mnn-opencl-cross.sh"
$Generator = Join-Path $ProjectRoot "tools\mnn\make_opencl_smoke_onnx.py"
$SmokeSource = Join-Path $ProjectRoot "tools\mnn\mnn_opencl_smoke.cpp"
$RuntimePackager = Join-Path $ProjectRoot "scripts\package-mnn-opencl-runtime.sh"
$CacheDirectory = Join-Path $ProjectRoot "data\video-development\mnn-opencl-cross"
$OutputDirectory = Join-Path $CacheDirectory "output"
$OpenClLibrary = Join-Path $CacheDirectory "libOpenCL.so.1.0.0"
$SshOptions = @("-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3")

foreach ($Path in @($BuildScript, $Generator, $SmokeSource, $RuntimePackager)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required build source is missing: $Path" }
}
foreach ($Command in @("wsl.exe", "ssh", "scp")) {
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) { throw "Required command is unavailable: $Command" }
}
New-Item -ItemType Directory -Force -Path $CacheDirectory, $OutputDirectory | Out-Null

Write-Output "Copying the existing ARM64 OpenCL link library for cross-linking (read-only board access)..."
& scp @SshOptions "${SshHost}:/usr/lib/aarch64-linux-gnu/libOpenCL.so.1.0.0" $OpenClLibrary | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Copying the board OpenCL library failed with exit code $LASTEXITCODE" }

function Convert-ToWslPath([string]$WindowsPath) {
    if ($WindowsPath -notmatch '^(?<drive>[A-Za-z]):\\(?<path>.*)$') { throw "Unsupported Windows path: $WindowsPath" }
    return "/mnt/$($Matches.drive.ToLowerInvariant())/$($Matches.path.Replace('\', '/'))"
}

$WslProjectRoot = Convert-ToWslPath $ProjectRoot
$WslOutput = Convert-ToWslPath $OutputDirectory
$WslOpenCl = Convert-ToWslPath $OpenClLibrary
$WslBuildScript = Convert-ToWslPath $BuildScript
$Install = if ($InstallBuildTools) { "true" } else { "false" }

Write-Output "Building pinned MNN $MnnRef in isolated WSL paths..."
Write-Output "Board packages and production services will not be changed."
$WslPythonBin = $PythonBin
Write-Output "Using WSL Python: $WslPythonBin"
& wsl.exe -d $Distribution -- env PYTHON_BIN=$WslPythonBin bash $WslBuildScript $WslProjectRoot $WslOutput $MnnRef $Install $WslOpenCl $WslWorkRoot
if ($LASTEXITCODE -ne 0) {
    $Hint = if (-not $InstallBuildTools) { " Rerun with -InstallBuildTools if the output reports a missing compiler or build dependency." } else { "" }
    throw "The isolated MNN OpenCL cross-build failed with exit code $LASTEXITCODE.$Hint"
}

foreach ($Name in @("libMNN.so", "mnn-opencl-smoke", "mnn-opencl-smoke.mnn", "build-record.json", "runtime-record.json", "SHA256SUMS")) {
    $Path = Join-Path $OutputDirectory $Name
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Expected cross-build artifact is missing: $Path" }
}
$BuildRecord = Get-Content -Raw -LiteralPath (Join-Path $OutputDirectory "build-record.json") | ConvertFrom-Json
if (-not $BuildRecord.opencl -or $BuildRecord.separate_backend) {
    throw "The MNN build record does not confirm an embedded OpenCL backend."
}
foreach ($Name in @("ld-linux-aarch64.so.1", "libc.so.6", "libm.so.6", "libmvec.so.1", "libstdc++.so.6", "libgcc_s.so.1", "libdl.so.2", "libpthread.so.0", "librt.so.1")) {
    $Path = Join-Path $OutputDirectory "runtime\$Name"
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Expected isolated ARM64 runtime artifact is missing: $Path" }
}
Write-Output "Output: $OutputDirectory"
Write-Output "Board upload: False"
Write-Output "RESULT=PASS_MNN_OPENCL_CROSS_BUILD_DEPLOY"
