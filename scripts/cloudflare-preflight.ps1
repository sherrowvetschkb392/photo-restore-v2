param(
    [string]$SshHost = "rk3588"
)

$ErrorActionPreference = "Stop"
$SshOptions = @("-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3")

function Invoke-CaptureChecked {
    param([scriptblock]$Command, [string]$Description)
    $Previous = $ErrorActionPreference
    try { $ErrorActionPreference = "Continue"; $Lines = @(& $Command); $Code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $Previous }
    if ($Code -ne 0) { throw "$Description failed with exit code $Code" }
    return (($Lines | ForEach-Object { "$_" }) -join "`n").Trim()
}

Write-Output "Checking RK3588 architecture and operating system..."
$Platform = Invoke-CaptureChecked { ssh @SshOptions $SshHost "printf 'architecture='; uname -m; . /etc/os-release; printf 'os='; printf '%s %s\n' `"`$ID`" `"`$VERSION_ID`"" } "Reading the board platform"
Write-Output $Platform

Write-Output "Checking the local photo restoration API..."
$Health = Invoke-CaptureChecked { ssh @SshOptions $SshHost "curl --fail --silent --show-error http://127.0.0.1:8080/api/health" } "Checking the local API"
Write-Output $Health

Write-Output "Checking whether cloudflared is already installed..."
$Cloudflared = Invoke-CaptureChecked { ssh @SshOptions $SshHost "if command -v cloudflared >/dev/null 2>&1; then printf 'installed=true\n'; cloudflared --version; else printf 'installed=false\n'; fi" } "Checking cloudflared"
Write-Output $Cloudflared

Write-Output "Checking outbound HTTPS and available storage..."
$Network = Invoke-CaptureChecked { ssh @SshOptions $SshHost "curl --head --silent --show-error --max-time 15 https://api.cloudflare.com/client/v4/ >/dev/null && printf 'cloudflare_https=ok\n'; df -h /userdata | tail -1" } "Checking Cloudflare connectivity and storage"
Write-Output $Network

Write-Output "RESULT=PASS_CLOUDFLARE_PREFLIGHT"
