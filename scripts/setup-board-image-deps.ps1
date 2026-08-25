param(
    [string]$SshHost = "rk3588",
    [string]$RemoteRoot = "/userdata/photo-restore-v2"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$SshOptions = @("-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3")
$Python = "${RemoteRoot}/venv/bin/python"
$LocalCheck = Join-Path $ProjectRoot "apps\worker\image_runtime_check.py"
$RemoteCheck = "${RemoteRoot}/repo/image_runtime_check.py"

function Invoke-NativeChecked {
    param([scriptblock]$Command, [string]$Description)
    $PreviousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $Command
        $ExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
    }
    if ($ExitCode -ne 0) {
        throw "$Description failed with exit code $ExitCode"
    }
}

function Invoke-NativeRetry {
    param([scriptblock]$Command, [string]$Description, [int]$Attempts = 3)
    for ($Attempt = 1; $Attempt -le $Attempts; $Attempt++) {
        $PreviousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            & $Command
            $ExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $PreviousErrorActionPreference
        }
        if ($ExitCode -eq 0) { return }
        if ($Attempt -eq $Attempts) {
            throw "$Description failed after $Attempts attempts; last exit code $ExitCode"
        }
        Write-Warning "$Description failed on attempt $Attempt; retrying..."
        Start-Sleep -Seconds (2 * $Attempt)
    }
}

foreach ($RequiredCommand in @("ssh", "scp")) {
    if (-not (Get-Command $RequiredCommand -ErrorAction SilentlyContinue)) {
        throw "Required command is unavailable: $RequiredCommand"
    }
}
if (-not (Test-Path -LiteralPath $LocalCheck -PathType Leaf)) {
    throw "Board image runtime check is missing: $LocalCheck"
}

Invoke-NativeRetry {
    ssh @SshOptions $SshHost "test -x '${Python}' && mkdir -p '${RemoteRoot}/repo'"
} "Checking the isolated board Python environment"
Invoke-NativeRetry {
    scp @SshOptions $LocalCheck "${SshHost}:${RemoteCheck}"
} "Uploading the board image runtime check"

$PreviousErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    ssh @SshOptions $SshHost "'${Python}' '${RemoteCheck}' --pillow-only" 2>$null
    $PillowProbeExitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $PreviousErrorActionPreference
}
if ($PillowProbeExitCode -ne 0) {
    Write-Output "Installing Pillow 11.3.0 into the isolated board venv..."
    Invoke-NativeRetry {
        ssh @SshOptions $SshHost "'${Python}' -m pip install --only-binary=:all: Pillow==11.3.0"
    } "Installing Pillow on RK3588"
}

Invoke-NativeRetry {
    ssh @SshOptions $SshHost "'${Python}' '${RemoteCheck}'"
} "Verifying board image dependencies"

Write-Output "RESULT=PASS_BOARD_IMAGE_DEPS"
