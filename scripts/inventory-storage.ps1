param(
    [string]$Distribution = "Ubuntu",
    [string]$LinuxRoot = "/home/ljd/photo-restore-rknn232",
    [string]$SshHost = "rk3588",
    [string]$RemoteRoot = "/userdata/photo-restore-v2"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$SshOptions = @("-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3")

function Write-Section([string]$Title) {
    Write-Output ""
    Write-Output ("=" * 72)
    Write-Output $Title
    Write-Output ("=" * 72)
}

function Format-Bytes([long]$Bytes) {
    if ($Bytes -ge 1GB) { return "{0:N2} GiB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MiB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KiB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

Write-Section "1. Windows Git workspace: $ProjectRoot"
Get-ChildItem -LiteralPath $ProjectRoot -Force |
    Where-Object Name -ne ".git" |
    ForEach-Object {
        if ($_.PSIsContainer) {
            $Size = (Get-ChildItem -LiteralPath $_.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
                Measure-Object Length -Sum).Sum
        } else {
            $Size = $_.Length
        }
        [pscustomobject]@{
            Name = $_.Name
            Type = if ($_.PSIsContainer) { "dir" } else { "file" }
            Size = Format-Bytes ([long]$Size)
        }
    } | Format-Table -AutoSize

Write-Output "Git state:"
git -C $ProjectRoot status --short
if ($LASTEXITCODE -ne 0) { throw "git status failed" }

Write-Section "2. WSL model workspace: $LinuxRoot"
wsl -d $Distribution -- bash -lc "set -e; test -d '${LinuxRoot}'; echo '[directory sizes]'; du -h -d 2 '${LinuxRoot}' | sort -h; echo; echo '[files >= 1 MiB]'; find '${LinuxRoot}' -type f -size +1M -printf '%s %p\n' | sort -nr"
if ($LASTEXITCODE -ne 0) { throw "WSL storage inventory failed" }

Write-Section "3. RK3588 runtime workspace: $RemoteRoot"
ssh @SshOptions $SshHost "set -e; test -d '${RemoteRoot}'; echo '[directory sizes]'; du -h -d 2 '${RemoteRoot}' | sort -h; echo; echo '[files >= 1 MiB]'; find '${RemoteRoot}' -type f -size +1M -printf '%s %p\n' | sort -nr; echo; echo '[filesystem]'; df -h '${RemoteRoot}'"
if ($LASTEXITCODE -ne 0) { throw "RK3588 storage inventory failed" }

Write-Output ""
Write-Output "RESULT=PASS_STORAGE_INVENTORY"

