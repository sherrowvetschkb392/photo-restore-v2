param(
    [string]$Distribution = "Ubuntu",
    [string]$CondaEnvironment = "photo-restore-rknn232",
    [string]$SshHost = "rk3588",
    [string]$RemoteRoot = "/userdata/photo-restore-v2"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$LocalInputDirectory = Join-Path $ProjectRoot "data\prototype"
$SshOptions = @("-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3")
$Files = @(
    @{ Local = Join-Path $ProjectRoot "apps\worker\tiling.py"; Remote = "${RemoteRoot}/repo/tiling.py" },
    @{ Local = Join-Path $ProjectRoot "apps\worker\restore_image.py"; Remote = "${RemoteRoot}/repo/restore_image.py" }
)
$Generator = Join-Path $ProjectRoot "tools\make_prototype_image.py"
$CoreTestScript = Join-Path $PSScriptRoot "test-image-core.ps1"
$DependencyScript = Join-Path $PSScriptRoot "setup-board-image-deps.ps1"
$InputImage = Join-Path $LocalInputDirectory "prototype-173x131.png"
$LocalOutputDirectory = Join-Path $ProjectRoot "benchmarks\prototype"
$LocalOutput = Join-Path $LocalOutputDirectory "prototype-173x131-x4.png"
$LocalReport = Join-Path $LocalOutputDirectory "prototype-173x131-report.json"
$RemoteModel = "${RemoteRoot}/models/realesrgan_x4plus_tile96_fp16.rknn"

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

foreach ($RequiredCommand in @("wsl", "ssh", "scp")) {
    if (-not (Get-Command $RequiredCommand -ErrorAction SilentlyContinue)) {
        throw "Required command is unavailable: $RequiredCommand"
    }
}

foreach ($File in $Files) {
    if (-not (Test-Path -LiteralPath $File.Local -PathType Leaf)) {
        throw "Required source file missing: $($File.Local)"
    }
}
if (-not (Test-Path -LiteralPath $Generator -PathType Leaf)) {
    throw "Prototype generator missing: $Generator"
}

New-Item -ItemType Directory -Force -Path $LocalInputDirectory, $LocalOutputDirectory | Out-Null

function Convert-ToWslPath([string]$WindowsPath) {
    if ($WindowsPath -notmatch '^(?<drive>[A-Za-z]):\\(?<path>.*)$') {
        throw "Unsupported Windows path: $WindowsPath"
    }
    $Drive = $Matches['drive'].ToLowerInvariant()
    $RelativePath = $Matches['path'].Replace('\', '/')
    return "/mnt/${Drive}/${RelativePath}"
}

& $CoreTestScript -Distribution $Distribution -CondaEnvironment $CondaEnvironment
& $DependencyScript -SshHost $SshHost -RemoteRoot $RemoteRoot

Invoke-NativeChecked {
    ssh @SshOptions $SshHost "test -f '${RemoteModel}' && test -x '${RemoteRoot}/venv/bin/python'"
} "Checking the selected RKNN model and board Python"

$WslGenerator = Convert-ToWslPath $Generator
$WslInput = Convert-ToWslPath $InputImage
Invoke-NativeChecked {
    wsl -d $Distribution -- bash -lc "set -e; source /home/ljd/miniconda3/etc/profile.d/conda.sh; conda activate '${CondaEnvironment}'; python '${WslGenerator}' --output '${WslInput}'"
} "Generating prototype image"

Invoke-NativeChecked {
    ssh @SshOptions $SshHost "mkdir -p '${RemoteRoot}/repo' '${RemoteRoot}/data/prototype/input' '${RemoteRoot}/data/prototype/output' '${RemoteRoot}/benchmarks'"
} "Creating remote prototype directories"

foreach ($File in $Files) {
    Invoke-NativeRetry {
        scp @SshOptions $File.Local "${SshHost}:$($File.Remote)"
    } "Uploading $($File.Local)"
}

Invoke-NativeChecked {
    ssh @SshOptions $SshHost "chmod 755 '${RemoteRoot}/repo/restore_image.py' && '${RemoteRoot}/venv/bin/python' -m py_compile '${RemoteRoot}/repo/tiling.py' '${RemoteRoot}/repo/restore_image.py'"
} "Checking board prototype syntax"

Invoke-NativeRetry {
    scp @SshOptions $InputImage "${SshHost}:${RemoteRoot}/data/prototype/input/prototype-173x131.png"
} "Uploading prototype input"

Invoke-NativeChecked {
    ssh @SshOptions $SshHost "'${RemoteRoot}/venv/bin/python' '${RemoteRoot}/repo/restore_image.py' --input '${RemoteRoot}/data/prototype/input/prototype-173x131.png' --output '${RemoteRoot}/data/prototype/output/prototype-173x131-x4.png' --model '${RemoteModel}' --report '${RemoteRoot}/benchmarks/prototype-173x131-report.json'"
} "Running board prototype restoration"

Invoke-NativeRetry {
    scp @SshOptions "${SshHost}:${RemoteRoot}/data/prototype/output/prototype-173x131-x4.png" $LocalOutput
} "Downloading prototype output"
Invoke-NativeRetry {
    scp @SshOptions "${SshHost}:${RemoteRoot}/benchmarks/prototype-173x131-report.json" $LocalReport
} "Downloading prototype report"

Write-Output "Input: $InputImage"
Write-Output "Output: $LocalOutput"
Write-Output "Report: $LocalReport"
Write-Output "RESULT=PASS_IMAGE_PROTOTYPE_DEPLOY"
