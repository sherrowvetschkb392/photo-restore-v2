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

Write-Output "Preparing isolated board API directories..."
Invoke-NativeChecked { ssh @SshOptions $SshHost "mkdir -p '${RemoteApp}' '${RemoteWorker}' '${RemoteFrontend}' '${RemoteRoot}/storage/incoming' '${RemoteRoot}/storage/jobs' '${RemoteRoot}/storage/outputs' '${RemoteRoot}/storage/reports' '${RemoteRoot}/storage/tmp' '${RemoteRoot}/database'" } "Preparing the board API directories"

Write-Output "Uploading API source and pinned requirements..."
Invoke-NativeChecked { scp @SshOptions (Join-Path $ProjectRoot "apps\server\app.py") "${SshHost}:${RemoteApp}/app.py" } "Uploading the API source"
Invoke-NativeChecked { scp @SshOptions (Join-Path $ProjectRoot "requirements-server.txt") "${SshHost}:${RemoteApp}/requirements-server.txt" } "Uploading API requirements"
foreach ($WorkerFile in @("restore_image.py", "tiling.py")) {
    Invoke-NativeChecked { scp @SshOptions (Join-Path $ProjectRoot "apps\worker\$WorkerFile") "${SshHost}:${RemoteWorker}/${WorkerFile}" } "Uploading worker file $WorkerFile"
}
foreach ($FrontendFile in @("index.html", "app.css", "app.js")) {
    Invoke-NativeChecked { scp @SshOptions (Join-Path $ProjectRoot "apps\frontend\$FrontendFile") "${SshHost}:${RemoteFrontend}/${FrontendFile}" } "Uploading frontend file $FrontendFile"
}

Write-Output "Installing the pinned API dependencies into the project venv..."
Invoke-NativeChecked { ssh @SshOptions $SshHost "'${Python}' -m pip install -r '${RemoteApp}/requirements-server.txt'" } "Installing the API dependencies"
Invoke-NativeChecked { ssh @SshOptions $SshHost "PHOTO_RESTORE_ROOT='${RemoteRoot}' '${Python}' -m py_compile '${RemoteApp}/app.py' '${RemoteWorker}/restore_image.py' '${RemoteWorker}/tiling.py'; cd '${RemoteApp}' && PHOTO_RESTORE_ROOT='${RemoteRoot}' '${Python}' -c 'import app as module; from PIL import Image; module.initialize(); assert len(module.app.routes) >= 11; assert module.PREVIEW_MAX_EDGE == 1600; assert len(module.PUBLIC_PROCESSING_ERROR) < 100; assert not any(ord(c) in (47,92) for c in module.PUBLIC_PROCESSING_ERROR); source=module.STORAGE/bytes((116,109,112)).decode(); input_path=source/bytes((112,114,101,118,105,101,119,45,99,104,101,99,107,46,112,110,103)).decode(); output_path=source/bytes((112,114,101,118,105,101,119,45,99,104,101,99,107,46,106,112,103)).decode(); Image.new(bytes((82,71,66)).decode(),(32,24)).save(input_path); module.create_preview(input_path,output_path); assert output_path.is_file(); input_path.unlink(); output_path.unlink(); print(module.health())'" } "Checking API routes, preview generation, error sanitization, worker and database"
Invoke-NativeChecked { ssh @SshOptions $SshHost "if systemctl is-active --quiet photo-restore-api.service; then sudo systemctl restart photo-restore-api.service; fi" } "Restarting the API service after deployment"

Write-Output "Waiting for the deployed API to become healthy..."
Invoke-NativeChecked { ssh @SshOptions $SshHost "for wait_step in 1 2 3 4 5 6 7 8 9 10; do if curl --fail --silent http://127.0.0.1:8080/api/health; then exit 0; fi; sleep 1; done; exit 1" } "Checking the deployed API health endpoint"

Write-Output "RESULT=PASS_WEB_API_DEPLOY"
Write-Output "Service: photo-restore-api.service (127.0.0.1:8080)"
