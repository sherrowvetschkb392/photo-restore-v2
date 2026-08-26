param(
    [string]$Distribution = "Ubuntu",
    [string]$CondaEnvironment = "photo-restore-videoexport",
    [int]$Frames = 5,
    [int]$Width = 64,
    [int]$Height = 64,
    [ValidateSet(2, 4)]
    [int]$Scale = 4
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$OutputDirectory = Join-Path $ProjectRoot "benchmarks\video-model-candidates\temporal-fusion-sr"
$Onnx = Join-Path $OutputDirectory "temporal-fusion-sr-${Frames}f-${Width}x${Height}-x${Scale}.onnx"
$ExportReport = Join-Path $OutputDirectory "export-report.json"
$AuditReport = Join-Path $OutputDirectory "onnx-audit.json"

function Convert-ToWslPath([string]$WindowsPath) {
    if ($WindowsPath -notmatch '^(?<drive>[A-Za-z]):\\(?<path>.*)$') { throw "Unsupported Windows path: $WindowsPath" }
    return "/mnt/$($Matches['drive'].ToLowerInvariant())/$($Matches['path'].Replace('\', '/'))"
}

if ($Frames -lt 3 -or $Frames % 2 -eq 0) { throw "Frames must be an odd number >= 3" }
if ($Width -le 0 -or $Height -le 0 -or $Width % 16 -ne 0 -or $Height % 16 -ne 0) {
    throw "Width and Height must be positive and divisible by 16"
}
foreach ($Path in @("tools\export_temporal_fusion_sr_onnx.py", "tools\audit_onnx_graph.py")) {
    if (-not (Test-Path (Join-Path $ProjectRoot $Path))) { throw "Required tool is missing: $Path" }
}

$WslProjectRoot = Convert-ToWslPath $ProjectRoot
$WslOnnx = Convert-ToWslPath $Onnx
$WslExportReport = Convert-ToWslPath $ExportReport
$WslAuditReport = Convert-ToWslPath $AuditReport
$Command = @"
set -euo pipefail
source /home/ljd/miniconda3/etc/profile.d/conda.sh
conda activate '$CondaEnvironment'
cd '$WslProjectRoot'
python tools/export_temporal_fusion_sr_onnx.py --output '$WslOnnx' --report '$WslExportReport' --frames '$Frames' --width '$Width' --height '$Height' --scale '$Scale'
python tools/audit_onnx_graph.py '$WslOnnx' --report '$WslAuditReport'
"@

Write-Output "Exporting the untrained RKNN-oriented temporal-fusion SR architecture probe..."
wsl -d $Distribution -- bash -lc $Command
if ($LASTEXITCODE -ne 0) { throw "Temporal-fusion SR architecture probe failed with exit code $LASTEXITCODE" }

$Export = Get-Content -LiteralPath $ExportReport -Raw | ConvertFrom-Json
$Audit = Get-Content -LiteralPath $AuditReport -Raw | ConvertFrom-Json
Write-Output "Contract: $($Export.contract.input_shape -join 'x') -> $($Export.contract.output_shape -join 'x')"
Write-Output "Parameters: $($Export.architecture.parameter_count)"
Write-Output "ONNX operators: $($Export.onnx.op_types -join ', ')"
Write-Output "Numerical error: max=$($Export.numerical_validation.max_abs_error); mean=$($Export.numerical_validation.mean_abs_error)"
Write-Output "Audit gate: $($Audit.export_gate)"
Write-Output "Quality claim: False (training/distillation is still required)"
Write-Output "Board upload: False"
Write-Output "Report: $ExportReport"
Write-Output "RESULT=PASS_TEMPORAL_FUSION_SR_ARCHITECTURE_PROBE_DEPLOY"
