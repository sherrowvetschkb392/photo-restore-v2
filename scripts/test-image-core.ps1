param(
    [string]$Distribution = "Ubuntu",
    [string]$CondaEnvironment = "photo-restore-rknn232"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path

function Convert-ToWslPath([string]$WindowsPath) {
    if ($WindowsPath -notmatch '^(?<drive>[A-Za-z]):\\(?<path>.*)$') {
        throw "Unsupported Windows path: $WindowsPath"
    }
    $Drive = $Matches['drive'].ToLowerInvariant()
    $RelativePath = $Matches['path'].Replace('\', '/')
    return "/mnt/${Drive}/${RelativePath}"
}

$WslProjectRoot = Convert-ToWslPath $ProjectRoot
if (-not (Get-Command "wsl" -ErrorAction SilentlyContinue)) {
    throw "Required command is unavailable: wsl"
}

wsl -d $Distribution -- bash -lc "set -e; test -f /home/ljd/miniconda3/etc/profile.d/conda.sh; source /home/ljd/miniconda3/etc/profile.d/conda.sh; conda activate '${CondaEnvironment}'; cd '${WslProjectRoot}'; python -m unittest discover -s tests -p 'test_*.py' -v; python -m py_compile apps/worker/tiling.py apps/worker/restore_image.py apps/worker/image_runtime_check.py tools/make_prototype_image.py"
if ($LASTEXITCODE -ne 0) {
    throw "Image core tests failed with exit code $LASTEXITCODE"
}

Write-Output "RESULT=PASS_IMAGE_CORE_TESTS"
