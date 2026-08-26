param(
    [string]$SshHost = "rk3588"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$BoardScript = Join-Path $ProjectRoot "scripts\video-vulkan-preflight-board.sh"
$ReportDirectory = Join-Path $ProjectRoot "benchmarks\video-vulkan-preflight"
$RawReport = Join-Path $ReportDirectory "latest-raw.txt"
$JsonReport = Join-Path $ReportDirectory "latest.json"
$SshOptions = @("-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3")

if (-not (Test-Path -LiteralPath $BoardScript)) { throw "Board inventory script is missing: $BoardScript" }
foreach ($Command in @("ssh", "scp")) {
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) { throw "Required command is unavailable: $Command" }
}
New-Item -ItemType Directory -Force -Path $ReportDirectory | Out-Null

$RemoteScript = "/tmp/photo-restore-video-vulkan-preflight.sh"
Write-Output "Collecting a read-only RK3588 Vulkan/NCNN capability inventory..."
& scp @SshOptions $BoardScript "${SshHost}:${RemoteScript}" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Uploading the temporary read-only Vulkan inventory failed with exit code $LASTEXITCODE" }
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
if ($Code -ne 0) { throw "Collecting the read-only Vulkan inventory failed with exit code $Code`n$Text" }

$Sections = @{}; $Current = $null
foreach ($Line in $Text -split "`r?`n") {
    if ($Line -match '^---SECTION:(?<name>[A-Z_]+)---$') {
        $Current = $Matches.name; $Sections[$Current] = @()
    } elseif ($null -ne $Current -and $Line -ne '---END---') {
        $Sections[$Current] += $Line
    }
}
$ToolValues = @{}
foreach ($Line in @($Sections.TOOLS)) {
    if ($Line -match '^(?<key>[a-z_]+)_path=(?<value>.*)$') { $ToolValues[$Matches.key] = $Matches.value }
}
$DeviceLines = @($Sections.DEVICES)
$MaliReady = @($DeviceLines | Where-Object { $_ -match '^/dev/mali0\|present\|readable=true\|writable=true$' }).Count -gt 0
$RenderReady = @($DeviceLines | Where-Object { $_ -match '^/dev/dri/renderD12[89]\|present\|readable=true\|writable=true$' }).Count -gt 0
$HasVulkanLibrary = @($Sections.VULKAN_LIBRARIES | Where-Object { $_ -match 'libvulkan' }).Count -gt 0
$HasIcd = @($Sections.VULKAN_ICD | Where-Object { $_ -match '^icd=/' }).Count -gt 0
$VulkanInfoAvailable = $ToolValues.vulkaninfo -and $ToolValues.vulkaninfo -ne "missing"
$VulkanInfoPassed = $VulkanInfoAvailable -and @($Sections.VULKANINFO | Where-Object { $_ -match 'deviceName|GPU|Vulkan Instance Version' }).Count -gt 0 -and @($Sections.VULKANINFO | Where-Object { $_ -eq 'vulkaninfo_status=failed' }).Count -eq 0
$BuildTools = @("cmake", "git", "g__")
$MissingBuildTools = @($BuildTools | Where-Object { -not $ToolValues[$_] -or $ToolValues[$_] -eq "missing" })
$ExistingNcnn = @($Sections.EXISTING_NCNN | Where-Object { $_ -match '^/' })

$Blockers = [System.Collections.Generic.List[string]]::new()
if (-not $MaliReady -and -not $RenderReady) { $Blockers.Add("no_writable_gpu_device") }
if (-not $HasVulkanLibrary) { $Blockers.Add("vulkan_loader_missing") }
if (-not $HasIcd) { $Blockers.Add("vulkan_icd_missing") }
if ($VulkanInfoAvailable -and -not $VulkanInfoPassed) { $Blockers.Add("vulkan_runtime_probe_failed") }
$Assessment = if ($Blockers.Count) { "BLOCKED" } elseif ($VulkanInfoPassed) { "READY_FOR_NCNN_BUILD_SMOKE" } else { "READY_FOR_VULKANINFO_INSTALL_PLAN" }

$Report = [ordered]@{
    schema_version = 1
    checked_at_utc = [DateTime]::UtcNow.ToString("o")
    assessment = $Assessment
    board_changed = $false
    gpu = [ordered]@{ mali_device_ready = $MaliReady; render_device_ready = $RenderReady }
    vulkan = [ordered]@{ loader_available = $HasVulkanLibrary; icd_available = $HasIcd; vulkaninfo_available = [bool]$VulkanInfoAvailable; runtime_probe_passed = [bool]$VulkanInfoPassed }
    build = [ordered]@{ missing_tools = $MissingBuildTools }
    existing_ncnn_binaries = $ExistingNcnn
    candidate_route = [ordered]@{
        interpolation_primary = "rife-ncnn-vulkan pretrained model"
        spatial_primary = "existing Real-ESRGAN RKNN image worker"
        spatial_backup = "realesrgan-ncnn-vulkan / realesr-animevideov3"
        training_required = $false
    }
    blockers = @($Blockers)
}
$Report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $JsonReport -Encoding utf8
Write-Output "GPU: mali=$MaliReady; render=$RenderReady"
Write-Output "Vulkan: loader=$HasVulkanLibrary; ICD=$HasIcd; vulkaninfo=$VulkanInfoAvailable; runtime=$VulkanInfoPassed"
Write-Output "Existing NCNN binaries: $($ExistingNcnn.Count)"
Write-Output "Missing build tools: $(if ($MissingBuildTools.Count) { $MissingBuildTools -join ', ' } else { 'none' })"
Write-Output "Assessment: $Assessment"
if ($Blockers.Count) { Write-Output "Blockers: $($Blockers -join ', ')" }
Write-Output "Raw report: $RawReport"
Write-Output "JSON report: $JsonReport"
Write-Output "Board changed: False"
Write-Output "RESULT=PASS_VIDEO_VULKAN_PREFLIGHT"
