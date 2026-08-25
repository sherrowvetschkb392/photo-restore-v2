param(
    [string]$SshHost = "rk3588",
    [string]$RemoteRoot = "/userdata/photo-restore-v2"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$SshOptions = @("-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3")
$RemoteApp = "${RemoteRoot}/app/backend"
$Python = "${RemoteRoot}/venv/bin/python"

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
Invoke-NativeChecked { ssh @SshOptions $SshHost "mkdir -p '${RemoteApp}' '${RemoteRoot}/storage/incoming' '${RemoteRoot}/storage/jobs' '${RemoteRoot}/storage/outputs' '${RemoteRoot}/storage/reports' '${RemoteRoot}/storage/tmp' '${RemoteRoot}/database'" } "Preparing the board API directories"

Write-Output "Uploading API source and pinned requirements..."
Invoke-NativeChecked { scp @SshOptions (Join-Path $ProjectRoot "apps\server\app.py") "${SshHost}:${RemoteApp}/app.py" } "Uploading the API source"
Invoke-NativeChecked { scp @SshOptions (Join-Path $ProjectRoot "requirements-server.txt") "${SshHost}:${RemoteApp}/requirements-server.txt" } "Uploading API requirements"

Write-Output "Installing the pinned API dependencies into the project venv..."
Invoke-NativeChecked { ssh @SshOptions $SshHost "'${Python}' -m pip install -r '${RemoteApp}/requirements-server.txt'" } "Installing the API dependencies"
Invoke-NativeChecked { ssh @SshOptions $SshHost "PHOTO_RESTORE_ROOT='${RemoteRoot}' '${Python}' -m py_compile '${RemoteApp}/app.py'; cd '${RemoteApp}' && PHOTO_RESTORE_ROOT='${RemoteRoot}' '${Python}' -c 'from app import initialize, health; initialize(); print(health())'" } "Checking the API and database"

Write-Output "RESULT=PASS_WEB_API_DEPLOY"
Write-Output "Next board command:"
Write-Output "PHOTO_RESTORE_ROOT=${RemoteRoot} ${Python} -m uvicorn app:app --app-dir ${RemoteApp} --host 127.0.0.1 --port 8080"
