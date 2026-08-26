param(
    [string]$Distribution = "Ubuntu",
    [string]$CondaEnvironment = "photo-restore-videoexport"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$Report = Join-Path $ProjectRoot "benchmarks\video-model-candidates\deform-conv-onnx-probe.json"
$Onnx = Join-Path $ProjectRoot "benchmarks\video-model-candidates\deform-conv-probe.onnx"

function Convert-ToWslPath([string]$WindowsPath) {
    if ($WindowsPath -notmatch '^(?<drive>[A-Za-z]):\\(?<path>.*)$') { throw "Unsupported Windows path: $WindowsPath" }
    return "/mnt/$($Matches['drive'].ToLowerInvariant())/$($Matches['path'].Replace('\', '/'))"
}

$WslProjectRoot = Convert-ToWslPath $ProjectRoot
$WslReport = Convert-ToWslPath $Report
$WslOnnx = Convert-ToWslPath $Onnx
$Command = @"
set -euo pipefail
source /home/ljd/miniconda3/etc/profile.d/conda.sh
conda activate '$CondaEnvironment'
cd '$WslProjectRoot'
python tools/probe_deform_conv_onnx.py --output '$WslOnnx' --report '$WslReport'
"@

Write-Output "Probing the TorchVision modulated deform-convolution ONNX path..."
wsl -d $Distribution -- bash -lc $Command
if ($LASTEXITCODE -ne 0) { throw "Deform-convolution ONNX probe failed with exit code $LASTEXITCODE" }
$Result = Get-Content -LiteralPath $Report -Raw | ConvertFrom-Json
Write-Output "CPU execution: $($Result.cpu_execution.passed)"
Write-Output "ONNX export: $($Result.onnx_export.passed)"
Write-Output "Gate: $($Result.gate)"
Write-Output "Report: $Report"
Write-Output "Board upload: False"
Write-Output "RESULT=$($Result.gate)_DEFORM_CONV_PROBE_DEPLOY"
