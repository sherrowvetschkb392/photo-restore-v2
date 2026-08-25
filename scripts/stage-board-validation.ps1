param(
    [string]$Distribution = "Ubuntu",
    [string]$SshHost = "rk3588",
    [ValidateScript({ $_ -ge 64 -and $_ -le 128 -and $_ % 16 -eq 0 })]
    [int]$TileSize = 64,
    [int]$Runs = 5,
    [string]$LinuxRoot = "/home/ljd/photo-restore-rknn232",
    [string]$RemoteRoot = "/userdata/photo-restore-v2"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$LocalArtifacts = Join-Path $ProjectRoot "models\validation"
$LocalBenchmarks = Join-Path $ProjectRoot "benchmarks"
$LocalProbe = Join-Path $ProjectRoot "apps\worker\rknn_probe.py"
$ModelName = "realesrgan_x4plus_tile${TileSize}_fp16.rknn"
$InputName = "tile${TileSize}-input.npy"
$ReferenceName = "tile${TileSize}-onnx-output.npy"
$FixtureName = "tile${TileSize}-fixture.json"
$ReportName = "tile${TileSize}-board-report.json"
$SshOptions = @("-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3")

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

function Invoke-NativeRetry {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Command,
        [Parameter(Mandatory = $true)]
        [string]$Description,
        [int]$Attempts = 3
    )

    for ($Attempt = 1; $Attempt -le $Attempts; $Attempt++) {
        & $Command
        if ($LASTEXITCODE -eq 0) {
            return
        }
        if ($Attempt -eq $Attempts) {
            throw "$Description failed after $Attempts attempts; last exit code $LASTEXITCODE"
        }
        Write-Warning "$Description failed on attempt $Attempt; retrying..."
        Start-Sleep -Seconds (2 * $Attempt)
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

New-Item -ItemType Directory -Force -Path $LocalArtifacts | Out-Null
New-Item -ItemType Directory -Force -Path $LocalBenchmarks | Out-Null
$WslArtifacts = Convert-ToWslPath (Resolve-Path -LiteralPath $LocalArtifacts).Path

Invoke-NativeChecked {
    wsl -d $Distribution -- bash -lc "cp '${LinuxRoot}/models/rknn/${ModelName}' '${WslArtifacts}/' && cp '${LinuxRoot}/workspace/samples/${InputName}' '${WslArtifacts}/' && cp '${LinuxRoot}/workspace/samples/${ReferenceName}' '${WslArtifacts}/' && cp '${LinuxRoot}/workspace/samples/${FixtureName}' '${WslArtifacts}/'"
} "Copying WSL validation artifacts"

Invoke-NativeChecked {
    ssh @SshOptions $SshHost "mkdir -p '${RemoteRoot}/models' '${RemoteRoot}/data/validation' '${RemoteRoot}/repo' '${RemoteRoot}/benchmarks'"
} "Creating remote validation directories"

$LocalModel = Join-Path $LocalArtifacts $ModelName
$LocalModelHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $LocalModel).Hash.ToLowerInvariant()
$RemoteModel = "${RemoteRoot}/models/${ModelName}"
$RemoteModelTemporary = "${RemoteModel}.uploading"
$RemoteModelHashOutput = & ssh @SshOptions $SshHost "if [ -f '${RemoteModel}' ]; then sha256sum '${RemoteModel}' | cut -d ' ' -f 1; fi"
if ($LASTEXITCODE -ne 0) {
    throw "Reading remote model checksum failed with exit code $LASTEXITCODE"
}
if ($null -eq $RemoteModelHashOutput) {
    $RemoteModelHash = ""
} else {
    $RemoteModelHash = (($RemoteModelHashOutput | ForEach-Object { "$_" }) -join "").Trim()
}

if ($RemoteModelHash -eq $LocalModelHash) {
    Write-Output "Model checksum matches; upload skipped: $LocalModelHash"
} else {
    $RemoteTemporaryHashOutput = & ssh @SshOptions $SshHost "if [ -f '${RemoteModelTemporary}' ]; then sha256sum '${RemoteModelTemporary}' | cut -d ' ' -f 1; fi"
    if ($LASTEXITCODE -ne 0) {
        throw "Reading temporary model checksum failed with exit code $LASTEXITCODE"
    }
    if ($null -eq $RemoteTemporaryHashOutput) {
        $RemoteTemporaryHash = ""
    } else {
        $RemoteTemporaryHash = (($RemoteTemporaryHashOutput | ForEach-Object { "$_" }) -join "").Trim()
    }

    if ($RemoteTemporaryHash -eq $LocalModelHash) {
        Write-Output "Temporary upload checksum matches; resuming activation: $LocalModelHash"
    } else {
        Write-Output "Uploading model to a temporary path..."
        Invoke-NativeRetry {
            scp @SshOptions $LocalModel "${SshHost}:${RemoteModelTemporary}"
        } "Uploading RKNN model"
    }

    $VerifiedTemporaryHashOutput = & ssh @SshOptions $SshHost "sha256sum '${RemoteModelTemporary}' | cut -d ' ' -f 1"
    if ($LASTEXITCODE -ne 0) {
        throw "Verifying temporary model checksum failed with exit code $LASTEXITCODE"
    }
    $VerifiedTemporaryHash = (($VerifiedTemporaryHashOutput | ForEach-Object { "$_" }) -join "").Trim()
    if ($VerifiedTemporaryHash -ne $LocalModelHash) {
        throw "Temporary model checksum mismatch: expected $LocalModelHash, got $VerifiedTemporaryHash"
    }

    Invoke-NativeChecked {
        ssh @SshOptions $SshHost "mv -f '${RemoteModelTemporary}' '${RemoteModel}'"
    } "Activating verified RKNN model"
}

Invoke-NativeRetry {
    scp @SshOptions (Join-Path $LocalArtifacts $InputName) "${SshHost}:${RemoteRoot}/data/validation/"
} "Uploading validation input"
Invoke-NativeRetry {
    scp @SshOptions (Join-Path $LocalArtifacts $ReferenceName) "${SshHost}:${RemoteRoot}/data/validation/"
} "Uploading validation reference"
Invoke-NativeRetry {
    scp @SshOptions (Join-Path $LocalArtifacts $FixtureName) "${SshHost}:${RemoteRoot}/data/validation/"
} "Uploading validation manifest"
Invoke-NativeRetry {
    scp @SshOptions $LocalProbe "${SshHost}:${RemoteRoot}/repo/rknn_probe.py"
} "Uploading RKNN probe"

Invoke-NativeChecked {
    ssh @SshOptions $SshHost "chmod 755 '${RemoteRoot}/repo/rknn_probe.py' && '${RemoteRoot}/venv/bin/python' '${RemoteRoot}/repo/rknn_probe.py' --model '${RemoteModel}' --input '${RemoteRoot}/data/validation/${InputName}' --reference '${RemoteRoot}/data/validation/${ReferenceName}' --tile-size '${TileSize}' --runs '${Runs}' --report '${RemoteRoot}/benchmarks/${ReportName}'"
} "Running board RKNN validation"

Invoke-NativeRetry {
    scp @SshOptions "${SshHost}:${RemoteRoot}/benchmarks/${ReportName}" (Join-Path $LocalBenchmarks $ReportName)
} "Downloading board validation report"

Write-Output "Board report: $(Join-Path $LocalBenchmarks $ReportName)"
