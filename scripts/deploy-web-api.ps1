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

Write-Output "Preparing isolated board API directories..."
Invoke-NativeChecked { ssh @SshOptions $SshHost "mkdir -p '${RemoteApp}' '${RemoteWorker}' '${RemoteRoot}/storage/incoming' '${RemoteRoot}/storage/jobs' '${RemoteRoot}/storage/outputs' '${RemoteRoot}/storage/reports' '${RemoteRoot}/storage/tmp' '${RemoteRoot}/database'" } "Preparing the board API directories"

Write-Output "Uploading API source and pinned requirements..."
Invoke-NativeChecked { scp @SshOptions (Join-Path $ProjectRoot "apps\server\app.py") "${SshHost}:${RemoteApp}/app.py" } "Uploading the API source"
Invoke-NativeChecked { scp @SshOptions (Join-Path $ProjectRoot "requirements-server.txt") "${SshHost}:${RemoteApp}/requirements-server.txt" } "Uploading API requirements"
foreach ($WorkerFile in @("restore_image.py", "tiling.py")) {
    Invoke-NativeChecked { scp @SshOptions (Join-Path $ProjectRoot "apps\worker\$WorkerFile") "${SshHost}:${RemoteWorker}/${WorkerFile}" } "Uploading worker file $WorkerFile"
}

Write-Output "Installing the pinned API dependencies into the project venv..."
Invoke-NativeChecked { ssh @SshOptions $SshHost "'${Python}' -m pip install -r '${RemoteApp}/requirements-server.txt'" } "Installing the API dependencies"
Invoke-NativeChecked { ssh @SshOptions $SshHost "PHOTO_RESTORE_ROOT='${RemoteRoot}' '${Python}' -m py_compile '${RemoteApp}/app.py' '${RemoteWorker}/restore_image.py' '${RemoteWorker}/tiling.py'; cd '${RemoteApp}' && PHOTO_RESTORE_ROOT='${RemoteRoot}' '${Python}' -c 'from app import app, initialize, health; initialize(); assert len(app.routes) >= 9; print(health())'" } "Checking API routes, worker and database"
Invoke-NativeChecked { ssh @SshOptions $SshHost "if systemctl is-active --quiet photo-restore-api.service; then sudo systemctl restart photo-restore-api.service; fi" } "Restarting the API service after deployment"

Write-Output "RESULT=PASS_WEB_API_DEPLOY"
Write-Output "Service: photo-restore-api.service (127.0.0.1:8080)"
