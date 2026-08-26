param(
    [string]$SshHost = "rk3588",
    [string]$RemoteRoot = "/userdata/photo-restore-v2"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$SshOptions = @("-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3")
$RemoteApp = "${RemoteRoot}/app/backend"
$Python = "${RemoteRoot}/venv/bin/python"
$RemoteWorker = "${RemoteRoot}/app/worker"
$RemoteFrontend = "${RemoteRoot}/app/frontend"
$UnitSource = Join-Path $ProjectRoot "config\photo-restore-api.service"
$RemoteUnitUpload = "${RemoteApp}/photo-restore-api.service.uploading"
$RemoteServerTest = "${RemoteRoot}/storage/tmp/test-server-uploading.py"

function Invoke-NativeChecked {
    param([scriptblock]$Command, [string]$Description)
    $Previous = $ErrorActionPreference
    try { $ErrorActionPreference = "Continue"; & $Command; $Code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $Previous }
    if ($Code -ne 0) { throw "$Description failed with exit code $Code" }
}

foreach ($Command in @("ssh", "scp")) {
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) { throw "Required command unavailable: $Command" }
}

$FrontendCss = Get-Content (Join-Path $ProjectRoot "apps\frontend\app.css") -Raw
$FrontendJs = Get-Content (Join-Path $ProjectRoot "apps\frontend\app.js") -Raw
if ($FrontendCss -match "object-fit\s*:\s*fill" -or $FrontendCss -notmatch "object-fit\s*:\s*contain" -or $FrontendJs -notmatch "clipPath") {
    throw "Frontend comparison viewer must preserve image aspect ratio and reveal by clipping"
}
if ($FrontendJs -notmatch "input_preview_url" -or $FrontendJs -notmatch "output_preview_url") {
    throw "Frontend comparison viewer must use lightweight preview endpoints"
}
if ($FrontendJs -notmatch "accepting_uploads" -or $FrontendJs -notmatch "storage_used_bytes") {
    throw "Frontend must display production health and upload availability"
}

Write-Output "Preparing isolated board API directories..."
Invoke-NativeChecked { ssh @SshOptions $SshHost "mkdir -p '${RemoteApp}' '${RemoteWorker}' '${RemoteFrontend}' '${RemoteRoot}/storage/incoming' '${RemoteRoot}/storage/jobs' '${RemoteRoot}/storage/outputs' '${RemoteRoot}/storage/reports' '${RemoteRoot}/storage/tmp' '${RemoteRoot}/database'" } "Preparing the board API directories"

Write-Output "Uploading API source and pinned requirements..."
Invoke-NativeChecked { scp @SshOptions (Join-Path $ProjectRoot "apps\server\app.py") "${SshHost}:${RemoteApp}/app.py" } "Uploading the API source"
Invoke-NativeChecked { scp @SshOptions (Join-Path $ProjectRoot "requirements-server.txt") "${SshHost}:${RemoteApp}/requirements-server.txt" } "Uploading API requirements"
Invoke-NativeChecked { scp @SshOptions $UnitSource "${SshHost}:${RemoteUnitUpload}" } "Uploading the API systemd unit"
Invoke-NativeChecked { scp @SshOptions (Join-Path $ProjectRoot "tests\test_server.py") "${SshHost}:${RemoteServerTest}" } "Uploading isolated API tests"
foreach ($WorkerFile in @("restore_image.py", "tiling.py", "interpolate_video.py")) {
    Invoke-NativeChecked { scp @SshOptions (Join-Path $ProjectRoot "apps\worker\$WorkerFile") "${SshHost}:${RemoteWorker}/${WorkerFile}" } "Uploading worker file $WorkerFile"
}
foreach ($FrontendFile in @("index.html", "app.css", "app.js")) {
    Invoke-NativeChecked { scp @SshOptions (Join-Path $ProjectRoot "apps\frontend\$FrontendFile") "${SshHost}:${RemoteFrontend}/${FrontendFile}" } "Uploading frontend file $FrontendFile"
}

Write-Output "Installing the pinned API dependencies into the project venv..."
Invoke-NativeChecked { ssh @SshOptions $SshHost "'${Python}' -m pip install -r '${RemoteApp}/requirements-server.txt'" } "Installing the API dependencies"
Invoke-NativeChecked { ssh @SshOptions $SshHost "compile_code=0; '${Python}' -m py_compile '${RemoteApp}/app.py' '${RemoteWorker}/restore_image.py' '${RemoteWorker}/tiling.py' '${RemoteWorker}/interpolate_video.py' '${RemoteServerTest}' || compile_code=`$?; test_code=0; PHOTO_RESTORE_SERVER_SOURCE='${RemoteApp}/app.py' '${Python}' '${RemoteServerTest}' -v || test_code=`$?; rm -f '${RemoteServerTest}'; test `"`$compile_code`" -eq 0 && test `"`$test_code`" -eq 0" } "Running isolated API retention, preview, safety and database tests"

Write-Output "Installing the versioned API service configuration..."
Invoke-NativeChecked { ssh @SshOptions $SshHost "sudo install -o root -g root -m 0644 '${RemoteUnitUpload}' /etc/systemd/system/photo-restore-api.service; rm -f '${RemoteUnitUpload}'; sudo systemctl daemon-reload; sudo systemctl enable photo-restore-api.service; sudo systemctl restart photo-restore-api.service" } "Installing and restarting the API service"

Write-Output "Waiting for the deployed API to become healthy..."
Invoke-NativeChecked { ssh @SshOptions $SshHost "for wait_step in 1 2 3 4 5 6 7 8 9 10; do if curl --fail --silent http://127.0.0.1:8080/api/health; then exit 0; fi; sleep 1; done; exit 1" } "Checking the deployed API health endpoint"

Write-Output "RESULT=PASS_WEB_API_DEPLOY"
Write-Output "Service: photo-restore-api.service (127.0.0.1:8080)"
