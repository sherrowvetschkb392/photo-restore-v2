param(
    [string]$Distribution = "Ubuntu",
    [string]$CondaEnvironment = "photo-restore-rknn232",
    [ValidateSet('BasicVSR++', 'RealBasicVSR')]
    [string]$Candidate = "BasicVSR++",
    [switch]$Install
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$CandidateRoot = Join-Path $ProjectRoot "data\video-development\model-candidates\$Candidate"
$WeightsRecord = Join-Path $CandidateRoot "weights-record.json"
if (-not (Test-Path -LiteralPath $WeightsRecord)) {
    throw "Weights record not found: $WeightsRecord. Download the candidate artifacts first."
}
if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
    throw "Required command is unavailable: wsl"
}

function Convert-ToWslPath([string]$WindowsPath) {
    if ($WindowsPath -notmatch '^(?<drive>[A-Za-z]):\\(?<path>.*)$') { throw "Unsupported Windows path: $WindowsPath" }
    return "/mnt/$($Matches['drive'].ToLowerInvariant())/$($Matches['path'].Replace('\', '/'))"
}

$WslProjectRoot = Convert-ToWslPath $ProjectRoot
$WslCandidateRoot = Convert-ToWslPath $CandidateRoot
$WslWorkspace = "/home/ljd/photo-restore-rknn232/workspace/video-export"
$WslCommand = @"
set -euo pipefail
source /home/ljd/miniconda3/etc/profile.d/conda.sh
conda activate '$CondaEnvironment'
mkdir -p '$WslWorkspace'
cd '$WslWorkspace'
python - <<'PY'
import importlib.util
mods = ['torch','onnx','onnxruntime','mmengine','mmagic']
for name in mods:
    spec = importlib.util.find_spec(name)
    print(f'{name}=' + ('installed' if spec else 'missing'))
PY
"@

if (-not $Install) {
    Write-Output "Candidate: $Candidate"
    Write-Output "Environment: $CondaEnvironment"
    Write-Output "Workspace: $WslWorkspace"
    Write-Output "Plan: verify the isolated Conda environment, then install PyTorch/ONNX/MMEngine/MMagic only there."
    Write-Output "No packages changed. Re-run with -Install to perform the development-environment setup."
    Write-Output "RESULT=PASS_VIDEO_EXPORT_ENV_PLAN"
    return
}

Write-Output "Preparing isolated WSL video export environment..."
wsl -d $Distribution -- bash -lc $WslCommand
if ($LASTEXITCODE -ne 0) { throw "Checking the isolated WSL export environment failed with exit code $LASTEXITCODE" }

$InstallCommand = @"
set -euo pipefail
source /home/ljd/miniconda3/etc/profile.d/conda.sh
conda activate '$CondaEnvironment'
python -m pip install --upgrade 'setuptools==70.3.0' 'numpy==1.26.4' 'protobuf==4.25.4' 'onnx==1.16.1' 'onnxruntime==1.18.1'
python -m pip install 'mmengine>=0.10.4,<1.0' 'mmagic>=1.2.0,<2.0'
mkdir -p '$WslWorkspace'
if [ ! -d '$WslWorkspace/mmagic/.git' ]; then
  git clone --depth 1 https://github.com/open-mmlab/mmagic.git '$WslWorkspace/mmagic'
fi
python - <<'PY'
import torch, onnx, onnxruntime, mmengine, mmagic
print('torch=' + torch.__version__)
print('onnx=' + onnx.__version__)
print('onnxruntime=' + onnxruntime.__version__)
print('mmengine=' + mmengine.__version__)
print('mmagic=' + getattr(mmagic, '__version__', 'installed'))
PY
"@
wsl -d $Distribution -- bash -lc $InstallCommand
if ($LASTEXITCODE -ne 0) { throw "Installing the isolated WSL video export environment failed with exit code $LASTEXITCODE" }

Write-Output "Workspace: $WslWorkspace"
Write-Output "Weights remain local at: $CandidateRoot"
Write-Output "Board upload: False"
Write-Output "RESULT=PASS_VIDEO_EXPORT_ENV_READY"
