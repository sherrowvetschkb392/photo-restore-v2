param(
    [string]$SshHost = "rk3588",
    [string]$RemoteRoot = "/userdata/photo-restore-v2"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$UnitSource = Join-Path $ProjectRoot "config\photo-restore-api.service"
$RemoteTemporaryUnit = "${RemoteRoot}/app/backend/photo-restore-api.service.uploading"
$SshOptions = @("-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3")

function Invoke-NativeChecked {
    param([scriptblock]$Command, [string]$Description)
    $Previous = $ErrorActionPreference
    try { $ErrorActionPreference = "Continue"; & $Command; $Code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $Previous }
    if ($Code -ne 0) { throw "$Description failed with exit code $Code" }
}

Write-Output "Uploading the systemd unit..."
Invoke-NativeChecked { scp @SshOptions $UnitSource "${SshHost}:${RemoteTemporaryUnit}" } "Uploading the API systemd unit"

Write-Output "Installing and starting photo-restore-api.service..."
Invoke-NativeChecked { ssh -t @SshOptions $SshHost "sudo install -o root -g root -m 0644 '${RemoteTemporaryUnit}' /etc/systemd/system/photo-restore-api.service && rm -f '${RemoteTemporaryUnit}' && sudo systemctl daemon-reload && sudo systemctl enable --now photo-restore-api.service" } "Installing the API systemd service"

Write-Output "Checking service state and local health endpoint..."
Invoke-NativeChecked { ssh @SshOptions $SshHost "systemctl is-enabled photo-restore-api.service && systemctl is-active photo-restore-api.service && curl --fail --silent --show-error http://127.0.0.1:8080/api/health" } "Checking the API service"

Write-Output "RESULT=PASS_WEB_API_SERVICE"
