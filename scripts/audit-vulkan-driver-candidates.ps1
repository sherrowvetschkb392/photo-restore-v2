param(
    [string]$SshHost = "rk3588"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$BoardScript = Join-Path $ProjectRoot "scripts\audit-vulkan-driver-candidates-board.sh"
$ReportDirectory = Join-Path $ProjectRoot "benchmarks\video-vulkan-driver-audit"
$RawReport = Join-Path $ReportDirectory "latest-raw.txt"
$JsonReport = Join-Path $ReportDirectory "latest.json"
$SshOptions = @("-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3")

if (-not (Test-Path -LiteralPath $BoardScript)) { throw "Board audit script is missing: $BoardScript" }
foreach ($Command in @("ssh", "scp")) {
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) { throw "Required command is unavailable: $Command" }
}
New-Item -ItemType Directory -Force -Path $ReportDirectory | Out-Null

$RemoteScript = "/tmp/photo-restore-vulkan-driver-audit.sh"
Write-Output "Auditing RK3588 Vulkan driver and package candidates (read-only)..."
& scp @SshOptions $BoardScript "${SshHost}:${RemoteScript}" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Uploading the temporary read-only driver audit failed with exit code $LASTEXITCODE" }
$Previous = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    $Lines = @(& ssh @SshOptions $SshHost "chmod 700 '$RemoteScript' && '$RemoteScript'; code=`$?; rm -f '$RemoteScript'; exit `$code" 2>&1)
    $Code = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $Previous
}
$Text = ($Lines | ForEach-Object { "$_" }) -join "`n"
$Text | Set-Content -LiteralPath $RawReport -Encoding utf8
if ($Code -ne 0) { throw "Collecting the Vulkan driver audit failed with exit code $Code`n$Text" }

$Sections = @{}; $Current = $null
foreach ($Line in $Text -split "`r?`n") {
    if ($Line -match '^---SECTION:(?<name>[A-Z_]+)---$') {
        $Current = $Matches.name; $Sections[$Current] = @()
    } elseif ($null -ne $Current -and $Line -ne '---END---') {
        $Sections[$Current] += $Line
    }
}
$CandidatePackages = @($Sections.APT_PACKAGE_NAMES | Where-Object { $_ -match '^[a-z0-9][a-z0-9+.-]+$' } | Select-Object -Unique)
$VendorCandidatePackages = @($CandidatePackages | Where-Object { $_ -match '(?i)libmali|mali.*g610|g610.*mali' })
$MesaCandidatePackages = @($CandidatePackages | Where-Object { $_ -match '(?i)mesa-vulkan|panvk|panfrost' })
$MaliFiles = @($Sections.INSTALLED_MALI_FILES | Where-Object { $_ -match '^/' })
$HasVulkanIcdFile = @($MaliFiles | Where-Object { $_ -match '(?i)vulkan.*icd.*\.json$|icd\.d/.+\.json$' }).Count -gt 0
$HasVulkanLibraryFile = @($MaliFiles | Where-Object { $_ -match '(?i)libvulkan|vulkan' }).Count -gt 0
$BuildSimulation = @($Sections.BUILD_TOOL_SIMULATION)
$BuildRemovals = @($BuildSimulation | Where-Object { $_ -match '^Remv\s' })
$MesaSimulation = @($Sections.MESA_VULKAN_SIMULATION)
$MesaRemovals = @($MesaSimulation | Where-Object { $_ -match '^Remv\s' })
$ProductionHealthy = @($Sections.PRODUCTION | Where-Object { $_ -eq 'api_active=active' }).Count -gt 0 -and @($Sections.PRODUCTION | Where-Object { $_ -eq 'tunnel_active=active' }).Count -gt 0

$Assessment = if (-not $ProductionHealthy) {
    "BLOCKED_PRODUCTION_UNHEALTHY"
} elseif ($VendorCandidatePackages.Count -gt 0) {
    "READY_FOR_VENDOR_CANDIDATE_REVIEW"
} elseif ($MesaCandidatePackages.Count -gt 0) {
    "ONLY_GENERIC_MESA_CANDIDATE_AVAILABLE"
} else {
    "NO_VENDOR_VULKAN_PACKAGE_IN_CURRENT_APT_METADATA"
}
$Report = [ordered]@{
    schema_version = 1
    audited_at_utc = [DateTime]::UtcNow.ToString("o")
    assessment = $Assessment
    board_changed = $false
    installed_mali_package = @($Sections.INSTALLED_MALI_PACKAGE)
    installed_mali_file_count = $MaliFiles.Count
    installed_package_contains_vulkan_icd = $HasVulkanIcdFile
    installed_package_contains_vulkan_library = $HasVulkanLibraryFile
    apt_candidate_packages = $CandidatePackages
    vendor_candidate_packages = $VendorCandidatePackages
    mesa_candidate_packages = $MesaCandidatePackages
    build_tool_simulation = [ordered]@{ removals = $BuildRemovals; safe_no_removals = $BuildRemovals.Count -eq 0 }
    mesa_vulkan_simulation = [ordered]@{ removals = $MesaRemovals; safe_no_removals = $MesaRemovals.Count -eq 0 }
    production_healthy = $ProductionHealthy
}
$Report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $JsonReport -Encoding utf8

Write-Output "Installed Mali files: $($MaliFiles.Count); Vulkan library in package=$HasVulkanLibraryFile; ICD in package=$HasVulkanIcdFile"
Write-Output "APT Vulkan/Mali candidates: $($CandidatePackages.Count)"
if ($CandidatePackages.Count) { Write-Output "Candidates: $($CandidatePackages -join ', ')" }
Write-Output "Vendor G610/Mali candidates: $($VendorCandidatePackages.Count)"
if ($VendorCandidatePackages.Count) { Write-Output "Vendor candidates: $($VendorCandidatePackages -join ', ')" }
Write-Output "Build-tool simulation removals: $($BuildRemovals.Count)"
Write-Output "Mesa Vulkan simulation removals: $($MesaRemovals.Count)"
Write-Output "Production healthy: $ProductionHealthy"
Write-Output "Assessment: $Assessment"
Write-Output "Raw report: $RawReport"
Write-Output "JSON report: $JsonReport"
Write-Output "Board changed: False"
Write-Output "RESULT=PASS_VULKAN_DRIVER_CANDIDATE_AUDIT"
