param(
    [string]$SshHost = "rk3588"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$BoardScript = Join-Path $ProjectRoot "scripts\test-video-opencl-board.sh"
$ReportDirectory = Join-Path $ProjectRoot "benchmarks\video-opencl-smoke"
$JsonReport = Join-Path $ReportDirectory "latest.json"
$SshOptions = @("-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3")

if (-not (Test-Path -LiteralPath $BoardScript)) { throw "OpenCL smoke worker is missing: $BoardScript" }
foreach ($Command in @("ssh", "scp")) {
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) { throw "Required command is unavailable: $Command" }
}
New-Item -ItemType Directory -Force -Path $ReportDirectory | Out-Null

Write-Output "Checking production services before the isolated OpenCL compute smoke test..."
$Safety = @(& ssh @SshOptions $SshHost "printf 'api='; systemctl is-active photo-restore-api.service; printf 'tunnel='; systemctl is-active cloudflared.service; printf 'workers='; pgrep -fc '/userdata/photo-restore-v2.*([r]estore_image.py|[r]ife|[m]nn)' || true" 2>&1)
if ($LASTEXITCODE -ne 0) { throw "Reading the production safety state failed.`n$($Safety -join "`n")" }
$SafetyText = ($Safety | ForEach-Object { "$_" }) -join "`n"
if ($SafetyText -notmatch '(?m)^api=active$' -or $SafetyText -notmatch '(?m)^tunnel=active$') {
    throw "Production services are not healthy; the GPU smoke test was not started.`n$SafetyText"
}
if ($SafetyText -match '(?m)^workers=(?<count>\d+)$' -and [int]$Matches.count -gt 0) {
    throw "A media worker is already active; the GPU smoke test was not started.`n$SafetyText"
}

$RemoteScript = "/tmp/photo-restore-video-opencl-smoke.sh"
Write-Output "Uploading one temporary OpenCL compute worker..."
& scp @SshOptions $BoardScript "${SshHost}:${RemoteScript}" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Uploading the OpenCL smoke worker failed with exit code $LASTEXITCODE" }

$PreviousPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    $Lines = @(& ssh @SshOptions $SshHost "chmod 700 '$RemoteScript' && '$RemoteScript'; code=`$?; rm -f '$RemoteScript'; exit `$code" 2>&1)
    $Code = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $PreviousPreference
}
$Text = ($Lines | ForEach-Object { "$_" }) -join "`n"
$BeginMarker = "---OPENCL_SMOKE_JSON_BEGIN---"
$EndMarker = "---OPENCL_SMOKE_JSON_END---"
$BeginIndex = $Text.IndexOf($BeginMarker, [StringComparison]::Ordinal)
$EndIndex = $Text.IndexOf($EndMarker, [StringComparison]::Ordinal)
if ($BeginIndex -lt 0 -or $EndIndex -le $BeginIndex) {
    throw "The board did not return a delimited OpenCL smoke report (exit code $Code).`n$Text"
}
$JsonText = $Text.Substring($BeginIndex + $BeginMarker.Length, $EndIndex - ($BeginIndex + $BeginMarker.Length)).Trim()
try { $Report = $JsonText | ConvertFrom-Json } catch { throw "The OpenCL smoke report is invalid.`n$Text" }
$JsonText | Set-Content -LiteralPath $JsonReport -Encoding utf8
if ($Code -ne 0 -or $Report.result -ne "PASS" -or -not $Report.validation.passed) {
    throw "The Mali OpenCL compute smoke test failed.`n$JsonText"
}

Write-Output "Device: $($Report.device.name); driver=$($Report.device.driver_version)"
Write-Output "Kernel: $($Report.workload.operation); elements=$($Report.workload.elements); repeats=$($Report.workload.repeats)"
Write-Output "Timing: compile=$($Report.timing_seconds.compile)s; compute total=$($Report.timing_seconds.compute_total)s; per repeat=$($Report.timing_seconds.compute_per_repeat)s"
Write-Output "Validation: passed=$($Report.validation.passed); mismatches=$($Report.validation.mismatch_count); max error=$($Report.validation.maximum_absolute_error)"
Write-Output "Report: $JsonReport"
Write-Output "Board changed: False"
Write-Output "RESULT=PASS_VIDEO_OPENCL_COMPUTE_SMOKE"
