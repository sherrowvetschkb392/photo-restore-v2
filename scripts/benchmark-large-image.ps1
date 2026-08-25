param(
    [ValidateRange(64, 4000)]
    [int]$Width = 1280,
    [ValidateRange(64, 4000)]
    [int]$Height = 720,
    [ValidateRange(60, 3600)]
    [int]$TimeoutSeconds = 900,
    [string]$Distribution = "Ubuntu",
    [string]$CondaEnvironment = "photo-restore-rknn232",
    [string]$SshHost = "rk3588",
    [string]$RemoteRoot = "/userdata/photo-restore-v2",
    [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$PixelCount = [int64]$Width * [int64]$Height
$TierName = if ($PixelCount -le 1000000) { "tier-1" } else { "tier-2" }
if ($PixelCount -gt 2000000) {
    throw "Benchmark image has $PixelCount pixels, above the currently deployed 2,000,000-pixel safety limit"
}

$Generator = Join-Path $ProjectRoot "tools\make_prototype_image.py"
$SmokeTest = Join-Path $PSScriptRoot "test-web-api.ps1"
$InputDirectory = Join-Path $ProjectRoot "data\benchmarks\large-image"
$BenchmarkDirectory = Join-Path $ProjectRoot "benchmarks\large-image"
$InputImage = Join-Path $InputDirectory "benchmark-${Width}x${Height}.png"
$SmokeReport = Join-Path $ProjectRoot "benchmarks\web-api-smoke\api-smoke-report.json"
$BenchmarkReport = Join-Path $BenchmarkDirectory "benchmark-${Width}x${Height}-report.json"
$BenchmarkSummary = Join-Path $BenchmarkDirectory "benchmark-${Width}x${Height}-summary.json"

foreach ($RequiredCommand in @("wsl", "ssh", "scp")) {
    if (-not (Get-Command $RequiredCommand -ErrorAction SilentlyContinue)) {
        throw "Required command is unavailable: $RequiredCommand"
    }
}
foreach ($RequiredFile in @($Generator, $SmokeTest)) {
    if (-not (Test-Path -LiteralPath $RequiredFile -PathType Leaf)) {
        throw "Required file is missing: $RequiredFile"
    }
}
New-Item -ItemType Directory -Force -Path $InputDirectory, $BenchmarkDirectory | Out-Null
foreach ($GeneratedPath in @($BenchmarkReport, $BenchmarkSummary)) {
    if (Test-Path -LiteralPath $GeneratedPath) {
        Remove-Item -LiteralPath $GeneratedPath -Force
    }
}

function Convert-ToWslPath([string]$WindowsPath) {
    if ($WindowsPath -notmatch '^(?<drive>[A-Za-z]):\\(?<path>.*)$') {
        throw "Unsupported Windows path: $WindowsPath"
    }
    $Drive = $Matches['drive'].ToLowerInvariant()
    $RelativePath = $Matches['path'].Replace('\', '/')
    return "/mnt/${Drive}/${RelativePath}"
}

$WslGenerator = Convert-ToWslPath $Generator
$WslInput = Convert-ToWslPath $InputImage
if ($WslGenerator -notlike "/mnt/*" -or $WslInput -notlike "/mnt/*") {
    throw "Windows-to-WSL path conversion failed"
}
if ($ValidateOnly) {
    Write-Output "Generator WSL path: $WslGenerator"
    Write-Output "Input WSL path: $WslInput"
    Write-Output "Pixels: $PixelCount"
    Write-Output "RESULT=PASS_LARGE_IMAGE_BENCHMARK_PREFLIGHT"
    return
}
Write-Output "Generating deterministic benchmark image: ${Width}x${Height} ($PixelCount pixels)..."
wsl -d $Distribution -- bash -lc "set -e; source /home/ljd/miniconda3/etc/profile.d/conda.sh; conda activate '${CondaEnvironment}'; python '${WslGenerator}' --output '${WslInput}' --width '${Width}' --height '${Height}'"
if ($LASTEXITCODE -ne 0) {
    throw "Generating the large-image benchmark fixture failed with exit code $LASTEXITCODE"
}

Write-Output "Running the image through the deployed API..."
& $SmokeTest -InputImage $InputImage -TimeoutSeconds $TimeoutSeconds -SshHost $SshHost -RemoteRoot $RemoteRoot
if (-not (Test-Path -LiteralPath $SmokeReport -PathType Leaf)) {
    throw "API benchmark report was not downloaded: $SmokeReport"
}

$Report = Get-Content -LiteralPath $SmokeReport -Raw | ConvertFrom-Json
$ExpectedOutputWidth = $Width * 4
$ExpectedOutputHeight = $Height * 4
if ($Report.compositor -ne "disk") {
    throw "Expected disk compositor for $PixelCount pixels, received '$($Report.compositor)'"
}
if ([int]$Report.output_size[0] -ne $ExpectedOutputWidth -or [int]$Report.output_size[1] -ne $ExpectedOutputHeight) {
    throw "Unexpected output size: $($Report.output_size -join 'x')"
}
if ([int]$Report.preview_size[0] -gt 1600 -or [int]$Report.preview_size[1] -gt 1600) {
    throw "Preview exceeds the 1600-pixel longest-edge limit: $($Report.preview_size -join 'x')"
}
if ([int64]$Report.raw_output_bytes -ne ($PixelCount * 16 * 3)) {
    throw "Raw output byte estimate is inconsistent with the 4x RGB output"
}

Copy-Item -LiteralPath $SmokeReport -Destination $BenchmarkReport -Force
$Summary = [ordered]@{
    benchmark = "large-image-api-${TierName}"
    input_size = @($Width, $Height)
    input_pixels = $PixelCount
    output_size = @($ExpectedOutputWidth, $ExpectedOutputHeight)
    compositor = [string]$Report.compositor
    tile_count = [int]$Report.plan.tile_count
    inference_seconds = [double]$Report.inference_seconds
    total_seconds = [double]$Report.total_seconds
    input_pixels_per_second = [Math]::Round($PixelCount / [double]$Report.inference_seconds, 2)
    max_rss_kib = [int64]$Report.max_rss_kib
    raw_output_bytes = [int64]$Report.raw_output_bytes
    required_free_bytes = [int64]$Report.required_free_bytes
    preview_size = @([int]$Report.preview_size[0], [int]$Report.preview_size[1])
    report = $BenchmarkReport
    tested_at_utc = [DateTime]::UtcNow.ToString("o")
}
$Summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $BenchmarkSummary -Encoding utf8

Write-Output ($Summary | ConvertTo-Json -Depth 6)
Write-Output "Benchmark report: $BenchmarkReport"
Write-Output "Benchmark summary: $BenchmarkSummary"
Write-Output "RESULT=PASS_LARGE_IMAGE_$($TierName.Replace('-', '').ToUpperInvariant())_BENCHMARK"
