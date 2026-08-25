param(
    [string]$SshHost = "rk3588",
    [string]$RemoteRoot = "/userdata/photo-restore-v2",
    [switch]$Restart,
    [switch]$Cleanup,
    [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$WorkerSource = Join-Path $ProjectRoot "apps\worker\video_codec_smoke.py"
$RemoteDirectory = "${RemoteRoot}/data/video-development/codec-smoke-640x360"
$RemoteWorker = "${RemoteDirectory}/video_codec_smoke.py"
$RemoteWork = "${RemoteDirectory}/work"
$RemoteReport = "${RemoteWork}/report.json"
$RemoteOutput = "${RemoteWork}/mpp-codec-smoke-640x360.mp4"
$LocalDirectory = Join-Path $ProjectRoot "benchmarks\video-codec-smoke"
$LocalReport = Join-Path $LocalDirectory "report.json"
$LocalOutput = Join-Path $LocalDirectory "mpp-codec-smoke-640x360.mp4"
$SshOptions = @(
    "-o", "ConnectTimeout=10",
    "-o", "ServerAliveInterval=15",
    "-o", "ServerAliveCountMax=3"
)

function Assert-SafePaths {
    if ($RemoteRoot -ne "/userdata/photo-restore-v2") {
        throw "RemoteRoot must remain the isolated project root: /userdata/photo-restore-v2"
    }
    if ($RemoteDirectory -ne "/userdata/photo-restore-v2/data/video-development/codec-smoke-640x360") {
        throw "Unexpected remote codec-smoke directory: $RemoteDirectory"
    }
}

function Invoke-NativeChecked {
    param([scriptblock]$Command, [string]$Description)
    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $Lines = @(& $Command 2>&1)
        $Code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $Previous
    }
    if ($Lines.Count) { $Lines | ForEach-Object { Write-Output "$_" } }
    if ($Code -ne 0) { throw "$Description failed with exit code $Code" }
}

function Invoke-SshCapture {
    param([string]$RemoteCommand, [string]$Description)
    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $Lines = @(& ssh @SshOptions $SshHost $RemoteCommand 2>&1)
        $Code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $Previous
    }
    if ($Code -ne 0) {
        throw "$Description failed with exit code $Code`n$($Lines -join "`n")"
    }
    return (($Lines | ForEach-Object { "$_" }) -join "`n").Trim()
}

Assert-SafePaths
foreach ($Command in @("ssh", "scp")) {
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        throw "Required command is unavailable: $Command"
    }
}
if (-not (Test-Path -LiteralPath $WorkerSource -PathType Leaf)) {
    throw "Video codec smoke worker is missing: $WorkerSource"
}

if ($ValidateOnly) {
    Write-Output "Remote directory: $RemoteDirectory"
    Write-Output "Local report: $LocalReport"
    Write-Output "Local output: $LocalOutput"
    Write-Output "RESULT=PASS_VIDEO_CODEC_SMOKE_PREFLIGHT"
    return
}

if ($Cleanup) {
    Write-Output "Removing only the isolated board codec-smoke directory..."
    Invoke-NativeChecked {
        ssh @SshOptions $SshHost "test '${RemoteDirectory}' = '/userdata/photo-restore-v2/data/video-development/codec-smoke-640x360' && rm -rf -- '${RemoteDirectory}'"
    } "Cleaning the isolated board codec-smoke directory"
    Write-Output "RESULT=PASS_VIDEO_CODEC_SMOKE_CLEANUP"
    return
}

Write-Output "Checking that production services remain healthy and no media task is active..."
$Safety = Invoke-SshCapture `
    "export LC_ALL=C LANG=C GST_REGISTRY_UPDATE=no; test `"`$(systemctl is-active photo-restore-api.service)`" = active; test `"`$(systemctl is-active cloudflared.service)`" = active; test `"`$(pgrep -fc '^${RemoteRoot}/venv/bin/python ${RemoteRoot}/app/worker/restore_image.py ' || true)`" -eq 0; test `"`$(pgrep -fc '(^|/)ffmpeg([[:space:]]|$)' || true)`" -eq 0; test `"`$(pgrep -fc '(^|/)gst-launch-1.0([[:space:]]|$)' || true)`" -eq 0; command -v ffmpeg; command -v ffprobe; command -v gst-launch-1.0; gst-inspect-1.0 mpph264enc >/dev/null 2>&1; gst-inspect-1.0 mppvideodec >/dev/null 2>&1; printf 'CODEC_SMOKE_SAFETY_OK\n'" `
    "Checking codec-smoke safety prerequisites"
Write-Output $Safety

$Existing = Invoke-SshCapture `
    "if test -f '${RemoteReport}'; then printf 'REPORT_PRESENT\n'; elif test -d '${RemoteDirectory}'; then printf 'INCOMPLETE\n'; else printf 'ABSENT\n'; fi" `
    "Checking an existing codec-smoke run"
if ($Existing -eq "REPORT_PRESENT" -and -not $Restart) {
    Write-Output "A completed board codec smoke result already exists; downloading it without rerunning hardware work."
} elseif ($Existing -eq "INCOMPLETE" -and -not $Restart) {
    throw "An incomplete isolated codec-smoke directory exists. Inspect it, then rerun with -Restart or remove it with -Cleanup."
} else {
    if ($Restart) {
        Write-Output "Restart requested: resetting only the isolated codec-smoke directory..."
        Invoke-NativeChecked {
            ssh @SshOptions $SshHost "test '${RemoteDirectory}' = '/userdata/photo-restore-v2/data/video-development/codec-smoke-640x360' && rm -rf -- '${RemoteDirectory}'"
        } "Resetting the isolated codec-smoke directory"
    }
    Write-Output "Preparing and uploading the isolated codec-smoke worker..."
    Invoke-NativeChecked {
        ssh @SshOptions $SshHost "mkdir -p '${RemoteDirectory}' '${RemoteWork}'"
    } "Preparing the isolated codec-smoke directory"
    Invoke-NativeChecked {
        scp @SshOptions $WorkerSource "${SshHost}:${RemoteWorker}"
    } "Uploading the codec-smoke worker"

    Write-Output "Running MPP hardware encode, hardware decode, MP4/AAC mux and ffprobe verification..."
    Invoke-NativeChecked {
        ssh @SshOptions $SshHost "'${RemoteRoot}/venv/bin/python' '${RemoteWorker}' --work-dir '${RemoteWork}' --report '${RemoteReport}'"
    } "Running the isolated hardware codec smoke test"
}

Write-Output "Downloading the verified report and playable sample..."
New-Item -ItemType Directory -Force -Path $LocalDirectory | Out-Null
Invoke-NativeChecked {
    scp @SshOptions "${SshHost}:${RemoteReport}" $LocalReport
} "Downloading the codec-smoke report"
Invoke-NativeChecked {
    scp @SshOptions "${SshHost}:${RemoteOutput}" $LocalOutput
} "Downloading the codec-smoke MP4"

$Report = Get-Content -LiteralPath $LocalReport -Raw | ConvertFrom-Json
if ($Report.result -ne "PASS") { throw "Codec-smoke report is not PASS" }
if ($Report.pipeline.encoder -ne "mpph264enc" -or $Report.pipeline.decoder -ne "mppvideodec") {
    throw "Codec-smoke report did not use the required MPP encoder/decoder"
}
if ($Report.verified_output.video_codec -ne "h264" -or $Report.verified_output.audio_codec -ne "aac") {
    throw "Codec-smoke output codecs are unexpected"
}
if ($Report.verified_output.width -ne 640 -or $Report.verified_output.height -ne 360) {
    throw "Codec-smoke output dimensions are unexpected"
}
if ($Report.verified_output.decoded_frame_count -lt 298 -or $Report.verified_output.decoded_frame_count -gt 302) {
    throw "Codec-smoke decoded frame count is unexpected"
}
$LocalOutputHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $LocalOutput).Hash.ToLowerInvariant()
if ($LocalOutputHash -ne $Report.artifacts.output_mp4_sha256) {
    throw "Downloaded MP4 SHA-256 does not match the board report"
}

Write-Output "Pipeline: $($Report.pipeline.encoder) -> $($Report.pipeline.decoder); mux=$($Report.pipeline.container_mux)"
Write-Output "Output: $($Report.verified_output.width)x$($Report.verified_output.height) $($Report.verified_output.frame_rate) fps; frames=$($Report.verified_output.decoded_frame_count); duration=$($Report.verified_output.duration_seconds)s"
Write-Output "Audio: $($Report.verified_output.audio_codec) $($Report.verified_output.audio_sample_rate) Hz"
Write-Output "Timing: encode=$($Report.timing_seconds.hardware_encode)s decode=$($Report.timing_seconds.hardware_decode)s total=$($Report.timing_seconds.total)s"
Write-Output "Sample: $LocalOutput"
Write-Output "Report: $LocalReport"
Write-Output "RESULT=PASS_VIDEO_CODEC_SMOKE_DEPLOY"
