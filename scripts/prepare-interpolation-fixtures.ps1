param(
    [string]$Distribution = "Ubuntu",
    [string]$CondaEnvironment = "photo-restore-rknn232",
    [int]$Width = 256,
    [int]$Height = 256,
    [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$OutputDirectory = Join-Path $ProjectRoot "data\video-development\interpolation-fixtures"

function Convert-ToWslPath([string]$WindowsPath) {
    if ($WindowsPath -notmatch '^(?<drive>[A-Za-z]):\\(?<path>.*)$') {
        throw "Unsupported Windows path: $WindowsPath"
    }
    $Drive = $Matches['drive'].ToLowerInvariant()
    $RelativePath = $Matches['path'].Replace('\', '/')
    return "/mnt/${Drive}/${RelativePath}"
}

if ($Width -le 0 -or $Height -le 0 -or $Width % 16 -ne 0 -or $Height % 16 -ne 0) {
    throw "Width and Height must be positive and divisible by 16"
}
if (-not (Get-Command "wsl" -ErrorAction SilentlyContinue)) {
    throw "Required command is unavailable: wsl"
}

$WslProjectRoot = Convert-ToWslPath $ProjectRoot
$WslOutputDirectory = Convert-ToWslPath $OutputDirectory
if ($ValidateOnly) {
    Write-Output "Distribution: $Distribution"
    Write-Output "Conda environment: $CondaEnvironment"
    Write-Output "Output: $OutputDirectory"
    Write-Output "Shape: 1x3x${Height}x${Width}"
    Write-Output "RESULT=PASS_INTERPOLATION_FIXTURE_PREFLIGHT"
    return
}

Write-Output "Generating deterministic interpolation frame-pair fixtures..."
wsl -d $Distribution -- bash -lc "set -e; test -f /home/ljd/miniconda3/etc/profile.d/conda.sh; source /home/ljd/miniconda3/etc/profile.d/conda.sh; conda activate '${CondaEnvironment}'; cd '${WslProjectRoot}'; python tools/make_interpolation_fixtures.py --output-dir '${WslOutputDirectory}' --width '${Width}' --height '${Height}' --force"
if ($LASTEXITCODE -ne 0) {
    throw "Generating interpolation fixtures failed with exit code $LASTEXITCODE"
}

Write-Output "Validating the exact midpoint against the linear-motion contract..."
wsl -d $Distribution -- bash -lc "set -e; source /home/ljd/miniconda3/etc/profile.d/conda.sh; conda activate '${CondaEnvironment}'; cd '${WslProjectRoot}'; python tools/evaluate_interpolation_output.py --case-dir '${WslOutputDirectory}/linear-motion' --candidate '${WslOutputDirectory}/linear-motion/target.npy' --report '${WslOutputDirectory}/linear-motion/exact-target-evaluation.json' --require-beats-baseline"
if ($LASTEXITCODE -ne 0) {
    throw "Validating interpolation fixtures failed with exit code $LASTEXITCODE"
}

Write-Output "Output: $OutputDirectory"
Write-Output "RESULT=PASS_INTERPOLATION_FIXTURE_PREPARATION"
