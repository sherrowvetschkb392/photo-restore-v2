param(
    [string]$Distribution = "Ubuntu",
    [string]$CondaEnvironment = "photo-restore-videoexport",
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
$WslWorkspace = "/home/ljd/photo-restore-videoexport/workspace"
$WslCommand = @"
set -euo pipefail
source /home/ljd/miniconda3/etc/profile.d/conda.sh
if ! conda env list | awk '{print $1}' | grep -qx '$CondaEnvironment'; then
  conda create -y -n '$CondaEnvironment' python=3.10
fi
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
    Write-Output "Plan: create/use the separate video-export Conda environment, then install PyTorch/ONNX/MMEngine/MMagic only there."
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
if ! conda env list | awk '{print $1}' | grep -qx '$CondaEnvironment'; then
  conda create -y -n '$CondaEnvironment' python=3.10
fi
conda activate '$CondaEnvironment'
python -m pip install --force-reinstall --no-deps 'setuptools==70.3.0' 'numpy==1.26.4' 'protobuf==4.25.4' 'onnx==1.16.1' 'onnxruntime==1.18.1'
# Install Torch normally in this video-only environment so its CUDA runtime
# wheels (libcudart, libcublas, etc.) are present. Torch does not require a
# NumPy 2.x ABI; the pins are reasserted after all dependency resolution.
python -m pip install --upgrade 'torch==2.4.0' 'torchvision==0.19.0'
# MMagic's broad optional dependency set currently requests NumPy 2.x. Install
# the packages without dependency resolution, then add only conservative
# versions needed for the BasicVSR++ config/export path.
python -m pip install --no-deps 'mmengine==0.10.7' 'mmagic==1.2.0'
python -m pip install --no-deps 'addict==2.4.0' 'yapf==0.43.0' 'opencv-python==4.10.0.84' 'scipy==1.13.1' 'scikit-image==0.24.0' 'imageio==2.35.1' 'matplotlib==3.9.2' 'pyyaml==6.0.2' 'rich==13.9.4' 'termcolor==2.5.0'
# Re-assert the ABI-sensitive pins after all package operations.
python -m pip install --force-reinstall --no-deps 'numpy==1.26.4' 'protobuf==4.25.4' 'onnx==1.16.1' 'onnxruntime==1.18.1'
mkdir -p '$WslWorkspace'
if [ ! -d '$WslWorkspace/mmagic/.git' ]; then
  git clone --depth 1 https://github.com/open-mmlab/mmagic.git '$WslWorkspace/mmagic'
fi
python - <<'PY'
import numpy, torch, onnx, onnxruntime, mmengine, mmagic
assert numpy.__version__ == '1.26.4', numpy.__version__
assert onnx.__version__ == '1.16.1', onnx.__version__
print('torch=' + torch.__version__)
print('numpy=' + numpy.__version__)
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
