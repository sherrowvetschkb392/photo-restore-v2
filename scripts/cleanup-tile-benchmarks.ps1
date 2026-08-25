param(
    [string]$Distribution = "Ubuntu",
    [string]$LinuxRoot = "/home/ljd/photo-restore-rknn232",
    [string]$SshHost = "rk3588",
    [string]$RemoteRoot = "/userdata/photo-restore-v2"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$SshOptions = @("-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3")
$CleanupHelper = Join-Path $PSScriptRoot "cleanup-benchmark-artifacts.sh"

function Assert-ExactRoot([string]$Actual, [string]$Expected, [string]$Label) {
    if ($Actual -ne $Expected) {
        throw "$Label root mismatch. Expected '$Expected', got '$Actual'"
    }
}

function Invoke-NativeChecked([scriptblock]$Command, [string]$Description) {
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE"
    }
}

function Convert-ToWslPath([string]$WindowsPath) {
    if ($WindowsPath -notmatch '^(?<drive>[A-Za-z]):\\(?<path>.*)$') {
        throw "Unsupported Windows path: $WindowsPath"
    }
    $Drive = $Matches['drive'].ToLowerInvariant()
    $RelativePath = $Matches['path'].Replace('\', '/')
    return "/mnt/${Drive}/${RelativePath}"
}

Write-Output "Checking cleanup boundaries and required tile96 artifacts..."
Assert-ExactRoot $ProjectRoot "C:\Users\LJD\rk\photo-restore-v2" "Windows"
Assert-ExactRoot $LinuxRoot "/home/ljd/photo-restore-rknn232" "WSL"
Assert-ExactRoot $RemoteRoot "/userdata/photo-restore-v2" "RK3588"
if (-not (Test-Path -LiteralPath $CleanupHelper -PathType Leaf)) {
    throw "Cleanup helper missing: $CleanupHelper"
}
$WslCleanupHelper = Convert-ToWslPath (Resolve-Path -LiteralPath $CleanupHelper).Path

Invoke-NativeChecked {
    wsl -d $Distribution -- bash -lc "set -e; test -f '${LinuxRoot}/models/source/RealESRGAN_x4plus.pth'; test -f '${LinuxRoot}/models/onnx/realesrgan_x4plus_tile96.onnx'; test -f '${LinuxRoot}/models/rknn/realesrgan_x4plus_tile96_fp16.rknn'; test -f '${LinuxRoot}/workspace/samples/tile96-input.npy'; test -f '${LinuxRoot}/workspace/samples/tile96-onnx-output.npy'"
} "Checking WSL tile96 artifacts"

Invoke-NativeChecked {
    ssh @SshOptions $SshHost "set -e; test -f '${RemoteRoot}/models/realesrgan_x4plus_tile96_fp16.rknn'; test -x '${RemoteRoot}/venv/bin/python'"
} "Checking RK3588 tile96 artifacts"

Write-Output "Cleaning Windows deployment cache and compiler intermediates..."
$WindowsTargets = @(
    (Join-Path $ProjectRoot "models\validation"),
    (Join-Path $ProjectRoot "check0_base_optimize.onnx"),
    (Join-Path $ProjectRoot "check3_fuse_ops.onnx")
)
foreach ($Target in $WindowsTargets) {
    $FullTarget = [System.IO.Path]::GetFullPath($Target)
    if (-not $FullTarget.StartsWith($ProjectRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing Windows cleanup outside project root: $FullTarget"
    }
    if (Test-Path -LiteralPath $FullTarget) {
        Remove-Item -LiteralPath $FullTarget -Recurse -Force
        Write-Output "Removed: $FullTarget"
    }
}

Write-Output "Cleaning non-selected WSL tile artifacts..."
Invoke-NativeChecked {
    wsl -d $Distribution -- bash $WslCleanupHelper wsl $LinuxRoot
} "Cleaning WSL benchmark artifacts"

Write-Output "Cleaning non-selected RK3588 tile artifacts..."
$RemoteCleanupHelper = "${RemoteRoot}/repo/cleanup-benchmark-artifacts.sh"
Invoke-NativeChecked {
    scp @SshOptions $CleanupHelper "${SshHost}:${RemoteCleanupHelper}"
} "Uploading RK3588 cleanup helper"
Invoke-NativeChecked {
    ssh @SshOptions $SshHost "chmod 755 '${RemoteCleanupHelper}' && bash '${RemoteCleanupHelper}' board '${RemoteRoot}'"
} "Cleaning RK3588 benchmark artifacts"

Write-Output ""
Write-Output "Cleanup completed. Preserved tile96 artifacts and all reports."
Write-Output "RESULT=PASS_TILE_BENCHMARK_CLEANUP"
