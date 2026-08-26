param(
    [string]$SshHost = "rk3588"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$BoardScript = Join-Path $ProjectRoot "scripts\video-opencl-preflight-board.sh"
$ReportDirectory = Join-Path $ProjectRoot "benchmarks\video-opencl-preflight"
$JsonReport = Join-Path $ReportDirectory "latest.json"
$SshOptions = @("-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3")

if (-not (Test-Path -LiteralPath $BoardScript)) {
    throw "Board OpenCL probe is missing: $BoardScript"
}
foreach ($Command in @("ssh", "scp")) {
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        throw "Required command is unavailable: $Command"
    }
}
New-Item -ItemType Directory -Force -Path $ReportDirectory | Out-Null

$RemoteScript = "/tmp/photo-restore-video-opencl-preflight.sh"
Write-Output "Probing the existing RK3588 OpenCL runtime without installing anything..."
& scp @SshOptions $BoardScript "${SshHost}:${RemoteScript}" | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Uploading the temporary OpenCL probe failed with exit code $LASTEXITCODE"
}

$PreviousPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    $Lines = @(& ssh @SshOptions $SshHost "chmod 700 '$RemoteScript' && '$RemoteScript'; code=`$?; rm -f '$RemoteScript'; exit `$code" 2>&1)
    $Code = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $PreviousPreference
}
$Text = ($Lines | ForEach-Object { "$_" }) -join "`n"
if ($Code -ne 0) {
    throw "Running the read-only OpenCL probe failed with exit code $Code`n$Text"
}

$BeginMarker = "---OPENCL_JSON_BEGIN---"
$EndMarker = "---OPENCL_JSON_END---"
$BeginIndex = $Text.IndexOf($BeginMarker, [StringComparison]::Ordinal)
$EndIndex = $Text.IndexOf($EndMarker, [StringComparison]::Ordinal)
if ($BeginIndex -lt 0 -or $EndIndex -le $BeginIndex) {
    throw "The board did not return a delimited OpenCL report.`n$Text"
}
$JsonText = $Text.Substring(
    $BeginIndex + $BeginMarker.Length,
    $EndIndex - ($BeginIndex + $BeginMarker.Length)
).Trim()
try {
    $Report = $JsonText | ConvertFrom-Json
} catch {
    throw "The board did not return a valid OpenCL JSON report.`n$Text"
}
$JsonText | Set-Content -LiteralPath $JsonReport -Encoding utf8

$Platforms = @($Report.opencl.platforms)
$Devices = @($Platforms | ForEach-Object { @($_.devices) })
Write-Output "OpenCL loader: loaded=$($Report.loader.loaded); path=$($Report.loader.loaded_path)"
Write-Output "OpenCL platforms: $($Platforms.Count); devices=$($Devices.Count)"
foreach ($Device in $Devices) {
    $MemoryGiB = if ($Device.global_memory_bytes) {
        [math]::Round([double]$Device.global_memory_bytes / 1GB, 2)
    } else {
        0
    }
    Write-Output "Device: $($Device.name); vendor=$($Device.vendor); compute units=$($Device.compute_units); clock=$($Device.max_clock_mhz) MHz; memory=$MemoryGiB GiB; driver=$($Device.driver_version)"
}
if ($Report.opencl.error) { Write-Output "OpenCL error: $($Report.opencl.error)" }
Write-Output "Assessment: $($Report.assessment)"
Write-Output "Report: $JsonReport"
Write-Output "Board changed: False"
Write-Output "RESULT=PASS_VIDEO_OPENCL_PREFLIGHT"
