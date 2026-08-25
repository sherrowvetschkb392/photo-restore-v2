param(
    [ValidateScript({ $_ -ge 64 -and $_ -le 128 -and $_ % 16 -eq 0 })]
    [int]$TileSize = 96,
    [int]$Runs = 5,
    [string]$Distribution = "Ubuntu",
    [string]$CondaEnvironment = "photo-restore-rknn232",
    [string]$LinuxRoot = "/home/ljd/photo-restore-rknn232",
    [string]$SshHost = "rk3588"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$PrepareScript = Join-Path $PSScriptRoot "prepare-wsl-export.ps1"
$StageScript = Join-Path $PSScriptRoot "stage-board-validation.ps1"
$Prefix = "realesrgan_x4plus_tile${TileSize}"
$Onnx = "${LinuxRoot}/models/onnx/${Prefix}.onnx"
$Rknn = "${LinuxRoot}/models/rknn/${Prefix}_fp16.rknn"
$Reports = "${LinuxRoot}/workspace/reports"
$Samples = "${LinuxRoot}/workspace/samples"
$Scripts = "${LinuxRoot}/workspace/scripts"
$Weights = "${LinuxRoot}/models/source/RealESRGAN_x4plus.pth"
$WslPipeline = "${LinuxRoot}/workspace/scripts/wsl-model-pipeline.sh"
$SshOptions = @("-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3")

function Invoke-NativeChecked {
    param([scriptblock]$Command, [string]$Description)
    Write-Output "`n== $Description =="
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE"
    }
}

foreach ($RequiredCommand in @("wsl", "ssh", "scp", "powershell.exe")) {
    if (-not (Get-Command $RequiredCommand -ErrorAction SilentlyContinue)) {
        throw "Required command is unavailable: $RequiredCommand"
    }
}

Invoke-NativeChecked {
    wsl -d $Distribution -- bash -lc "test -f '${Weights}'"
} "Check WSL and source weights"

Invoke-NativeChecked {
    ssh @SshOptions $SshHost "test -x '/userdata/photo-restore-v2/venv/bin/python' && test -f '/usr/lib/librknnrt.so'"
} "Check RK3588 SSH and RKNN runtime"

Invoke-NativeChecked {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PrepareScript -Distribution $Distribution
} "Synchronize model tools to WSL"

Invoke-NativeChecked {
    wsl -d $Distribution -- bash $WslPipeline $LinuxRoot $CondaEnvironment $TileSize
} "Export, preflight, compile and create reference data"

Invoke-NativeChecked {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $StageScript -Distribution $Distribution -SshHost $SshHost -TileSize $TileSize -Runs $Runs -LinuxRoot $LinuxRoot
} "Deploy and validate on RK3588"

Write-Output "`nRESULT=PASS_END_TO_END_MODEL_PIPELINE"
