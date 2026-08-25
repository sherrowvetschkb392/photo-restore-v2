param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string]$DatasetName,
    [string]$InputDirectory,
    [ValidateRange(1, 20)]
    [int]$MaximumImages = 8,
    [ValidateRange(1, 2000000)]
    [int]$MaxInputPixels = 2000000,
    [switch]$RestartDataset,
    [ValidateRange(10, 1800)]
    [int]$BoardWaitSeconds = 300,
    [ValidateRange(60, 7200)]
    [int]$BatchTimeoutSeconds = 1800,
    [string]$SshHost = "rk3588",
    [string]$RemoteRoot = "/userdata/photo-restore-v2"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$DependencyScript = Join-Path $PSScriptRoot "setup-board-image-deps.ps1"
$ManifestPath = Join-Path $ProjectRoot "datasets\manifests\${DatasetName}.json"
$OutputRoot = Join-Path $ProjectRoot "benchmarks\validation\${DatasetName}"
$StagingBase = Join-Path $ProjectRoot "data\validation\.staging"
$StagingRoot = Join-Path $StagingBase $DatasetName
$UploadArchive = Join-Path $StagingBase "${DatasetName}.tar"
$ResultArchive = Join-Path $StagingBase "${DatasetName}-results.tar.gz"
$ResultExtract = Join-Path $StagingBase "${DatasetName}-results"
$SshOptions = @("-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3")
$RemoteBatchRoot = "${RemoteRoot}/data/validation-batches/${DatasetName}"
$RemoteUploadArchive = "${RemoteRoot}/data/validation-batches/${DatasetName}.tar.uploading"
$RemoteResultArchive = "${RemoteRoot}/data/validation-batches/${DatasetName}-results.tar.gz"
$RemoteModel = "${RemoteRoot}/models/realesrgan_x4plus_tile96_fp16.rknn"
$RemoteStatus = "${RemoteBatchRoot}/status.json"
$RemotePid = "${RemoteBatchRoot}/batch.pid"
$RemoteLog = "${RemoteBatchRoot}/batch.log"
$RemoteRunner = "${RemoteBatchRoot}/repo/run_validation_batch.sh"
$StaleRestartLimit = 3

function Invoke-NativeChecked {
    param([scriptblock]$Command, [string]$Description)
    $PreviousErrorActionPreference = $ErrorActionPreference
    try { $ErrorActionPreference = "Continue"; & $Command; $ExitCode = $LASTEXITCODE }
    finally { $ErrorActionPreference = $PreviousErrorActionPreference }
    if ($ExitCode -ne 0) { throw "$Description failed with exit code $ExitCode" }
}

function Invoke-NativeRetry {
    param([scriptblock]$Command, [string]$Description, [int]$Attempts = 4)
    for ($Attempt = 1; $Attempt -le $Attempts; $Attempt++) {
        $PreviousErrorActionPreference = $ErrorActionPreference
        try { $ErrorActionPreference = "Continue"; & $Command; $ExitCode = $LASTEXITCODE }
        finally { $ErrorActionPreference = $PreviousErrorActionPreference }
        if ($ExitCode -eq 0) { return }
        if ($Attempt -eq $Attempts) { throw "$Description failed after $Attempts attempts; last exit code $ExitCode" }
        Write-Warning "$Description failed on attempt $Attempt; retrying..."
        Start-Sleep -Seconds ([Math]::Min(10, 2 * $Attempt))
    }
}

function Wait-ForBoardSsh {
    $Deadline = [DateTime]::UtcNow.AddSeconds($BoardWaitSeconds)
    $Attempt = 0
    while ([DateTime]::UtcNow -lt $Deadline) {
        $Attempt++
        $PreviousErrorActionPreference = $ErrorActionPreference
        try { $ErrorActionPreference = "Continue"; ssh @SshOptions -o BatchMode=yes $SshHost "true" 2>$null; $ExitCode = $LASTEXITCODE }
        finally { $ErrorActionPreference = $PreviousErrorActionPreference }
        if ($ExitCode -eq 0) { Write-Output "BOARD_SSH_READY"; return }
        if ($Attempt -eq 1 -or $Attempt % 3 -eq 0) {
            $Remaining = [Math]::Max(0, [int]($Deadline - [DateTime]::UtcNow).TotalSeconds)
            Write-Warning "RK3588 SSH is unavailable; waiting ($Remaining seconds remaining)..."
        }
        Start-Sleep -Seconds 5
    }
    throw "RK3588 SSH did not become available within $BoardWaitSeconds seconds."
}

function Get-RemoteBatchStatus {
    $PreviousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $StatusText = @(& ssh @SshOptions $SshHost "if [ ! -s '${RemoteStatus}' ]; then printf '{\"state\":\"STARTING\"}\n'; elif grep -q '\"state\": \"RUNNING\"' '${RemoteStatus}'; then if [ ! -s '${RemotePid}' ]; then printf '{\"state\":\"STALE\"}\n'; else batch_pid=`$(cat '${RemotePid}'); case `"`$batch_pid`" in *[!0-9]*|'') printf '{\"state\":\"STALE\"}\n' ;; *) if kill -0 `"`$batch_pid`" 2>/dev/null; then cat '${RemoteStatus}'; else printf '{\"state\":\"STALE\"}\n'; fi ;; esac; fi; else cat '${RemoteStatus}'; fi" 2>$null)
        $ExitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $PreviousErrorActionPreference }
    if ($ExitCode -ne 0) { return [pscustomobject]@{ state = "UNREACHABLE"; completed = 0; total = $Images.Count; current = $null; error = $null } }
    try { $Status = (($StatusText | ForEach-Object { "$_" }) -join "`n") | ConvertFrom-Json }
    catch { return [pscustomobject]@{ state = "INVALID_STATUS"; completed = 0; total = $Images.Count; current = $null; error = $_.Exception.Message } }
    return $Status
}

foreach ($RequiredCommand in @("ssh", "scp", "tar")) {
    if (-not (Get-Command $RequiredCommand -ErrorAction SilentlyContinue)) { throw "Required command is unavailable: $RequiredCommand" }
}
if ([string]::IsNullOrWhiteSpace($InputDirectory)) { $InputDirectory = Join-Path $ProjectRoot "data\validation\${DatasetName}\raw" }
$InputRoot = (Resolve-Path -LiteralPath $InputDirectory).Path
$ExpectedDataRoot = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot "data\validation"))
if (-not $InputRoot.StartsWith($ExpectedDataRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Validation inputs must stay under $ExpectedDataRoot" }
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "Dataset source/license manifest is missing: $ManifestPath" }
$Manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
if ($Manifest.dataset -ne $DatasetName -or $null -eq $Manifest.items) { throw "Dataset manifest is invalid or names a different dataset" }
$Images = @(Get-ChildItem -LiteralPath $InputRoot -File | Where-Object { $_.Extension.ToLowerInvariant() -in @(".png", ".jpg", ".jpeg") } | Sort-Object Name)
if ($Images.Count -eq 0 -or $Images.Count -gt $MaximumImages) { throw "Validation image count $($Images.Count) is outside 1..$MaximumImages" }
if (@($Manifest.items).Count -ne $Images.Count) { throw "Manifest and isolated raw directory contain different image counts" }
$SeenNames = @{}
$LegacyJobIds = @()
foreach ($Item in @($Manifest.items)) {
    if ($Item.filename -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\.(png|jpg|jpeg)$' -or $SeenNames.ContainsKey($Item.filename)) { throw "Unsafe or duplicate manifest filename: $($Item.filename)" }
    $SeenNames[$Item.filename] = $true
    foreach ($Field in @("source_page_url", "asset_url", "license", "license_url", "sha256")) { if ([string]::IsNullOrWhiteSpace($Item.$Field)) { throw "Manifest item $($Item.filename) is missing $Field" } }
    $Image = @($Images | Where-Object Name -eq $Item.filename)
    if ($Image.Count -ne 1) { throw "Manifest image is missing or duplicated locally: $($Item.filename)" }
    $ActualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Image[0].FullName).Hash.ToLowerInvariant()
    if ($ActualHash -ne $Item.sha256) { throw "SHA-256 mismatch for $($Item.filename)" }
    $LegacyJobIds += $ActualHash.Substring(0, 16)
}

New-Item -ItemType Directory -Force -Path $OutputRoot, $StagingBase | Out-Null
$OutputRoot = (Resolve-Path -LiteralPath $OutputRoot).Path
if ($RestartDataset) {
    Write-Output "Restart requested: removing only generated results for '$DatasetName'..."
    foreach ($Pattern in @("*-x4.png", "*-report.json", "summary.json", "board-batch.log", "board-status.json")) {
        foreach ($Target in @(Get-ChildItem -LiteralPath $OutputRoot -Filter $Pattern -File -ErrorAction SilentlyContinue)) {
            $FullTarget = [System.IO.Path]::GetFullPath($Target.FullName)
            if (-not $FullTarget.StartsWith($OutputRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Refusing cleanup outside dataset output root: $FullTarget" }
            Remove-Item -LiteralPath $FullTarget -Force
            Write-Output "Removed: $FullTarget"
        }
    }
}

Write-Output "Preparing one isolated batch upload..."
foreach ($Path in @($StagingRoot, $ResultExtract)) { if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force } }
foreach ($Path in @($UploadArchive, $ResultArchive)) { if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force } }
New-Item -ItemType Directory -Force -Path (Join-Path $StagingRoot "repo"), (Join-Path $StagingRoot "input") | Out-Null
Copy-Item -LiteralPath (Join-Path $ProjectRoot "apps\worker\tiling.py") -Destination (Join-Path $StagingRoot "repo\tiling.py")
Copy-Item -LiteralPath (Join-Path $ProjectRoot "apps\worker\restore_image.py") -Destination (Join-Path $StagingRoot "repo\restore_image.py")
Copy-Item -LiteralPath (Join-Path $ProjectRoot "apps\worker\validation_batch.py") -Destination (Join-Path $StagingRoot "repo\validation_batch.py")
Copy-Item -LiteralPath (Join-Path $ProjectRoot "apps\worker\run_validation_batch.sh") -Destination (Join-Path $StagingRoot "repo\run_validation_batch.sh")
Copy-Item -LiteralPath $ManifestPath -Destination (Join-Path $StagingRoot "manifest.json")
foreach ($Image in $Images) { Copy-Item -LiteralPath $Image.FullName -Destination (Join-Path $StagingRoot "input\$($Image.Name)") }
Invoke-NativeChecked { tar -cf $UploadArchive -C $StagingRoot . } "Creating the isolated validation upload archive"

Write-Output "Waiting for RK3588 SSH..."
Wait-ForBoardSsh
Write-Output "Checking board image runtime once..."
& $DependencyScript -SshHost $SshHost -RemoteRoot $RemoteRoot
Invoke-NativeRetry { ssh @SshOptions $SshHost "test -f '${RemoteModel}' && mkdir -p '${RemoteRoot}/data/validation-batches'" } "Checking the selected RKNN model"
if ($RestartDataset) {
    Write-Output "Resetting the exact previous board batch..."
    $LegacyCleanupCommands = @()
    foreach ($LegacyJobId in $LegacyJobIds) {
        $LegacyJobRoot = "${RemoteRoot}/data/jobs/${LegacyJobId}"
        $LegacyPid = "${LegacyJobRoot}/pid"
        $LegacyCleanupCommands += "if [ -s '${LegacyPid}' ]; then legacy_pid=`$(cat '${LegacyPid}'); case `"`$legacy_pid`" in *[!0-9]*|'') ;; *) kill `"`$legacy_pid`" 2>/dev/null || true ;; esac; fi; rm -rf '${LegacyJobRoot}'; rm -f '${RemoteRoot}/benchmarks/restore-${LegacyJobId}.json'"
    }
    $LegacyCleanup = $LegacyCleanupCommands -join "; "
    Invoke-NativeRetry { ssh @SshOptions $SshHost "if [ -s '${RemotePid}' ]; then batch_pid=`$(cat '${RemotePid}'); case `"`$batch_pid`" in *[!0-9]*|'') ;; *) kill `"`$batch_pid`" 2>/dev/null || true; sleep 1; kill -9 `"`$batch_pid`" 2>/dev/null || true ;; esac; fi; rm -rf '${RemoteBatchRoot}'; rm -f '${RemoteUploadArchive}' '${RemoteResultArchive}'; ${LegacyCleanup}" } "Resetting the exact RK3588 validation batch and legacy image jobs"
}

Write-Output "Uploading one batch archive ($($Images.Count) images)..."
Invoke-NativeRetry { scp @SshOptions $UploadArchive "${SshHost}:${RemoteUploadArchive}" } "Uploading the validation batch"
Invoke-NativeRetry { ssh @SshOptions $SshHost "rm -rf '${RemoteBatchRoot}'; mkdir -p '${RemoteBatchRoot}'; tar -xf '${RemoteUploadArchive}' -C '${RemoteBatchRoot}'; rm -f '${RemoteUploadArchive}'; chmod 755 '${RemoteRunner}'; '${RemoteRoot}/venv/bin/python' -m py_compile '${RemoteBatchRoot}/repo/tiling.py' '${RemoteBatchRoot}/repo/restore_image.py' '${RemoteBatchRoot}/repo/validation_batch.py'" } "Activating and checking the validation batch"

function Start-DetachedBatch {
    Invoke-NativeRetry { ssh @SshOptions $SshHost "if [ -s '${RemotePid}' ]; then p=`$(cat '${RemotePid}' 2>/dev/null); case `"`$p`" in *[!0-9]*|'') ;; *) if kill -0 `"`$p`" 2>/dev/null; then exit 0; fi ;; esac; fi; rm -f '${RemoteStatus}' '${RemoteLog}'; nohup '${RemoteRunner}' '${RemotePid}' '${RemoteRoot}/venv/bin/python' '${RemoteBatchRoot}/repo/validation_batch.py' --manifest '${RemoteBatchRoot}/manifest.json' --input-dir '${RemoteBatchRoot}/input' --output-dir '${RemoteBatchRoot}/output' --report-dir '${RemoteBatchRoot}/reports' --summary '${RemoteBatchRoot}/summary.json' --status '${RemoteStatus}' --worker '${RemoteBatchRoot}/repo/restore_image.py' --model '${RemoteModel}' --max-input-pixels '${MaxInputPixels}' > '${RemoteLog}' 2>&1 < /dev/null & for wait_step in 1 2 3 4 5 6 7 8 9 10; do if [ -s '${RemoteStatus}' ]; then break; fi; sleep 1; done; test -s '${RemoteStatus}'" } "Starting the detached validation batch"
}

Write-Output "Starting one detached board batch..."
Start-DetachedBatch

$Deadline = [DateTime]::UtcNow.AddSeconds($BatchTimeoutSeconds)
$LastDisplay = ""
$FinalStatus = $null
$StaleRestarts = 0
while ([DateTime]::UtcNow -lt $Deadline) {
    Start-Sleep -Seconds 10
    $Status = Get-RemoteBatchStatus
    $Display = "state=$($Status.state) completed=$($Status.completed)/$($Status.total) current=$($Status.current)"
    if ($Display -ne $LastDisplay -or $Status.state -eq "UNREACHABLE") { Write-Output "BOARD_BATCH_STATUS $Display"; $LastDisplay = $Display }
    if ($Status.state -eq "COMPLETE") { $FinalStatus = $Status; break }
    if ($Status.state -eq "STALE" -or $Status.state -eq "STARTING") {
        $StaleRestarts++
        if ($StaleRestarts -gt $StaleRestartLimit) { throw "Board validation batch remained stale after $StaleRestartLimit restart attempts" }
        Write-Warning "Board batch is $($Status.state) (no live worker); restarting in place (attempt $StaleRestarts/$StaleRestartLimit)..."
        Start-DetachedBatch
        $LastDisplay = ""
        continue
    }
    if ($Status.state -eq "FAILED") {
        $PreviousErrorActionPreference = $ErrorActionPreference
        try { $ErrorActionPreference = "Continue"; ssh @SshOptions $SshHost "tail -100 '${RemoteLog}'" } finally { $ErrorActionPreference = $PreviousErrorActionPreference }
        throw "Board validation batch ended in state '$($Status.state)': $($Status.error)"
    }
}
if ($null -eq $FinalStatus) { throw "Timed out after $BatchTimeoutSeconds seconds waiting for the board validation batch" }

Write-Output "Packaging and downloading all results once..."
Invoke-NativeRetry { ssh @SshOptions $SshHost "rm -f '${RemoteResultArchive}'; tar -czf '${RemoteResultArchive}' -C '${RemoteBatchRoot}' output reports summary.json batch.log status.json" } "Packaging board validation results"
Invoke-NativeRetry { scp @SshOptions "${SshHost}:${RemoteResultArchive}" $ResultArchive } "Downloading the validation result archive"
New-Item -ItemType Directory -Force -Path $ResultExtract | Out-Null
Invoke-NativeChecked { tar -xzf $ResultArchive -C $ResultExtract } "Extracting the validation result archive"

foreach ($Image in $Images) {
    $Stem = [System.IO.Path]::GetFileNameWithoutExtension($Image.Name)
    Copy-Item -LiteralPath (Join-Path $ResultExtract "output\${Stem}-x4.png") -Destination (Join-Path $OutputRoot "${Stem}-x4.png") -Force
    Copy-Item -LiteralPath (Join-Path $ResultExtract "reports\${Stem}-report.json") -Destination (Join-Path $OutputRoot "${Stem}-report.json") -Force
}
Copy-Item -LiteralPath (Join-Path $ResultExtract "summary.json") -Destination (Join-Path $OutputRoot "summary.json") -Force
Copy-Item -LiteralPath (Join-Path $ResultExtract "batch.log") -Destination (Join-Path $OutputRoot "board-batch.log") -Force
Copy-Item -LiteralPath (Join-Path $ResultExtract "status.json") -Destination (Join-Path $OutputRoot "board-status.json") -Force

$Summary = Get-Content -Raw -LiteralPath (Join-Path $OutputRoot "summary.json") | ConvertFrom-Json
if ($Summary.image_count -ne $Images.Count) { throw "Downloaded summary contains $($Summary.image_count) results, expected $($Images.Count)" }
foreach ($Result in @($Summary.results)) {
    $Output = Join-Path $OutputRoot $Result.output_name
    $ReportName = ([System.IO.Path]::GetFileNameWithoutExtension($Result.input_name)) + "-report.json"
    $Report = Join-Path $OutputRoot $ReportName
    if (-not (Test-Path -LiteralPath $Output -PathType Leaf) -or -not (Test-Path -LiteralPath $Report -PathType Leaf)) { throw "Downloaded files are incomplete for $($Result.input_name)" }
    $ActualOutputHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Output).Hash.ToLowerInvariant()
    if ($ActualOutputHash -ne $Result.output_sha256) { throw "Downloaded output SHA-256 mismatch: $($Result.output_name)" }
}

try { Invoke-NativeRetry { ssh @SshOptions $SshHost "rm -rf '${RemoteBatchRoot}'; rm -f '${RemoteResultArchive}'" } "Cleaning the completed board batch" }
catch { Write-Warning "Results are verified locally, but board cleanup was deferred: $($_.Exception.Message)" }
foreach ($Path in @($StagingRoot, $ResultExtract)) { if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force } }
foreach ($Path in @($UploadArchive, $ResultArchive)) { if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force } }

Write-Output "Summary: $(Join-Path $OutputRoot 'summary.json')"
Write-Output "RESULT=PASS_VALIDATION_DATASET"
