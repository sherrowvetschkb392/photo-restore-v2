param(
    [string]$Distribution = "Ubuntu",
    [string]$CondaEnvironment = "photo-restore-rknn232",
    [int]$Width = 64,
    [int]$Height = 64,
    [int]$Frames = 5,
    [ValidateSet(2, 4)]
    [int]$Scale = 2,
    [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$OutputDirectory = Join-Path $ProjectRoot "data\video-development\enhancement-fixtures"

function Convert-ToWslPath([string]$WindowsPath) {
    if ($WindowsPath -notmatch '^(?<drive>[A-Za-z]):\\(?<path>.*)$') {
        throw "Unsupported Windows path: $WindowsPath"
    }
    $Drive = $Matches['drive'].ToLowerInvariant()
    $RelativePath = $Matches['path'].Replace('\', '/')
    return "/mnt/${Drive}/${RelativePath}"
}

if ($Width -le 0 -or $Height -le 0 -or $Frames -le 1 -or $Width % 16 -ne 0 -or $Height % 16 -ne 0) {
    throw "Width and Height must be positive and divisible by 16; Frames must be greater than 1"
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
    Write-Output "Input shape: ${Frames}x3x${Height}x${Width}"
    Write-Output "Output shape: ${Frames}x3x$($Height * $Scale)x$($Width * $Scale)"
    Write-Output "Scale: ${Scale}x"
    Write-Output "RESULT=PASS_VIDEO_ENHANCEMENT_FIXTURE_PREFLIGHT"
    return
}

Write-Output "Generating deterministic video spatial-enhancement fixtures..."
wsl -d $Distribution -- bash -lc "set -e; test -f /home/ljd/miniconda3/etc/profile.d/conda.sh; source /home/ljd/miniconda3/etc/profile.d/conda.sh; conda activate '${CondaEnvironment}'; cd '${WslProjectRoot}'; python tools/make_video_enhancement_fixtures.py --output-dir '${WslOutputDirectory}' --width '${Width}' --height '${Height}' --frames '${Frames}' --scale '${Scale}' --force"
if ($LASTEXITCODE -ne 0) {
    throw "Generating video enhancement fixtures failed with exit code $LASTEXITCODE"
}

Write-Output "Output: $OutputDirectory"
Write-Output "RESULT=PASS_VIDEO_ENHANCEMENT_FIXTURES"
