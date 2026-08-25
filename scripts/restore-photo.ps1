param(
    [Parameter(Mandatory = $true)]
    [string]$InputImage,
    [string]$OutputImage,
    [ValidateRange(1, 2000000)]
    [int]$MaxInputPixels = 2000000,
    [switch]$KeepRemoteArtifacts,
    [switch]$SkipBoardSetup,
    [switch]$SkipWorkerSync,
    [switch]$ResetRemoteJob,
    [ValidateRange(30, 3600)]
    [int]$JobTimeoutSeconds = 900,
    [ValidateRange(10, 1800)]
    [int]$BoardWaitSeconds = 300,
    [string]$SshHost = "rk3588",
    [string]$RemoteRoot = "/userdata/photo-restore-v2"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$InputPath = (Resolve-Path -LiteralPath $InputImage).Path
$InputExtension = [System.IO.Path]::GetExtension($InputPath).ToLowerInvariant()
$SupportedExtensions = @(".png", ".jpg", ".jpeg")
$SshOptions = @("-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3")
$DependencyScript = Join-Path $PSScriptRoot "setup-board-image-deps.ps1"
$WorkerFiles = @(
    @{ Local = Join-Path $ProjectRoot "apps\worker\tiling.py"; Remote = "${RemoteRoot}/repo/tiling.py" },
    @{ Local = Join-Path $ProjectRoot "apps\worker\restore_image.py"; Remote = "${RemoteRoot}/repo/restore_image.py" },
    @{ Local = Join-Path $ProjectRoot "apps\worker\run_restore_job.sh"; Remote = "${RemoteRoot}/repo/run_restore_job.sh" }
)
$RemoteModel = "${RemoteRoot}/models/realesrgan_x4plus_tile96_fp16.rknn"

function Invoke-NativeChecked {
    param([scriptblock]$Command, [string]$Description)
    $PreviousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $Command
        $ExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
    }
    if ($ExitCode -ne 0) {
        throw "$Description failed with exit code $ExitCode"
    }
}

function Invoke-NativeRetry {
    param([scriptblock]$Command, [string]$Description, [int]$Attempts = 3)
    for ($Attempt = 1; $Attempt -le $Attempts; $Attempt++) {
        $PreviousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            & $Command
            $ExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $PreviousErrorActionPreference
        }
        if ($ExitCode -eq 0) { return }
        if ($Attempt -eq $Attempts) {
            throw "$Description failed after $Attempts attempts; last exit code $ExitCode"
        }
        Write-Warning "$Description failed on attempt $Attempt; retrying..."
        Start-Sleep -Seconds (2 * $Attempt)
    }
}

function Invoke-NativeCaptureRetry {
    param([scriptblock]$Command, [string]$Description, [int]$Attempts = 3)
    for ($Attempt = 1; $Attempt -le $Attempts; $Attempt++) {
        $PreviousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $Captured = @(& $Command)
            $ExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $PreviousErrorActionPreference
        }
        if ($ExitCode -eq 0) {
            return (($Captured | ForEach-Object { "$_" }) -join "`n").Trim()
        }
        if ($Attempt -eq $Attempts) {
            throw "$Description failed after $Attempts attempts; last exit code $ExitCode"
        }
        Write-Warning "$Description failed on attempt $Attempt; retrying..."
        Start-Sleep -Seconds (2 * $Attempt)
    }
}

function Wait-ForBoardSsh {
    $Deadline = [DateTime]::UtcNow.AddSeconds($BoardWaitSeconds)
    $Attempt = 0
    while ([DateTime]::UtcNow -lt $Deadline) {
        $Attempt++
        $PreviousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            ssh @SshOptions -o BatchMode=yes $SshHost "true" 2>$null
            $ExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $PreviousErrorActionPreference
        }
        if ($ExitCode -eq 0) {
            Write-Output "BOARD_SSH_READY"
            return
        }
        if ($Attempt -eq 1 -or $Attempt % 3 -eq 0) {
            $Remaining = [Math]::Max(0, [int]($Deadline - [DateTime]::UtcNow).TotalSeconds)
            Write-Warning "RK3588 SSH is unavailable; waiting for the board/network ($Remaining seconds remaining)..."
        }
        Start-Sleep -Seconds 5
    }
    throw "RK3588 SSH did not become available within $BoardWaitSeconds seconds. Check board power, Ethernet/Wi-Fi and IP address for '$SshHost'."
}

foreach ($RequiredCommand in @("ssh", "scp")) {
    if (-not (Get-Command $RequiredCommand -ErrorAction SilentlyContinue)) {
        throw "Required command is unavailable: $RequiredCommand"
    }
}
if ($SupportedExtensions -notcontains $InputExtension) {
    throw "Input must be PNG or JPEG: $InputPath"
}
foreach ($File in $WorkerFiles) {
    if (-not (Test-Path -LiteralPath $File.Local -PathType Leaf)) {
        throw "Required worker file is missing: $($File.Local)"
    }
}

$InputHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $InputPath).Hash.ToLowerInvariant()
$JobId = $InputHash.Substring(0, 16)
$InputStem = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
if ([string]::IsNullOrWhiteSpace($OutputImage)) {
    $OutputDirectory = Join-Path $ProjectRoot "benchmarks\restored"
    $OutputPath = Join-Path $OutputDirectory "${InputStem}-x4.png"
} else {
    $OutputPath = [System.IO.Path]::GetFullPath($OutputImage)
    $OutputDirectory = Split-Path -Parent $OutputPath
}
$OutputExtension = [System.IO.Path]::GetExtension($OutputPath).ToLowerInvariant()
if ($SupportedExtensions -notcontains $OutputExtension) {
    throw "Output must be PNG or JPEG: $OutputPath"
}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$ReportPath = Join-Path $OutputDirectory "${InputStem}-report.json"

$RemoteJob = "${RemoteRoot}/data/jobs/${JobId}"
$RemoteInput = "${RemoteJob}/input${InputExtension}"
$RemoteOutput = "${RemoteJob}/output${OutputExtension}"
$RemoteReport = "${RemoteRoot}/benchmarks/restore-${JobId}.json"
$RemoteStatus = "${RemoteJob}/status"
$RemotePid = "${RemoteJob}/pid"
$RemoteLog = "${RemoteJob}/restore.log"
$RemoteRunner = "${RemoteRoot}/repo/run_restore_job.sh"

function Get-RemoteJobState {
    $PreviousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $StateOutput = & ssh @SshOptions $SshHost "if [ ! -s '${RemoteStatus}' ]; then printf 'IDLE\n'; elif [ `"`$(cat '${RemoteStatus}')`" = RUNNING ]; then if [ -s '${RemotePid}' ]; then job_pid=`$(cat '${RemotePid}'); case `"`$job_pid`" in *[!0-9]*|'') printf 'STALE\n' ;; *) if kill -0 `"`$job_pid`" 2>/dev/null; then printf 'RUNNING\n'; else printf 'STALE\n'; fi ;; esac; else printf 'STALE\n'; fi; else cat '${RemoteStatus}'; fi" 2>$null
        $ExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
    }
    if ($ExitCode -ne 0 -or $null -eq $StateOutput) {
        return "UNREACHABLE"
    }
    return (($StateOutput | ForEach-Object { "$_" }) -join "").Trim()
}

Write-Output "Waiting for RK3588 SSH..."
Wait-ForBoardSsh
Write-Output "Checking board image runtime..."
if (-not $SkipBoardSetup) {
    & $DependencyScript -SshHost $SshHost -RemoteRoot $RemoteRoot
}

Invoke-NativeRetry {
    ssh @SshOptions $SshHost "test -f '${RemoteModel}' && mkdir -p '${RemoteRoot}/repo' '${RemoteJob}' '${RemoteRoot}/benchmarks'"
} "Checking the tile96 model and creating the board job directory"

if ($ResetRemoteJob) {
    Write-Output "Resetting previous board job artifacts: $JobId"
    Invoke-NativeRetry {
        ssh @SshOptions $SshHost "if [ -s '${RemotePid}' ]; then job_pid=`$(cat '${RemotePid}'); case `"`$job_pid`" in *[!0-9]*|'') ;; *) kill `"`$job_pid`" 2>/dev/null || true; sleep 1; kill -9 `"`$job_pid`" 2>/dev/null || true ;; esac; fi; rm -f '${RemoteInput}' '${RemoteOutput}' '${RemoteReport}' '${RemoteStatus}' '${RemotePid}' '${RemoteLog}' '${RemoteStatus}.tmp'"
    } "Resetting the exact RK3588 restoration job"
}

if (-not $SkipWorkerSync) {
    foreach ($File in $WorkerFiles) {
        Invoke-NativeRetry {
            scp @SshOptions $File.Local "${SshHost}:$($File.Remote)"
        } "Uploading $($File.Local)"
    }
    Invoke-NativeRetry {
        ssh @SshOptions $SshHost "chmod 755 '${RemoteRoot}/repo/restore_image.py' '${RemoteRunner}' && '${RemoteRoot}/venv/bin/python' -m py_compile '${RemoteRoot}/repo/tiling.py' '${RemoteRoot}/repo/restore_image.py'"
    } "Checking the board image worker"
} else {
    Invoke-NativeRetry {
        ssh @SshOptions $SshHost "test -x '${RemoteRoot}/repo/restore_image.py' && test -x '${RemoteRunner}'"
    } "Checking the synchronized board image worker"
}

$RemoteInputHash = Invoke-NativeCaptureRetry {
    ssh @SshOptions $SshHost "if [ -f '${RemoteInput}' ]; then sha256sum '${RemoteInput}' | cut -d ' ' -f 1; fi"
} "Reading the board input checksum"
if ($RemoteInputHash -eq $InputHash) {
    Write-Output "Input checksum matches; upload skipped: $InputHash"
} else {
    Write-Output "Uploading photo: $InputPath"
    Invoke-NativeRetry {
        scp @SshOptions $InputPath "${SshHost}:${RemoteInput}"
    } "Uploading the input photo"
}

$InitialState = Get-RemoteJobState
if ($InitialState -eq "COMPLETE") {
    Write-Output "Board job already complete; downloading results: $JobId"
} else {
    if ($InitialState -ne "RUNNING") {
        Write-Output "Starting detached RK3588 restoration job $JobId..."
        Invoke-NativeRetry {
            ssh @SshOptions $SshHost "if [ -s '${RemotePid}' ]; then existing_pid=`$(cat '${RemotePid}'); case `"`$existing_pid`" in *[!0-9]*|'') existing_pid='' ;; esac; fi; if [ -n `"`$existing_pid`" ] && kill -0 `"`$existing_pid`" 2>/dev/null; then exit 0; fi; if [ -s '${RemoteStatus}' ] && [ `"`$(cat '${RemoteStatus}')`" = COMPLETE ]; then exit 0; fi; rm -f '${RemoteStatus}' '${RemotePid}' '${RemoteLog}' '${RemoteOutput}' '${RemoteReport}' '${RemoteStatus}.tmp'; nohup '${RemoteRunner}' '${RemoteRoot}/venv/bin/python' '${RemoteRoot}/repo/restore_image.py' '${RemoteInput}' '${RemoteOutput}' '${RemoteModel}' '${RemoteReport}' '${MaxInputPixels}' '${RemoteStatus}' '${RemotePid}' > '${RemoteLog}' 2>&1 < /dev/null & launch_pid=`$!; for wait_step in 1 2 3 4 5 6 7 8 9 10; do if [ -s '${RemoteStatus}' ] || ! kill -0 `"`$launch_pid`" 2>/dev/null; then break; fi; sleep 1; done; test -s '${RemoteStatus}'"
        } "Starting the detached RK3588 restoration job"
    } else {
        Write-Output "Board job is still running; reconnecting to it: $JobId"
    }

    $Deadline = [DateTime]::UtcNow.AddSeconds($JobTimeoutSeconds)
    $State = $InitialState
    $LastState = ""
    while ([DateTime]::UtcNow -lt $Deadline) {
        Start-Sleep -Seconds 2
        $State = Get-RemoteJobState
        if ($State -ne $LastState -or $State -in @("UNREACHABLE", "COMPLETE")) {
            Write-Output "BOARD_JOB_STATUS=$State"
            $LastState = $State
        }
        if ($State -eq "COMPLETE") { break }
        if ($State -eq "STALE") {
            Write-Warning "The board job stopped without a result; restarting it once the board is reachable..."
            Wait-ForBoardSsh
            Invoke-NativeRetry {
                ssh @SshOptions $SshHost "rm -f '${RemoteStatus}' '${RemotePid}' '${RemoteLog}' '${RemoteOutput}' '${RemoteReport}' '${RemoteStatus}.tmp'; nohup '${RemoteRunner}' '${RemoteRoot}/venv/bin/python' '${RemoteRoot}/repo/restore_image.py' '${RemoteInput}' '${RemoteOutput}' '${RemoteModel}' '${RemoteReport}' '${MaxInputPixels}' '${RemoteStatus}' '${RemotePid}' > '${RemoteLog}' 2>&1 < /dev/null & launch_pid=`$!; for wait_step in 1 2 3 4 5 6 7 8 9 10; do if [ -s '${RemoteStatus}' ] || ! kill -0 `"`$launch_pid`" 2>/dev/null; then break; fi; sleep 1; done; test -s '${RemoteStatus}'"
            } "Restarting the detached RK3588 restoration job"
            $LastState = ""
            continue
        }
        if ($State.StartsWith("FAILED:")) {
            $PreviousErrorActionPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = "Continue"
                ssh @SshOptions $SshHost "tail -80 '${RemoteLog}'"
            } finally {
                $ErrorActionPreference = $PreviousErrorActionPreference
            }
            throw "RK3588 restoration job reported $State"
        }
    }
    if ($State -ne "COMPLETE") {
        throw "Timed out after $JobTimeoutSeconds seconds waiting for RK3588 restoration job $JobId; last state: $State"
    }
}

Invoke-NativeRetry {
    ssh @SshOptions $SshHost "tail -40 '${RemoteLog}'"
} "Reading the completed restoration log"

Invoke-NativeRetry {
    scp @SshOptions "${SshHost}:${RemoteOutput}" $OutputPath
} "Downloading the restored photo"
Invoke-NativeRetry {
    scp @SshOptions "${SshHost}:${RemoteReport}" $ReportPath
} "Downloading the restoration report"

if (-not $KeepRemoteArtifacts) {
    try {
        Invoke-NativeRetry {
            ssh @SshOptions $SshHost "rm -f '${RemoteInput}' '${RemoteOutput}' '${RemoteReport}' '${RemoteStatus}' '${RemotePid}' '${RemoteLog}' && rmdir '${RemoteJob}'"
        } "Cleaning the completed board job"
    } catch {
        Write-Warning "Results are safe locally, but board cleanup was deferred: $($_.Exception.Message)"
    }
}

Write-Output "Input: $InputPath"
Write-Output "Output: $OutputPath"
Write-Output "Report: $ReportPath"
Write-Output "RESULT=PASS_REAL_PHOTO_RESTORE"
