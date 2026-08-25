param(
    [string]$SshHost = "rk3588"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$LocalScript = Join-Path $ProjectRoot "scripts\device-audit.sh"
$RemoteScript = "/userdata/photo-restore-v2/repo/device-audit.sh"

if (-not (Test-Path -LiteralPath $LocalScript)) {
    throw "Device audit script not found: $LocalScript"
}

ssh $SshHost "mkdir -p /userdata/photo-restore-v2/repo /userdata/photo-restore-v2/benchmarks"
scp $LocalScript "${SshHost}:${RemoteScript}"
ssh $SshHost "chmod 755 ${RemoteScript} && ${RemoteScript}"

