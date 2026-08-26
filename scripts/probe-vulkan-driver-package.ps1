param(
    [Parameter(Mandatory = $true)]
    [string]$PackagePath,
    [string]$SshHost = "rk3588"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$BoardScript = Join-Path $ProjectRoot "scripts\probe-vulkan-driver-package-board.sh"
$ResolvedPackage = (Resolve-Path -LiteralPath $PackagePath).Path
$ReportDirectory = Join-Path $ProjectRoot "benchmarks\video-vulkan-driver-package-probe"
$RawReport = Join-Path $ReportDirectory "latest-raw.txt"
$JsonReport = Join-Path $ReportDirectory "latest.json"
$SshOptions = @("-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3")

if ([IO.Path]::GetExtension($ResolvedPackage) -ne ".deb") { throw "Only a vendor ARM64 .deb package can be probed: $ResolvedPackage" }
if (-not (Test-Path -LiteralPath $BoardScript)) { throw "Board probe script is missing: $BoardScript" }
foreach ($Command in @("ssh", "scp")) {
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) { throw "Required command is unavailable: $Command" }
}
New-Item -ItemType Directory -Force -Path $ReportDirectory | Out-Null

$Hash = (Get-FileHash -LiteralPath $ResolvedPackage -Algorithm SHA256).Hash.ToLowerInvariant()
$RemoteScript = "/tmp/photo-restore-vulkan-driver-package-probe.sh"
$RemotePackage = "/tmp/photo-restore-vulkan-driver-candidate.deb"
Write-Output "Uploading one Vulkan driver candidate for an isolated private probe..."
Write-Output "Package: $ResolvedPackage"
Write-Output "SHA256: $Hash"
Write-Output "No package will be installed and no system driver file will be replaced."

& scp @SshOptions $BoardScript "${SshHost}:${RemoteScript}" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Uploading the temporary probe script failed with exit code $LASTEXITCODE" }
& scp @SshOptions $ResolvedPackage "${SshHost}:${RemotePackage}" | Out-Null
if ($LASTEXITCODE -ne 0) {
    & ssh @SshOptions $SshHost "rm -f '$RemoteScript' '$RemotePackage'" | Out-Null
    throw "Uploading the temporary driver candidate failed with exit code $LASTEXITCODE"
}

$Previous = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    $Lines = @(& ssh @SshOptions $SshHost "chmod 700 '$RemoteScript' && '$RemoteScript' '$RemotePackage'; code=`$?; rm -f '$RemoteScript' '$RemotePackage'; exit `$code" 2>&1)
    $Code = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $Previous
}
$Text = ($Lines | ForEach-Object { "$_" }) -join "`n"
$Text | Set-Content -LiteralPath $RawReport -Encoding utf8

$PrivateProbe = if ($Text -match '(?m)^private_probe=(?<status>[^\r\n]+)$') { $Matches.status } else { "unknown" }
$Architecture = if ($Text -match '(?m)^architecture=(?<value>[^\r\n]+)$') { $Matches.value } else { "unknown" }
$PackageName = if ($Text -match '(?m)^package=(?<value>[^\r\n]+)$') { $Matches.value } else { "unknown" }
$Version = if ($Text -match '(?m)^version=(?<value>[^\r\n]+)$') { $Matches.value } else { "unknown" }
$EntryPoint = if ($Text -match '(?m)^vulkan_entrypoint=(?<value>[^\r\n]+)$') { $Matches.value } else { "unknown" }
$Report = [ordered]@{
    schema_version = 1
    probed_at_utc = [DateTime]::UtcNow.ToString("o")
    board_changed = $false
    installed = $false
    local_package = $ResolvedPackage
    sha256 = $Hash
    package = $PackageName
    version = $Version
    architecture = $Architecture
    vulkan_entrypoint = $EntryPoint
    private_runtime_probe = $PrivateProbe
    exit_code = $Code
}
$Report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $JsonReport -Encoding utf8

Write-Output $Text
Write-Output "Private Vulkan probe: $PrivateProbe"
Write-Output "Raw report: $RawReport"
Write-Output "JSON report: $JsonReport"
Write-Output "Board changed: False"
if ($Code -ne 0) { throw "The candidate package did not pass the private Vulkan runtime gate (exit code $Code). It was not installed." }
Write-Output "RESULT=PASS_VULKAN_DRIVER_PACKAGE_PROBE_DEPLOY"
