param(
    [string]$Distribution = "Ubuntu",
    [string]$CondaEnvironment = "photo-restore-videoexport",
    [ValidateSet('BasicVSR++')]
    [string]$Candidate = "BasicVSR++",
    [int]$Frames = 5,
    [int]$Width = 64,
    [int]$Height = 64
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$CandidateRoot = Join-Path $ProjectRoot "data\video-development\model-candidates\$Candidate"
$Weights = Join-Path $CandidateRoot "weights\basicvsr_plusplus_x4.pth"
$Spynet = Join-Path $CandidateRoot "weights\spynet.pth"
$Report = Join-Path $ProjectRoot "benchmarks\video-model-candidates\basicvsr-export-preflight.json"
$Verifier = Join-Path $ProjectRoot "tools\verify_video_model_artifacts.py"
$Preflight = Join-Path $ProjectRoot "tools\preflight_basicvsr_export.py"
$WeightsRecord = Join-Path $CandidateRoot "weights-record.json"

function Convert-ToWslPath([string]$WindowsPath) {
    if ($WindowsPath -notmatch '^(?<drive>[A-Za-z]):\\(?<path>.*)$') {
        throw "Unsupported Windows path: $WindowsPath"
    }
    return "/mnt/$($Matches['drive'].ToLowerInvariant())/$($Matches['path'].Replace('\', '/'))"
}

foreach ($Path in @($Weights, $Spynet, $Verifier, $Preflight, $WeightsRecord)) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "Required file is missing: $Path" }
}
if ($Frames -lt 2 -or $Width -le 0 -or $Height -le 0 -or $Width % 16 -ne 0 -or $Height % 16 -ne 0) {
    throw "Frames must be >= 2; Width and Height must be positive and divisible by 16"
}
if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) { throw "Required command is unavailable: wsl" }

$WslProjectRoot = Convert-ToWslPath $ProjectRoot
$WslWeights = Convert-ToWslPath $Weights
$WslSpynet = Convert-ToWslPath $Spynet
$WslReport = Convert-ToWslPath $Report
$WslWeightsRecord = Convert-ToWslPath $WeightsRecord

Write-Output "Verifying the isolated BasicVSR++ artifacts..."
$Command = @"
set -euo pipefail
source /home/ljd/miniconda3/etc/profile.d/conda.sh
conda activate '$CondaEnvironment'
cd '$WslProjectRoot'
python tools/verify_video_model_artifacts.py '$WslWeightsRecord'
python tools/preflight_basicvsr_export.py --weights '$WslWeights' --spynet '$WslSpynet' --report '$WslReport' --frames '$Frames' --width '$Width' --height '$Height'
"@
wsl -d $Distribution -- bash -lc $Command
if ($LASTEXITCODE -ne 0) { throw "BasicVSR++ export preflight failed with exit code $LASTEXITCODE" }

$Result = Get-Content -LiteralPath $Report -Raw | ConvertFrom-Json
Write-Output "Checkpoint: loaded=$($Result.checkpoint.loaded); tensors=$($Result.checkpoint.tensor_count); parameters=$($Result.checkpoint.parameter_count)"
Write-Output "MMCV compiled ops: $($Result.operators.mmcv_compiled_ops_available)"
Write-Output "Model class imported: $($Result.model.class_imported)"
Write-Output "Export gate: $($Result.export_gate)"
Write-Output "Report: $Report"
Write-Output "Board upload: False"
Write-Output "RESULT=PASS_BASICVSR_EXPORT_PREFLIGHT_DEPLOY"
