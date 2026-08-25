param(
    [string]$SshHost = "rk3588"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$LocalScript = Join-Path $ProjectRoot "scripts\rknn-runtime-check.py"
$RemoteScript = "/userdata/photo-restore-v2/repo/rknn-runtime-check.py"
$RemotePython = "/userdata/photo-restore-v2/venv/bin/python"

if (-not (Test-Path -LiteralPath $LocalScript)) {
    throw "Runtime check script not found: $LocalScript"
}

ssh $SshHost "mkdir -p /userdata/photo-restore-v2/repo"
scp $LocalScript "${SshHost}:${RemoteScript}"
ssh $SshHost "chmod 755 ${RemoteScript} && ${RemotePython} ${RemoteScript}"

