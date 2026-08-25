param(
    [string]$Distribution = "Ubuntu",
    [string]$SshHost = "rk3588"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$LocalArtifacts = Join-Path $ProjectRoot "models\validation"
$LocalProbe = Join-Path $ProjectRoot "apps\worker\rknn_probe.py"
$LinuxRoot = "/home/ljd/photo-restore-rknn232"
$RemoteRoot = "/userdata/photo-restore-v2"

function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Command,
        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE"
    }
}

New-Item -ItemType Directory -Force -Path $LocalArtifacts | Out-Null

Invoke-NativeChecked {
    wsl -d $Distribution -- bash -lc "cp '${LinuxRoot}/models/rknn/realesrgan_x4plus_tile64_fp16.rknn' '/mnt/c/Users/LJD/rk/photo-restore-v2/models/validation/' && cp '${LinuxRoot}/workspace/samples/tile64-input.npy' '/mnt/c/Users/LJD/rk/photo-restore-v2/models/validation/' && cp '${LinuxRoot}/workspace/samples/tile64-onnx-output.npy' '/mnt/c/Users/LJD/rk/photo-restore-v2/models/validation/' && cp '${LinuxRoot}/workspace/samples/tile64-fixture.json' '/mnt/c/Users/LJD/rk/photo-restore-v2/models/validation/'"
} "Copying WSL validation artifacts"

Invoke-NativeChecked {
    ssh $SshHost "mkdir -p '${RemoteRoot}/models' '${RemoteRoot}/data/validation' '${RemoteRoot}/repo'"
} "Creating remote validation directories"

$LocalModel = Join-Path $LocalArtifacts "realesrgan_x4plus_tile64_fp16.rknn"
$LocalModelHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $LocalModel).Hash.ToLowerInvariant()
$RemoteModel = "${RemoteRoot}/models/realesrgan_x4plus_tile64_fp16.rknn"
$RemoteModelTemporary = "${RemoteModel}.uploading"
$RemoteModelHash = (& ssh $SshHost "if [ -f '${RemoteModel}' ]; then sha256sum '${RemoteModel}' | cut -d ' ' -f 1; fi").Trim()
if ($LASTEXITCODE -ne 0) {
    throw "Reading remote model checksum failed with exit code $LASTEXITCODE"
}

if ($RemoteModelHash -eq $LocalModelHash) {
    Write-Output "Model checksum matches; upload skipped: $LocalModelHash"
} else {
    Write-Output "Uploading model to a temporary path..."
    Invoke-NativeChecked {
        scp $LocalModel "${SshHost}:${RemoteModelTemporary}"
    } "Uploading RKNN model"
    Invoke-NativeChecked {
        ssh $SshHost "actual=`$(sha256sum '${RemoteModelTemporary}' | cut -d ' ' -f 1); test \"`$actual\" = '${LocalModelHash}' && mv -f '${RemoteModelTemporary}' '${RemoteModel}'"
    } "Verifying and activating RKNN model"
}

Invoke-NativeChecked {
    scp (Join-Path $LocalArtifacts "tile64-input.npy") "${SshHost}:${RemoteRoot}/data/validation/"
} "Uploading validation input"
Invoke-NativeChecked {
    scp (Join-Path $LocalArtifacts "tile64-onnx-output.npy") "${SshHost}:${RemoteRoot}/data/validation/"
} "Uploading validation reference"
Invoke-NativeChecked {
    scp (Join-Path $LocalArtifacts "tile64-fixture.json") "${SshHost}:${RemoteRoot}/data/validation/"
} "Uploading validation manifest"
Invoke-NativeChecked {
    scp $LocalProbe "${SshHost}:${RemoteRoot}/repo/rknn_probe.py"
} "Uploading RKNN probe"

Invoke-NativeChecked {
    ssh $SshHost "chmod 755 '${RemoteRoot}/repo/rknn_probe.py' && '${RemoteRoot}/venv/bin/python' '${RemoteRoot}/repo/rknn_probe.py' --model '${RemoteRoot}/models/realesrgan_x4plus_tile64_fp16.rknn' --input '${RemoteRoot}/data/validation/tile64-input.npy' --reference '${RemoteRoot}/data/validation/tile64-onnx-output.npy' --runs 5"
} "Running board RKNN validation"
