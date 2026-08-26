param(
    [string]$SshHost = "rk3588"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$BoardScript = Join-Path $ProjectRoot "scripts\preflight-mnn-opencl-board.sh"
$ReportDirectory = Join-Path $ProjectRoot "benchmarks\mnn-opencl-preflight"
$RawReport = Join-Path $ReportDirectory "latest-raw.txt"
$JsonReport = Join-Path $ReportDirectory "latest.json"
$SshOptions = @("-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3")

if (-not (Test-Path -LiteralPath $BoardScript)) { throw "MNN/OpenCL board preflight is missing: $BoardScript" }
foreach ($Command in @("ssh", "scp")) {
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) { throw "Required command is unavailable: $Command" }
}
New-Item -ItemType Directory -Force -Path $ReportDirectory | Out-Null

$RemoteScript = "/tmp/photo-restore-mnn-opencl-preflight.sh"
Write-Output "Collecting a read-only MNN/OpenCL build inventory..."
& scp @SshOptions $BoardScript "${SshHost}:${RemoteScript}" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Uploading the temporary MNN/OpenCL preflight failed with exit code $LASTEXITCODE" }
$PreviousPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    $Lines = @(& ssh @SshOptions $SshHost "chmod 700 '$RemoteScript' && '$RemoteScript'; code=`$?; rm -f '$RemoteScript'; exit `$code" 2>&1)
    $Code = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $PreviousPreference
}
$Text = ($Lines | ForEach-Object { "$_" }) -join "`n"
$Text | Set-Content -LiteralPath $RawReport -Encoding utf8
if ($Code -ne 0) { throw "Collecting the read-only MNN/OpenCL inventory failed with exit code $Code`n$Text" }

$Sections = @{}
$Current = $null
foreach ($Line in $Text -split "`r?`n") {
    if ($Line -match '^---SECTION:(?<name>[A-Z_]+)---$') {
        $Current = $Matches.name
        $Sections[$Current] = @()
    } elseif ($null -ne $Current -and $Line -ne '---END---') {
        $Sections[$Current] += $Line
    }
}

$Tools = @{}
foreach ($Line in @($Sections.TOOLS)) {
    if ($Line -match '^(?<key>[a-z0-9_]+)_path=(?<value>.*)$') { $Tools[$Matches.key] = $Matches.value }
}
$RequiredNativeTools = @("git", "cmake", "make", "gcc", "gxx", "python3")
$MissingNativeTools = @($RequiredNativeTools | Where-Object { -not $Tools[$_] -or $Tools[$_] -eq "missing" })
$OpenClLines = @($Sections.OPENCL)
$HasOpenClLibrary = @($OpenClLines | Where-Object { $_ -match 'libOpenCL' }).Count -gt 0
$HasOpenClHeader = @($OpenClLines | Where-Object { $_ -match '^header=' }).Count -gt 0
$HasOpenClIcd = @($OpenClLines | Where-Object { $_ -match '^icd=' }).Count -gt 0
$ExistingMnn = @($Sections.EXISTING_MNN | Where-Object { $_ -match '^artifact=' -and $_ -ne 'artifact=none' })
$ResourceValues = @{}
foreach ($Line in @($Sections.RESOURCES)) {
    if ($Line -match '^(?<key>[a-z_]+)=(?<value>[0-9]+)$') { $ResourceValues[$Matches.key] = [double]$Matches.value }
}
$AvailableMemoryGiB = if ($ResourceValues.memory_available_bytes) { [math]::Round($ResourceValues.memory_available_bytes / 1GB, 2) } else { 0 }
$AvailableDiskGiB = if ($ResourceValues.filesystem_available_bytes) { [math]::Round($ResourceValues.filesystem_available_bytes / 1GB, 2) } else { 0 }
$ProductionHealthy =
    @($Sections.PRODUCTION | Where-Object { $_ -eq 'photo-restore-api.service|active=active|enabled=enabled' }).Count -gt 0 -and
    @($Sections.PRODUCTION | Where-Object { $_ -eq 'cloudflared.service|active=active|enabled=enabled' }).Count -gt 0
$MediaWorkers = if (($Sections.PRODUCTION -join "`n") -match '(?m)^media_workers=(?<count>\d+)$') { [int]$Matches.count } else { -1 }

$Blockers = [System.Collections.Generic.List[string]]::new()
if (-not $HasOpenClLibrary -or -not $HasOpenClIcd) { $Blockers.Add("opencl_runtime_not_detected") }
if (-not $ProductionHealthy) { $Blockers.Add("production_services_unhealthy") }
if ($MediaWorkers -gt 0) { $Blockers.Add("media_worker_active") }

$NativeReady = $MissingNativeTools.Count -eq 0 -and $HasOpenClHeader -and $AvailableMemoryGiB -ge 2 -and $AvailableDiskGiB -ge 2
$Assessment = if ($Blockers.Count) {
    "BLOCKED_MNN_OPENCL_PREFLIGHT"
} elseif ($ExistingMnn.Count) {
    "READY_FOR_EXISTING_MNN_OPENCL_SMOKE"
} elseif ($NativeReady) {
    "READY_FOR_NATIVE_MNN_BUILD_PLAN"
} else {
    "READY_FOR_ISOLATED_CROSS_BUILD_PLAN"
}

$Report = [ordered]@{
    schema_version = 1
    checked_at_utc = [DateTime]::UtcNow.ToString("o")
    assessment = $Assessment
    board_changed = $false
    opencl_compute_smoke_required = $true
    opencl = [ordered]@{ library = $HasOpenClLibrary; icd = $HasOpenClIcd; headers = $HasOpenClHeader }
    native_build = [ordered]@{ ready = $NativeReady; missing_tools = $MissingNativeTools }
    resources = [ordered]@{ memory_available_gib = $AvailableMemoryGiB; disk_available_gib = $AvailableDiskGiB }
    existing_mnn_artifacts = $ExistingMnn
    production = [ordered]@{ healthy = $ProductionHealthy; media_workers = $MediaWorkers }
    recommended_backend = "MNN OpenCL, isolated from the production Python venv"
    model_gate_order = @("framework_opencl_smoke", "small_onnx_gpu_inference", "CAIN_operator_export", "RIFE_lightweight_operator_export", "quality_and_performance_comparison")
    blockers = @($Blockers)
}
$Report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $JsonReport -Encoding utf8

Write-Output "OpenCL development files: library=$HasOpenClLibrary; ICD=$HasOpenClIcd; headers=$HasOpenClHeader"
Write-Output "Native build: ready=$NativeReady; missing tools=$(if ($MissingNativeTools.Count) { $MissingNativeTools -join ', ' } else { 'none' })"
Write-Output "Resources: memory available=$AvailableMemoryGiB GiB; disk available=$AvailableDiskGiB GiB"
Write-Output "Existing MNN artifacts: $($ExistingMnn.Count)"
Write-Output "Production: healthy=$ProductionHealthy; media workers=$MediaWorkers"
Write-Output "Assessment: $Assessment"
if ($Blockers.Count) { Write-Output "Blockers: $($Blockers -join ', ')" }
Write-Output "Raw report: $RawReport"
Write-Output "JSON report: $JsonReport"
Write-Output "Board changed: False"
Write-Output "RESULT=PASS_MNN_OPENCL_PREFLIGHT"

