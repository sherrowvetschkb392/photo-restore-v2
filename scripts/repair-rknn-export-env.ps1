param(
    [string]$Distribution = "Ubuntu",
    [string]$CondaEnvironment = "photo-restore-rknn232"
)

$ErrorActionPreference = "Stop"
if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) { throw "Required command is unavailable: wsl" }
$Command = @"
set -euo pipefail
source /home/ljd/miniconda3/etc/profile.d/conda.sh
conda activate '$CondaEnvironment'
python -m pip install --force-reinstall --no-deps 'setuptools==70.3.0' 'numpy==1.26.4' 'protobuf==4.25.4' 'onnx==1.16.1' 'torch==2.4.0'
python -m pip check
python - <<'PY'
import numpy, onnx, torch
print('numpy=' + numpy.__version__)
print('onnx=' + onnx.__version__)
print('torch=' + torch.__version__)
print('onnx_mapping=' + str(hasattr(onnx, 'mapping')))
PY
"@
Write-Output "Repairing only WSL Conda environment: $CondaEnvironment"
wsl -d $Distribution -- bash -lc $Command
if ($LASTEXITCODE -ne 0) { throw "Repairing the RKNN export environment failed with exit code $LASTEXITCODE" }
Write-Output "Environment: $CondaEnvironment"
Write-Output "Board upload: False"
Write-Output "RESULT=PASS_RKNN_EXPORT_ENV_REPAIR"
