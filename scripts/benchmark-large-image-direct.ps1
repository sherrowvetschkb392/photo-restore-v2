param(
    [ValidateRange(64, 3000)]
    [int]$Width = 2000,
    [ValidateRange(64, 3000)]
    [int]$Height = 1500,
    [ValidateRange(120, 3600)]
    [int]$TimeoutSeconds = 1200,
    [ValidateRange(60, 600)]
    [int]$StallTimeoutSeconds = 120,
    [string]$Distribution = "Ubuntu",
    [string]$CondaEnvironment = "photo-restore-rknn232",
    [string]$SshHost = "rk3588",
    [string]$RemoteRoot = "/userdata/photo-restore-v2",
    [switch]$ValidateOnly,
    [switch]$RestartBenchmark,
    [switch]$Cleanup,
    [switch]$AcknowledgeDriverResetRisk
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$PixelCount = [int64]$Width * [int64]$Height
if ($PixelCount -gt 3000000) {
    throw "Direct tier-3 benchmark is capped at 3,000,000 pixels; requested $PixelCount"
}
if ($PixelCount -le 2000000) {
    throw "Direct tier-3 benchmark must exceed the 2,000,000-pixel public limit; requested $PixelCount"
}

$Generator = Join-Path $ProjectRoot "tools\make_prototype_image.py"
$Runner = Join-Path $PSScriptRoot "run-large-image-benchmark.sh"
$InputDirectory = Join-Path $ProjectRoot "data\benchmarks\large-image"
$BenchmarkDirectory = Join-Path $ProjectRoot "benchmarks\large-image"
$InputImage = Join-Path $InputDirectory "benchmark-${Width}x${Height}.png"
$LocalReport = Join-Path $BenchmarkDirectory "benchmark-${Width}x${Height}-direct-report.json"
$LocalPreview = Join-Path $BenchmarkDirectory "benchmark-${Width}x${Height}-preview.jpg"
$LocalSummary = Join-Path $BenchmarkDirectory "benchmark-${Width}x${Height}-direct-summary.json"
$RemoteJob = "${RemoteRoot}/data/benchmarks/large-image-${Width}x${Height}"
$RemoteInput = "${RemoteJob}/input.png"
$RemoteOutput = "${RemoteJob}/output.png"
$RemotePreview = "${RemoteJob}/preview.jpg"
$RemoteReport = "${RemoteJob}/report.json"
$RemoteStatus = "${RemoteJob}/status"
$RemotePid = "${RemoteJob}/pid"
$RemoteLog = "${RemoteJob}/benchmark.log"
$RemoteWork = "${RemoteJob}/work"
$RemoteRunner = "${RemoteJob}/run-large-image-benchmark.sh"
$RemoteUnit = "photo-restore-benchmark-${Width}x${Height}.service"
$RemotePython = "${RemoteRoot}/venv/bin/python"
$RemoteWorker = "${RemoteRoot}/app/worker/restore_image.py"
$RemoteModel = "${RemoteRoot}/models/realesrgan_x4plus_tile96_fp16.rknn"
$SshOptions = @("-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3")

function Convert-ToWslPath([string]$WindowsPath) {
    if ($WindowsPath -notmatch '^(?<drive>[A-Za-z]):\\(?<path>.*)$') {
        throw "Unsupported Windows path: $WindowsPath"
    }
    $Drive = $Matches['drive'].ToLowerInvariant()
    $RelativePath = $Matches['path'].Replace('\', '/')
    return "/mnt/${Drive}/${RelativePath}"
}

function Invoke-NativeChecked {
    param([scriptblock]$Command, [string]$Description)
    $Previous = $ErrorActionPreference
    try { $ErrorActionPreference = "Continue"; & $Command; $Code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $Previous }
    if ($Code -ne 0) { throw "$Description failed with exit code $Code" }
}

function Stop-RemoteBenchmarkUnit {
    param([string]$Description)
    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & ssh @SshOptions $SshHost "sudo -n systemctl stop --no-block '${RemoteUnit}' 2>/dev/null || true; for stop_step in 1 2 3 4 5 6 7 8 9 10; do sudo -n systemctl is-active --quiet '${RemoteUnit}' 2>/dev/null || break; sleep 1; done; sudo -n systemctl kill --kill-who=all --signal=KILL '${RemoteUnit}' 2>/dev/null || true; sleep 1; if pgrep -f '^${RemotePython} ${RemoteWorker} --input ${RemoteInput} ' >/dev/null 2>&1; then printf 'DRIVER_RESET_REQUIRED\n'; exit 75; fi; sudo -n systemctl is-active --quiet '${RemoteUnit}' 2>/dev/null && exit 75 || exit 0"
        $Code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $Previous
    }
    if ($Code -eq 75) {
        throw "$Description could not stop the RKNN worker. The NPU driver is stuck; reboot the RK3588 before further inference."
    }
    if ($Code -ne 0) { throw "$Description failed with exit code $Code" }
}

foreach ($RequiredCommand in @("wsl", "ssh", "scp")) {
    if (-not (Get-Command $RequiredCommand -ErrorAction SilentlyContinue)) {
        throw "Required command is unavailable: $RequiredCommand"
    }
}

if ($Cleanup) {
    Write-Output "Cleaning only the isolated ${Width}x${Height} benchmark..."
    Stop-RemoteBenchmarkUnit "Stopping the isolated benchmark service"
    Invoke-NativeChecked {
        ssh @SshOptions $SshHost "sudo -n systemctl reset-failed '${RemoteUnit}' 2>/dev/null || true; case '${RemoteJob}' in '${RemoteRoot}/data/benchmarks/'*) rm -rf '${RemoteJob}' ;; *) exit 76 ;; esac; test ! -e '${RemoteJob}'"
    } "Cleaning the exact board benchmark directory"
    Write-Output "RESULT=PASS_LARGE_IMAGE_DIRECT_CLEANUP"
    return
}

foreach ($RequiredFile in @($Generator, $Runner)) {
    if (-not (Test-Path -LiteralPath $RequiredFile -PathType Leaf)) {
        throw "Required file is missing: $RequiredFile"
    }
}

$WslGenerator = Convert-ToWslPath $Generator
$WslInput = Convert-ToWslPath $InputImage
if ($ValidateOnly) {
    Write-Output "Input pixels: $PixelCount"
    Write-Output "Input WSL path: $WslInput"
    Write-Output "Remote job: $RemoteJob"
    Write-Output "WARNING=Inputs above 2,000,000 pixels can hang RKNN Runtime 2.3.2 and require a board reboot"
    Write-Output "RESULT=PASS_LARGE_IMAGE_DIRECT_PREFLIGHT"
    return
}

if (-not $AcknowledgeDriverResetRisk) {
    throw "Direct tests above 2,000,000 pixels are disabled by default because the 3 MP test hung RKNN Runtime 2.3.2 and required a board reboot. Use -AcknowledgeDriverResetRisk only for an intentional isolated driver test."
}

New-Item -ItemType Directory -Force -Path $InputDirectory, $BenchmarkDirectory | Out-Null
foreach ($GeneratedPath in @($LocalReport, $LocalPreview, $LocalSummary)) {
    if (Test-Path -LiteralPath $GeneratedPath) {
        Remove-Item -LiteralPath $GeneratedPath -Force
    }
}

Write-Output "Generating isolated benchmark image: ${Width}x${Height} ($PixelCount pixels)..."
Invoke-NativeChecked {
    wsl -d $Distribution -- bash -lc "set -e; source /home/ljd/miniconda3/etc/profile.d/conda.sh; conda activate '${CondaEnvironment}'; python '${WslGenerator}' --output '${WslInput}' --width '${Width}' --height '${Height}'"
} "Generating the tier-3 benchmark fixture"

Write-Output "Checking for an existing isolated board benchmark..."
$Previous = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    $ProbeLines = @(& ssh @SshOptions $SshHost "if [ -s '${RemoteStatus}' ]; then state=`$(cat '${RemoteStatus}'); else state=NONE; fi; if [ `"`$state`" = RUNNING ]; then alive=false; if sudo -n systemctl is-active --quiet '${RemoteUnit}' 2>/dev/null; then alive=true; elif [ -s '${RemotePid}' ]; then p=`$(cat '${RemotePid}'); case `"`$p`" in *[!0-9]*|'') ;; *) kill -0 `"`$p`" 2>/dev/null && alive=true ;; esac; fi; if `"`$alive`"; then printf 'RUNNING\n'; else printf 'STALE\n'; fi; else printf '%s\n' `"`$state`"; fi" 2>$null)
    $ProbeCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $Previous
}
if ($ProbeCode -ne 0) { throw "Reading the existing board benchmark state failed with exit code $ProbeCode" }
$ExistingState = (($ProbeLines | ForEach-Object { "$_" }) -join "").Trim()

if ($RestartBenchmark) {
    if ($ExistingState -eq "RUNNING") {
        throw "The board benchmark is still running. Wait for completion before using -RestartBenchmark."
    }
    Stop-RemoteBenchmarkUnit "Stopping the previous benchmark service"
    Invoke-NativeChecked { ssh @SshOptions $SshHost "sudo -n systemctl reset-failed '${RemoteUnit}' 2>/dev/null || true" } "Resetting the inactive benchmark service"
    $ExistingState = "NONE"
}

if ($ExistingState -in @("RUNNING", "COMPLETE")) {
    Write-Output "Resuming existing board benchmark: $ExistingState"
} elseif ($ExistingState -eq "STALE") {
    Write-Output "Existing benchmark status is stale; auditing generated artifacts and logs..."
    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $AuditLines = @(& ssh @SshOptions $SshHost "export LC_ALL=C LANG=C; if [ -s '${RemoteOutput}' ] && [ -s '${RemotePreview}' ] && [ -s '${RemoteReport}' ]; then printf 'RECOVERABLE_COMPLETE\n'; else printf 'INCOMPLETE\n'; fi; printf '%s\n' '---SERVICE---'; sudo -n systemctl status '${RemoteUnit}' --no-pager -l 2>&1 || true; printf '%s\n' '---FILES---'; ls -lh '${RemoteJob}' 2>/dev/null || true; printf '%s\n' '---MEMORY---'; free -h 2>/dev/null || true; printf '%s\n' '---DISK---'; df -h '${RemoteRoot}' 2>/dev/null || true; printf '%s\n' '---LOG---'; tail -80 '${RemoteLog}' 2>/dev/null || true; printf '%s\n' '---SERVICE-LOG---'; sudo -n journalctl -u '${RemoteUnit}' -n 80 --no-pager 2>&1 || true" 2>&1)
        $AuditCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $Previous
    }
    $AuditText = ($AuditLines | ForEach-Object { "$_" }) -join "`n"
    Write-Output $AuditText
    if ($AuditCode -eq 0 -and $AuditLines.Count -gt 0 -and [string]$AuditLines[0] -eq "RECOVERABLE_COMPLETE") {
        Write-Output "All required artifacts exist; recovering the completed benchmark."
        $ExistingState = "COMPLETE"
    } else {
        throw "Existing benchmark is incomplete. The audit above was preserved; use -RestartBenchmark only after reviewing it."
    }
} elseif ($ExistingState -like "FAILED:*") {
    throw "Existing benchmark ended with $ExistingState. Inspect '${RemoteLog}', then rerun with -RestartBenchmark."
} else {
    Write-Output "Preparing the exact board benchmark directory..."
    Invoke-NativeChecked {
        ssh @SshOptions $SshHost "sudo -n systemctl reset-failed '${RemoteUnit}' 2>/dev/null || true; case '${RemoteJob}' in '${RemoteRoot}/data/benchmarks/'*) rm -rf '${RemoteJob}' ;; *) exit 76 ;; esac; mkdir -p '${RemoteWork}'; test -x '${RemotePython}' && test -f '${RemoteWorker}' && test -f '${RemoteModel}'; sudo -n systemd-run --version >/dev/null"
    } "Preparing the isolated board benchmark"

    Write-Output "Uploading the benchmark runner and input once..."
    Invoke-NativeChecked { scp @SshOptions $Runner "${SshHost}:${RemoteRunner}" } "Uploading the benchmark runner"
    Invoke-NativeChecked { scp @SshOptions $InputImage "${SshHost}:${RemoteInput}" } "Uploading the benchmark input"

    Write-Output "Starting a detached RK3588 benchmark..."
    Invoke-NativeChecked {
        ssh @SshOptions $SshHost "chmod 755 '${RemoteRunner}'; : > '${RemoteLog}'; board_uid=`$(id -u); board_gid=`$(id -g); sudo -n systemd-run --unit='${RemoteUnit}' --property=Type=exec --property=User=`"`$board_uid`" --property=Group=`"`$board_gid`" --property=WorkingDirectory='${RemoteJob}' --property=KillMode=control-group --property=TimeoutStopSec=15s --property=SendSIGKILL=yes --property=StandardOutput=append:'${RemoteLog}' --property=StandardError=append:'${RemoteLog}' '${RemoteRunner}' '${RemotePython}' '${RemoteWorker}' '${RemoteInput}' '${RemoteOutput}' '${RemotePreview}' '${RemoteModel}' '${RemoteReport}' '${PixelCount}' '${RemoteWork}' '${RemoteStatus}' '${RemotePid}'; for wait_step in 1 2 3 4 5 6 7 8 9 10; do if [ -s '${RemoteStatus}' ]; then break; fi; if ! sudo -n systemctl is-active --quiet '${RemoteUnit}'; then break; fi; sleep 1; done; test -s '${RemoteStatus}'; sudo -n systemctl is-active --quiet '${RemoteUnit}'"
    } "Starting the detached tier-3 benchmark"
}

$Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$LastState = ""
$LastProgress = ""
$LastHeartbeat = [DateTime]::MinValue
$PollingStarted = [DateTime]::UtcNow
$LastProgressChangedAt = $PollingStarted
$FinalState = ""
while ([DateTime]::UtcNow -lt $Deadline) {
    Start-Sleep -Seconds 5
    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $StateLines = @(& ssh @SshOptions $SshHost "if [ -s '${RemoteStatus}' ]; then state=`$(cat '${RemoteStatus}'); else state=UNKNOWN; fi; if [ `"`$state`" = RUNNING ] && ! sudo -n systemctl is-active --quiet '${RemoteUnit}' 2>/dev/null; then state=FAILED:SERVICE; fi; progress=`$(grep '^PROGRESS ' '${RemoteLog}' 2>/dev/null | tail -1); printf '%s\n' `"`$state`"; printf '%s\n' `"`$progress`"" 2>$null)
        $StateCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $Previous
    }
    if ($StateCode -ne 0) {
        if ($LastState -ne "UNREACHABLE") { Write-Output "BENCHMARK_STATUS=UNREACHABLE"; $LastState = "UNREACHABLE" }
        continue
    }
    $State = if ($StateLines.Count -gt 0) { ([string]$StateLines[0]).Trim() } else { "UNKNOWN" }
    $ProgressText = if ($StateLines.Count -gt 1) { ([string]$StateLines[1]).Trim() } else { "" }
    $Now = [DateTime]::UtcNow
    if (-not [string]::IsNullOrWhiteSpace($ProgressText) -and $ProgressText -ne $LastProgress) {
        $LastProgressChangedAt = $Now
    }
    $HeartbeatDue = ($Now - $LastHeartbeat).TotalSeconds -ge 15
    if ($State -ne $LastState -or $ProgressText -ne $LastProgress -or $HeartbeatDue) {
        $Waited = [Math]::Round(($Now - $PollingStarted).TotalSeconds)
        $ProgressSuffix = if ([string]::IsNullOrWhiteSpace($ProgressText)) { "" } else { " $ProgressText" }
        Write-Output "BENCHMARK_STATUS=$State waited=${Waited}s$ProgressSuffix"
        $LastState = $State
        $LastProgress = $ProgressText
        $LastHeartbeat = $Now
    }
    if ($State -eq "COMPLETE") { $FinalState = $State; break }
    if ($State -like "FAILED:*") { $FinalState = $State; break }
    if ($State -eq "RUNNING" -and ($Now - $LastProgressChangedAt).TotalSeconds -ge $StallTimeoutSeconds) {
        $FinalState = "STALLED"
        Write-Output "BENCHMARK_STATUS=STALLED no_progress_for=$StallTimeoutSeconds`s"
        break
    }
}
if ($FinalState -ne "COMPLETE") {
    $Previous = $ErrorActionPreference
    try { $ErrorActionPreference = "Continue"; ssh @SshOptions $SshHost "export LC_ALL=C LANG=C; printf '%s\n' '---SERVICE---'; sudo -n systemctl status '${RemoteUnit}' --no-pager -l 2>&1 || true; printf '%s\n' '---LOG---'; tail -80 '${RemoteLog}' 2>/dev/null || true; printf '%s\n' '---SERVICE-LOG---'; sudo -n journalctl -u '${RemoteUnit}' -n 80 --no-pager 2>&1 || true" }
    finally { $ErrorActionPreference = $Previous }
    if ($FinalState -eq "STALLED") {
        Stop-RemoteBenchmarkUnit "Stopping the stalled tier-3 benchmark service"
        throw "Tier-3 benchmark made no progress for $StallTimeoutSeconds seconds and was stopped; board artifacts were preserved"
    }
    if ([string]::IsNullOrWhiteSpace($FinalState)) { throw "Tier-3 benchmark timed out after $TimeoutSeconds seconds; board artifacts were preserved" }
    throw "Tier-3 benchmark ended with state $FinalState; board artifacts were preserved"
}

Write-Output "Verifying the full output on the board..."
Invoke-NativeChecked {
    ssh @SshOptions $SshHost "'${RemotePython}' -c 'import hashlib,json,sys; from pathlib import Path; from PIL import Image; report_path,output_path,preview_path=sys.argv[1:]; report=json.loads(Path(report_path).read_text()); output=Path(output_path); preview=Path(preview_path); assert report[bytes((99,111,109,112,111,115,105,116,111,114)).decode()] == bytes((100,105,115,107)).decode(); assert hashlib.sha256(output.read_bytes()).hexdigest() == report[bytes((111,117,116,112,117,116,95,115,104,97,50,53,54)).decode()]; output_image=Image.open(output); preview_image=Image.open(preview); assert output_image.size == (${Width}*4,${Height}*4); assert max(preview_image.size) <= 1600; print(output_image.size,preview_image.size,output.stat().st_size)' '${RemoteReport}' '${RemoteOutput}' '${RemotePreview}'"
} "Verifying the tier-3 output, checksum and preview"

Write-Output "Downloading only the report and lightweight preview..."
Invoke-NativeChecked { scp @SshOptions "${SshHost}:${RemoteReport}" $LocalReport } "Downloading the tier-3 report"
Invoke-NativeChecked { scp @SshOptions "${SshHost}:${RemotePreview}" $LocalPreview } "Downloading the tier-3 preview"
$Report = Get-Content -LiteralPath $LocalReport -Raw | ConvertFrom-Json
$Summary = [ordered]@{
    benchmark = "large-image-direct-tier-3"
    input_size = @($Width, $Height)
    input_pixels = $PixelCount
    output_size = @($Width * 4, $Height * 4)
    compositor = [string]$Report.compositor
    tile_count = [int]$Report.plan.tile_count
    inference_seconds = [double]$Report.inference_seconds
    total_seconds = [double]$Report.total_seconds
    input_pixels_per_second = [Math]::Round($PixelCount / [double]$Report.inference_seconds, 2)
    max_rss_kib = [int64]$Report.max_rss_kib
    raw_output_bytes = [int64]$Report.raw_output_bytes
    required_free_bytes = [int64]$Report.required_free_bytes
    preview_size = @([int]$Report.preview_size[0], [int]$Report.preview_size[1])
    public_limit_unchanged = 2000000
    report = $LocalReport
    preview = $LocalPreview
    tested_at_utc = [DateTime]::UtcNow.ToString("o")
}
$Summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $LocalSummary -Encoding utf8

Write-Output "Cleaning the verified board benchmark directory..."
Stop-RemoteBenchmarkUnit "Stopping the completed tier-3 benchmark service"
Invoke-NativeChecked {
    ssh @SshOptions $SshHost "sudo -n systemctl reset-failed '${RemoteUnit}' 2>/dev/null || true; case '${RemoteJob}' in '${RemoteRoot}/data/benchmarks/'*) rm -rf '${RemoteJob}' ;; *) exit 76 ;; esac"
} "Cleaning the exact tier-3 board benchmark"

Write-Output ($Summary | ConvertTo-Json -Depth 6)
Write-Output "Benchmark report: $LocalReport"
Write-Output "Benchmark preview: $LocalPreview"
Write-Output "Benchmark summary: $LocalSummary"
Write-Output "RESULT=PASS_LARGE_IMAGE_DIRECT_TIER3_BENCHMARK"
