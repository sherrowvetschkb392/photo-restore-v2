param(
    [string]$SshHost = "rk3588",
    [string]$RemoteRoot = "/userdata/photo-restore-v2"
)

$ErrorActionPreference = "Stop"
$SshOptions = @("-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3")
$PackageDirectory = "${RemoteRoot}/packages"
$Package = "${PackageDirectory}/cloudflared-linux-arm64.deb"
$TemporaryPackage = "${Package}.uploading"
$DownloadUrl = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb"

function Invoke-NativeChecked {
    param([scriptblock]$Command, [string]$Description)
    $Previous = $ErrorActionPreference
    try { $ErrorActionPreference = "Continue"; & $Command; $Code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $Previous }
    if ($Code -ne 0) { throw "$Description failed with exit code $Code" }
}

Write-Output "Checking for an existing cloudflared installation..."
$Existing = & ssh @SshOptions $SshHost "if command -v cloudflared >/dev/null 2>&1; then cloudflared --version; fi"
if ($LASTEXITCODE -ne 0) { throw "Checking cloudflared failed" }
if (-not [string]::IsNullOrWhiteSpace(($Existing -join "`n"))) {
    Write-Output ($Existing -join "`n")
    Write-Output "cloudflared is already installed; no changes made."
    Write-Output "RESULT=PASS_CLOUDFLARED_INSTALL"
    exit 0
}

Write-Output "Downloading the official Cloudflare ARM64 package into the project package cache..."
Invoke-NativeChecked { ssh @SshOptions $SshHost "mkdir -p '${PackageDirectory}'; rm -f '${TemporaryPackage}'; curl --location --fail --show-error --retry 3 --connect-timeout 15 '${DownloadUrl}' -o '${TemporaryPackage}'; test `"`$(dpkg-deb -f '${TemporaryPackage}' Architecture)`" = arm64; test `"`$(dpkg-deb -f '${TemporaryPackage}' Package)`" = cloudflared; mv -f '${TemporaryPackage}' '${Package}'; sha256sum '${Package}'; dpkg-deb -f '${Package}' Version Architecture" } "Downloading and validating cloudflared"

Write-Output "Installing cloudflared as a system package..."
Invoke-NativeChecked { ssh -t @SshOptions $SshHost "sudo dpkg -i '${Package}'" } "Installing cloudflared"

Write-Output "Verifying cloudflared..."
Invoke-NativeChecked { ssh @SshOptions $SshHost "command -v cloudflared; cloudflared --version" } "Verifying cloudflared"

Write-Output "RESULT=PASS_CLOUDFLARED_INSTALL"
