param(
    [string]$Distribution = "Ubuntu"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$LocalExporter = Join-Path $ProjectRoot "tools\model\export_realesrgan_onnx.py"
$LocalBuilder = Join-Path $ProjectRoot "tools\model\build_rknn.py"
$LocalPreflight = Join-Path $ProjectRoot "tools\model\preflight_rknn.py"
$LocalFixture = Join-Path $ProjectRoot "tools\model\make_validation_fixture.py"
$LinuxRoot = "/home/ljd/photo-restore-rknn232"
$LinuxExporter = "${LinuxRoot}/workspace/scripts/export_realesrgan_onnx.py"
$LinuxBuilder = "${LinuxRoot}/workspace/scripts/build_rknn.py"
$LinuxPreflight = "${LinuxRoot}/workspace/scripts/preflight_rknn.py"
$LinuxFixture = "${LinuxRoot}/workspace/scripts/make_validation_fixture.py"

if (-not (Test-Path -LiteralPath $LocalExporter)) {
    throw "Exporter not found: $LocalExporter"
}
if (-not (Test-Path -LiteralPath $LocalBuilder)) {
    throw "Builder not found: $LocalBuilder"
}
if (-not (Test-Path -LiteralPath $LocalPreflight)) {
    throw "Preflight not found: $LocalPreflight"
}
if (-not (Test-Path -LiteralPath $LocalFixture)) {
    throw "Fixture generator not found: $LocalFixture"
}

$WindowsExporter = (Resolve-Path -LiteralPath $LocalExporter).Path
$WindowsBuilder = (Resolve-Path -LiteralPath $LocalBuilder).Path
$WindowsPreflight = (Resolve-Path -LiteralPath $LocalPreflight).Path
$WindowsFixture = (Resolve-Path -LiteralPath $LocalFixture).Path

function Convert-ToWslPath([string]$WindowsPath) {
    if ($WindowsPath -notmatch '^(?<drive>[A-Za-z]):\\(?<path>.*)$') {
        throw "Unsupported Windows path: $WindowsPath"
    }

    $Drive = $Matches['drive'].ToLowerInvariant()
    $RelativePath = $Matches['path'].Replace('\', '/')
    return "/mnt/${Drive}/${RelativePath}"
}

$WslExporter = Convert-ToWslPath $WindowsExporter
$WslBuilder = Convert-ToWslPath $WindowsBuilder
$WslPreflight = Convert-ToWslPath $WindowsPreflight
$WslFixture = Convert-ToWslPath $WindowsFixture

wsl -d $Distribution -- bash -lc "mkdir -p '${LinuxRoot}/workspace/scripts' && cp '${WslExporter}' '${LinuxExporter}' && cp '${WslBuilder}' '${LinuxBuilder}' && cp '${WslPreflight}' '${LinuxPreflight}' && cp '${WslFixture}' '${LinuxFixture}' && chmod 755 '${LinuxExporter}' '${LinuxBuilder}' '${LinuxPreflight}' '${LinuxFixture}'"

Write-Output "Prepared: ${LinuxExporter}"
Write-Output "Prepared: ${LinuxBuilder}"
Write-Output "Prepared: ${LinuxPreflight}"
Write-Output "Prepared: ${LinuxFixture}"
Write-Output "Run inside WSL with the photo-restore-rknn232 Conda environment:"
Write-Output "python ${LinuxExporter} --weights ${LinuxRoot}/models/source/RealESRGAN_x4plus.pth --output ${LinuxRoot}/models/onnx/realesrgan_x4plus_tile64.onnx --tile-size 64 --report ${LinuxRoot}/workspace/reports/onnx-tile64.json"
Write-Output "python ${LinuxBuilder} --onnx ${LinuxRoot}/models/onnx/realesrgan_x4plus_tile64.onnx --output ${LinuxRoot}/models/rknn/realesrgan_x4plus_tile64_fp16.rknn --report ${LinuxRoot}/workspace/reports/rknn-tile64-fp16.json --log ${LinuxRoot}/workspace/reports/rknn-build-tile64.log"
