param(
    [Parameter(Mandatory = $true)]
    [string]$InputVideo,
    [string]$OutputVideo,
    [ValidateRange(1, 3600)]
    [double]$MaxDurationSeconds = 600,
    [switch]$KeepRemoteArtifacts,
    [switch]$SyncModels,
    [ValidateRange(60, 86400)]
    [int]$JobTimeoutSeconds = 7200,
    [ValidateRange(5, 300)]
    [int]$PollSeconds = 15,
    [string]$SshHost = "rk3588",
    [string]$RemoteRoot = "/userdata/photo-restore-v2"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$InputPath = (Resolve-Path -LiteralPath $InputVideo).Path
$InputExtension = [System.IO.Path]::GetExtension($InputPath).ToLowerInvariant()
$SupportedExtensions = @(".mp4", ".mov", ".mkv", ".avi")
if ($SupportedExtensions -notcontains $InputExtension) {
    throw "unsupported input extension $InputExtension; expected one of: $($SupportedExtensions -join ', ')"
}
if (-not $OutputVideo) {
    $Stem = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
    $OutputVideo = Join-Path $ProjectRoot "benchmarks\restored-video\${Stem}-x2fps.mp4"
}
$OutputParent = Split-Path -Parent $OutputVideo
if ($OutputParent) { New-Item -ItemType Directory -Force -Path $OutputParent | Out-Null }

$WorkerLocal = Join-Path $ProjectRoot "apps\worker\interpolate_video.py"
$RemoteVideoRoot = "${RemoteRoot}/data/video-development"
$RemoteWorker = "${RemoteVideoRoot}/interpolate_video.py"
$RemoteModelDir = "${RemoteVideoRoot}/models-cain"
$ModelNames = @(
    "cain-interp-1x3x256x256-fp16.rknn",
    "cain-interp-1x3x360x640-fp16.rknn",
    "cain-interp-1x3x720x1280-fp16.rknn"
)
$WslModelDir = "~/photo-restore-rknn232/models/rknn"
$SshOptions = @("-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-o", "LogLevel=ERROR")

function Invoke-Ssh {
    param([string]$RemoteCommand)
    # Locally relax ErrorActionPreference: PowerShell 5.1 turns any native
    # stderr write into a NativeCommandError under Stop, even for warnings.
    $PreviousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $Output = @(& ssh @SshOptions $SshHost $RemoteCommand 2>$null)
        $ExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
    }
    if ($ExitCode -ne 0) {
        throw "ssh failed ($ExitCode): $($Output -join ' ')"
    }
    return (($Output | ForEach-Object { "$_" }) -join "`n").Trim()
}

Write-Host "==> validating input"
$InputHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $InputPath).Hash.ToLowerInvariant()
$JobId = (Get-Date -Format "yyyyMMdd-HHmmss") + "-" + $InputHash.Substring(0, 8)
$RemoteJob = "${RemoteVideoRoot}/interp-jobs/$JobId"
Write-Host "    input sha256: $InputHash"
Write-Host "    remote job:   $RemoteJob"

if ($SyncModels) {
    Write-Host "==> syncing CAIN RKNN models from WSL (one-time, ~320 MB)"
    Invoke-Ssh "mkdir -p '$RemoteModelDir'" | Out-Null
    foreach ($Name in $ModelNames) {
        & wsl -e bash -lc "cat $WslModelDir/$Name" | & ssh @SshOptions $SshHost "cat > '$RemoteModelDir/$Name'"
        if ($LASTEXITCODE -ne 0) { throw "model upload failed for $Name" }
        Write-Host "    uploaded $Name"
    }
}

Write-Host "==> checking remote models"
$Missing = Invoke-Ssh "for f in $($ModelNames -join ' '); do [ -s '$RemoteModelDir/'`$f ] || echo `$f; done"
if ($Missing) {
    throw "missing board models: $Missing. Rerun with -SyncModels to upload them from WSL."
}

Write-Host "==> uploading worker and input video"
Invoke-Ssh "mkdir -p '$RemoteJob'" | Out-Null
& scp @SshOptions $WorkerLocal "${SshHost}:${RemoteWorker}" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "worker upload failed" }
& scp @SshOptions $InputPath "${SshHost}:${RemoteJob}/input${InputExtension}" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "input upload failed" }

Write-Host "==> starting detached interpolation job"
$RemoteInput = "$RemoteJob/input${InputExtension}"
$VenvPython = "${RemoteRoot}/venv/bin/python3"
$StartCmd = "cd '$RemoteJob' && nohup $VenvPython '$RemoteWorker' --input '$RemoteInput' --output '$RemoteJob/output-x2fps.mp4' --model-dir '$RemoteModelDir' --work-dir '$RemoteJob' --report '$RemoteJob/report.json' --max-duration-seconds $MaxDurationSeconds > run.log 2>&1 < /dev/null & echo started"
Invoke-Ssh $StartCmd | Out-Null

Write-Host "==> polling job progress"
$Deadline = (Get-Date).AddSeconds($JobTimeoutSeconds)
$LastPhase = ""
while ((Get-Date) -lt $Deadline) {
    Start-Sleep -Seconds $PollSeconds
    $Progress = ""
    try { $Progress = Invoke-Ssh "cat '$RemoteJob/progress.json' 2>/dev/null || true" } catch { }
    if ($Progress) {
        try { $State = $Progress | ConvertFrom-Json } catch { $State = $null }
        if ($State) {
            $Line = "    phase=$($State.phase) result=$($State.result) input=$($State.input_frames) output=$($State.output_frames) cuts=$($State.scene_cuts) static=$($State.static_pairs)"
            if ($Line -ne $LastPhase) { Write-Host $Line; $LastPhase = $Line }
            if ($State.result -eq "PASS" -or $State.result -eq "FAIL" -or $State.phase -eq "done") { break }
        }
    }
    $Alive = Invoke-Ssh "pgrep -f 'interpolate_video.py' >/dev/null && echo yes || echo no"
    if ($Alive -ne "yes" -and (-not $State -or $State.result -eq "RUNNING")) {
        Start-Sleep -Seconds 5
        $Progress = Invoke-Ssh "cat '$RemoteJob/progress.json' 2>/dev/null || true"
        if ($Progress) { try { $State = $Progress | ConvertFrom-Json } catch { $State = $null } }
        if (-not $State -or $State.result -eq "RUNNING") {
            Write-Warning "worker exited unexpectedly; remote run.log tail:"
            Invoke-Ssh "tail -20 '$RemoteJob/run.log' 2>/dev/null || true" | ForEach-Object { Write-Warning "    $_" }
            throw "interpolation worker crashed; remote artifacts kept at $RemoteJob"
        }
        break
    }
}
if ((Get-Date) -ge $Deadline) { throw "job timed out after $JobTimeoutSeconds seconds; remote artifacts kept at $RemoteJob" }
if (-not $State -or $State.result -ne "PASS") {
    Invoke-Ssh "tail -20 '$RemoteJob/run.log' 2>/dev/null || true" | ForEach-Object { Write-Warning "    $_" }
    throw "job did not pass; remote artifacts kept at $RemoteJob"
}

Write-Host "==> downloading verified output and report"
& scp @SshOptions "${SshHost}:${RemoteJob}/output-x2fps.mp4" $OutputVideo | Out-Null
if ($LASTEXITCODE -ne 0) { throw "output download failed" }
$ReportLocal = Join-Path $OutputParent (([System.IO.Path]::GetFileNameWithoutExtension($OutputVideo)) + "-report.json")
& scp @SshOptions "${SshHost}:${RemoteJob}/report.json" $ReportLocal | Out-Null
if ($LASTEXITCODE -ne 0) { throw "report download failed" }

$Report = Get-Content -Raw -LiteralPath $ReportLocal | ConvertFrom-Json
$LocalHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $OutputVideo).Hash.ToLowerInvariant()
if ($LocalHash -ne $Report.output.sha256) {
    throw "downloaded output sha256 mismatch: local=$LocalHash remote=$($Report.output.sha256)"
}

if (-not $KeepRemoteArtifacts) {
    Invoke-Ssh "rm -rf -- '$RemoteJob'" | Out-Null
    Write-Host "==> remote job cleaned"
}

Write-Host ""
Write-Host "RESULT=PASS_VIDEO_INTERPOLATION"
Write-Host "output: $OutputVideo"
Write-Host "report: $ReportLocal"
Write-Host ("frames: {0} -> {1} ({2} model mids, {3} cuts, {4} static), total {5}s" -f
    $Report.counts.input_frames, $Report.counts.output_frames, $Report.counts.model_mids,
    $Report.counts.scene_cuts, $Report.counts.static_pairs, $Report.timing_seconds.total)
