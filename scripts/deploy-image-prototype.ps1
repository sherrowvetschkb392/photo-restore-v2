param(
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

& $CoreTestScript
if ($LASTEXITCODE -ne 0) { throw "Image core tests failed" }
& $DependencyScript -SshHost $SshHost -RemoteRoot $RemoteRoot
if ($LASTEXITCODE -ne 0) { throw "Board image dependency setup failed" }

$WslGenerator = Convert-ToWslPath $Generator
$WslInput = Convert-ToWslPath $InputImage
wsl -d Ubuntu -- bash -lc "source /home/ljd/miniconda3/etc/profile.d/conda.sh && conda activate photo-restore-rknn232 && python '${WslGenerator}' --output '${WslInput}'"
if ($LASTEXITCODE -ne 0) { throw "Generating prototype image failed" }

ssh @SshOptions $SshHost "mkdir -p '${RemoteRoot}/repo' '${RemoteRoot}/data/prototype/input' '${RemoteRoot}/data/prototype/output' '${RemoteRoot}/benchmarks'"
if ($LASTEXITCODE -ne 0) { throw "Creating remote prototype directories failed" }

foreach ($File in $Files) {
    scp @SshOptions $File.Local "${SshHost}:$($File.Remote)"
    if ($LASTEXITCODE -ne 0) { throw "Uploading $($File.Local) failed" }
}

ssh @SshOptions $SshHost "chmod 755 '${RemoteRoot}/repo/restore_image.py' && '${RemoteRoot}/venv/bin/python' -m py_compile '${RemoteRoot}/repo/tiling.py' '${RemoteRoot}/repo/restore_image.py'"
if ($LASTEXITCODE -ne 0) { throw "Board prototype syntax check failed" }

ssh @SshOptions $SshHost "'${RemoteRoot}/venv/bin/python' -c 'import numpy; from PIL import Image; from rknnlite.api import RKNNLite; print(\"BOARD_IMAGE_DEPS_OK\")'"
if ($LASTEXITCODE -ne 0) {
    throw "Board image dependencies are incomplete. Install Pillow in the project venv before continuing."
}

scp @SshOptions $InputImage "${SshHost}:${RemoteRoot}/data/prototype/input/prototype-173x131.png"
if ($LASTEXITCODE -ne 0) { throw "Uploading prototype input failed" }

ssh @SshOptions $SshHost "'${RemoteRoot}/venv/bin/python' '${RemoteRoot}/repo/restore_image.py' --input '${RemoteRoot}/data/prototype/input/prototype-173x131.png' --output '${RemoteRoot}/data/prototype/output/prototype-173x131-x4.png' --model '${RemoteRoot}/models/realesrgan_x4plus_tile96_fp16.rknn' --report '${RemoteRoot}/benchmarks/prototype-173x131-report.json'"
if ($LASTEXITCODE -ne 0) { throw "Board prototype restoration failed" }

scp @SshOptions "${SshHost}:${RemoteRoot}/data/prototype/output/prototype-173x131-x4.png" $LocalOutput
if ($LASTEXITCODE -ne 0) { throw "Downloading prototype output failed" }
scp @SshOptions "${SshHost}:${RemoteRoot}/benchmarks/prototype-173x131-report.json" $LocalReport
if ($LASTEXITCODE -ne 0) { throw "Downloading prototype report failed" }

Write-Output "Input: $InputImage"
Write-Output "Output: $LocalOutput"
Write-Output "Report: $LocalReport"
Write-Output "RESULT=PASS_IMAGE_PROTOTYPE_DEPLOY"
