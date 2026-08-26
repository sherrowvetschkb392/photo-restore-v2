param(
    [string]$Distribution = "Ubuntu",
    [string]$SshHost = "rk3588",
    [string]$MnnRef = "3.0.0",
    [string]$WslWorkRoot = "/mnt/d/photo-restore-mnn-opencl",
    [switch]$InstallBuildTools
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$BuildScript = Join-Path $ProjectRoot "scripts\build-mnn-opencl-cross.sh"
$Generator = Join-Path $ProjectRoot "tools\mnn\make_opencl_smoke_onnx.py"
$SmokeSource = Join-Path $ProjectRoot "tools\mnn\mnn_opencl_smoke.cpp"
$CacheDirectory = Join-Path $ProjectRoot "data\video-development\mnn-opencl-cross"
$OutputDirectory = Join-Path $CacheDirectory "output"
$OpenClLibrary = Join-Path $CacheDirectory "libOpenCL.so.1.0.0"
$SshOptions = @("-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3")

foreach ($Path in @($BuildScript, $Generator, $SmokeSource)) {
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
& wsl.exe -d $Distribution -- bash $WslBuildScript $WslProjectRoot $WslOutput $MnnRef $Install $WslOpenCl $WslWorkRoot
if ($LASTEXITCODE -ne 0) {
    $Hint = if (-not $InstallBuildTools) { " Rerun with -InstallBuildTools if the output reports a missing compiler or build dependency." } else { "" }
    throw "The isolated MNN OpenCL cross-build failed with exit code $LASTEXITCODE.$Hint"
}

foreach ($Name in @("libMNN.so", "mnn-opencl-smoke", "mnn-opencl-smoke.mnn", "build-record.json", "SHA256SUMS")) {
    $Path = Join-Path $OutputDirectory $Name
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Expected cross-build artifact is missing: $Path" }
}
Write-Output "Output: $OutputDirectory"
Write-Output "Board upload: False"
Write-Output "RESULT=PASS_MNN_OPENCL_CROSS_BUILD_DEPLOY"
