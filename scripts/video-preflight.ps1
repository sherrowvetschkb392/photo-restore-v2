param(
    [string]$SshHost = "rk3588",
    [string]$RemoteRoot = "/userdata/photo-restore-v2",
    [string]$InputFile,
    [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$CollectorPath = Join-Path $PSScriptRoot "video-preflight-board.sh"
$FixturePath = Join-Path $ProjectRoot "tests\fixtures\video-preflight-sample.txt"
$ReportDirectory = Join-Path $ProjectRoot "benchmarks\video-preflight"
$RawReportPath = Join-Path $ReportDirectory "latest-raw.txt"
$JsonReportPath = Join-Path $ReportDirectory "latest.json"
$SshOptions = @(
    "-o", "ConnectTimeout=10",
    "-o", "ServerAliveInterval=15",
    "-o", "ServerAliveCountMax=3"
)

function Assert-SafeRemoteRoot {
    param([string]$Path)
    if ($Path -ne "/userdata/photo-restore-v2") {
        throw "RemoteRoot must remain the isolated project root: /userdata/photo-restore-v2"
    }
}

function Invoke-BoardCollector {
    if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
        throw "Required command is unavailable: ssh"
    }
    if (-not (Test-Path -LiteralPath $CollectorPath -PathType Leaf)) {
        throw "Board collector is missing: $CollectorPath"
    }

    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        # PowerShell writes native pipeline text with CRLF even when the tracked
        # shell file itself is LF-only. Strip only carriage returns on the board
        # before Bash parses stdin; no remote file is created.
        $Lines = @(Get-Content -LiteralPath $CollectorPath | & ssh @SshOptions $SshHost "/usr/bin/tr -d '\015' | /bin/bash -s -- '$RemoteRoot'" 2>&1)
        $Code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $Previous
    }
    if ($Code -ne 0) {
        throw "Collecting the read-only board video inventory failed with exit code $Code`n$($Lines -join "`n")"
    }
    return (($Lines | ForEach-Object { "$_" }) -join "`n").Trim()
}

function ConvertFrom-SectionText {
    param([string]$Text)
    $Sections = [ordered]@{}
    $Current = $null
    $SawEnd = $false
    foreach ($Line in $Text -split "`r?`n") {
        if ($Line -match '^---SECTION:(?<name>[A-Z0-9_]+)---$') {
            $Current = $Matches.name
            if ($Sections.Contains($Current)) {
                throw "Duplicate collector section: $Current"
            }
            $Sections[$Current] = [System.Collections.Generic.List[string]]::new()
        } elseif ($Line -eq '---END---') {
            $SawEnd = $true
            $Current = $null
        } elseif ($null -ne $Current) {
            $Sections[$Current].Add($Line)
        }
    }
    if (-not $SawEnd) { throw "Collector output is incomplete: missing end marker" }
    foreach ($Required in @("PLATFORM", "TOOLS", "FFMPEG_DECODERS", "FFMPEG_ENCODERS", "DEVICES", "RESOURCES", "SERVICES", "PROCESSES")) {
        if (-not $Sections.Contains($Required)) { throw "Collector output is missing section: $Required" }
    }
    return $Sections
}

function ConvertFrom-KeyValueLines {
    param([object[]]$Lines)
    $Values = [ordered]@{}
    foreach ($Line in $Lines) {
        if ([string]$Line -match '^(?<key>[A-Za-z0-9_.-]+)=(?<value>.*)$') {
            $Values[$Matches.key] = $Matches.value.Trim()
        }
    }
    return $Values
}

function ConvertTo-NullableInt64 {
    param([object]$Value)
    $Parsed = [int64]0
    if ($null -ne $Value -and [int64]::TryParse([string]$Value, [ref]$Parsed)) { return $Parsed }
    return $null
}

function ConvertTo-NullableInt {
    param([object]$Value)
    $Parsed = [int]0
    if ($null -ne $Value -and [int]::TryParse([string]$Value, [ref]$Parsed)) { return $Parsed }
    return $null
}

function Get-CodecNames {
    param([object[]]$Lines)
    $Names = [System.Collections.Generic.List[string]]::new()
    foreach ($Line in $Lines) {
        if ([string]$Line -match '^\s*(?:[A-Z\.]{3}|[A-Z\.]{6})\s+(?<name>\S+)') {
            $Names.Add($Matches.name)
        }
    }
    return @($Names | Select-Object -Unique)
}

function Test-AnyMatch {
    param([object[]]$Values, [string]$Pattern)
    return [bool](@($Values | Where-Object { [string]$_ -match $Pattern }).Count)
}

function ConvertTo-DeviceRecords {
    param([object[]]$Lines)
    $Records = [System.Collections.Generic.List[object]]::new()
    foreach ($Line in $Lines) {
        if ([string]$Line -match '^(?<path>/[^|]+)\|(?<state>present|missing)\|readable=(?<readable>true|false)\|writable=(?<writable>true|false)$') {
            $Records.Add([ordered]@{
                path = $Matches.path
                present = $Matches.state -eq "present"
                readable = $Matches.readable -eq "true"
                writable = $Matches.writable -eq "true"
            })
        }
    }
    return @($Records)
}

function ConvertTo-ThermalRecords {
    param([object[]]$Lines)
    $Records = [ordered]@{}
    foreach ($Line in $Lines) {
        if ([string]$Line -match '^(?<name>[^=]+)=(?<value>-?\d+)$') {
            $Records[$Matches.name] = [Math]::Round(([double]$Matches.value / 1000), 1)
        }
    }
    return $Records
}

function New-Finding {
    param([string]$Code, [string]$Severity, [string]$Message)
    return [ordered]@{ code = $Code; severity = $Severity; message = $Message }
}

function ConvertTo-VideoPreflightReport {
    param([string]$RawText, [string]$Source)

    $Sections = ConvertFrom-SectionText $RawText
    $Platform = ConvertFrom-KeyValueLines $Sections.PLATFORM
    $Tools = ConvertFrom-KeyValueLines $Sections.TOOLS
    $Resources = ConvertFrom-KeyValueLines $Sections.RESOURCES
    $Services = ConvertFrom-KeyValueLines $Sections.SERVICES
    $Processes = ConvertFrom-KeyValueLines $Sections.PROCESSES
    $Python = ConvertFrom-KeyValueLines $Sections.PYTHON
    $Gstreamer = ConvertFrom-KeyValueLines $Sections.GSTREAMER_PLUGINS
    $Devices = ConvertTo-DeviceRecords $Sections.DEVICES
    $Temperatures = ConvertTo-ThermalRecords $Sections.THERMAL
    $Decoders = @(Get-CodecNames $Sections.FFMPEG_DECODERS)
    $Encoders = @(Get-CodecNames $Sections.FFMPEG_ENCODERS)
    $FilterNames = @(Get-CodecNames $Sections.FFMPEG_FILTERS)
    $Hwaccels = @($Sections.FFMPEG_HWACCELS | Where-Object {
        $_ -and $_ -notmatch '^Hardware acceleration methods:' -and $_ -ne 'unavailable'
    } | ForEach-Object { $_.Trim() } | Select-Object -Unique)

    $FfmpegAvailable = $Tools.ffmpeg_path -and $Tools.ffmpeg_path -ne "missing"
    $FfprobeAvailable = $Tools.ffprobe_path -and $Tools.ffprobe_path -ne "missing"
    $MppDevice = @($Devices | Where-Object { $_.path -eq "/dev/mpp_service" -and $_.present }).Count -gt 0
    $RgaDevice = @($Devices | Where-Object { $_.path -eq "/dev/rga" -and $_.present }).Count -gt 0
    $RenderDevice = @($Devices | Where-Object { $_.path -like "/dev/dri/renderD*" -and $_.present }).Count -gt 0
    $VideoDevice = @($Devices | Where-Object { $_.path -like "/dev/video*" -and $_.present }).Count -gt 0
    $FfmpegHardwareDecode = Test-AnyMatch $Decoders '(?i)(rkmpp|v4l2m2m|drm|rockchip)'
    $FfmpegHardwareEncode = Test-AnyMatch $Encoders '(?i)(rkmpp|v4l2m2m|drm|rockchip)'
    $GstreamerHardwareDecode = @($Gstreamer.Keys | Where-Object { $_ -match '(?i)(mpp|rkv4l2).*dec' -and $Gstreamer[$_] -eq "available" }).Count -gt 0
    $GstreamerHardwareEncode = @($Gstreamer.Keys | Where-Object { $_ -match '(?i)(mpp|rkv4l2).*enc' -and $Gstreamer[$_] -eq "available" }).Count -gt 0
    $HardwareDecodeEvidence = $FfmpegHardwareDecode -or $GstreamerHardwareDecode -or ($MppDevice -and $VideoDevice)
    $HardwareEncodeEvidence = $FfmpegHardwareEncode -or $GstreamerHardwareEncode -or ($MppDevice -and $VideoDevice)
    $MemoryAvailableBytes = ConvertTo-NullableInt64 $Resources.memory_available_bytes
    $FilesystemAvailableBytes = ConvertTo-NullableInt64 $Resources.filesystem_available_bytes
    $RestoreWorkerCount = ConvertTo-NullableInt $Processes.restore_worker_count
    $FfmpegProcessCount = ConvertTo-NullableInt $Processes.ffmpeg_process_count
    $VideoWorkerCount = ConvertTo-NullableInt $Processes.video_worker_count
    $MaxTemperature = if ($Temperatures.Count) { ($Temperatures.Values | Measure-Object -Maximum).Maximum } else { $null }

    $Findings = [System.Collections.Generic.List[object]]::new()
    if ($Platform.architecture -ne "aarch64") {
        $Findings.Add((New-Finding "unsupported_architecture" "blocker" "Expected aarch64, found '$($Platform.architecture)'."))
    }
    if (-not $FfmpegAvailable) {
        $Findings.Add((New-Finding "ffmpeg_missing" "blocker" "FFmpeg is unavailable; video decode/encode cannot be prototyped."))
    }
    if (-not $FfprobeAvailable) {
        $Findings.Add((New-Finding "ffprobe_missing" "blocker" "ffprobe is unavailable; media validation and output verification are incomplete."))
    }
    if (-not $HardwareDecodeEvidence) {
        $Findings.Add((New-Finding "hardware_decode_unconfirmed" "warning" "No Rockchip hardware decode path was confirmed by FFmpeg, GStreamer or device evidence."))
    }
    if (-not $HardwareEncodeEvidence) {
        $Findings.Add((New-Finding "hardware_encode_unconfirmed" "warning" "No Rockchip hardware encode path was confirmed by FFmpeg, GStreamer or device evidence."))
    }
    if (-not $MppDevice) {
        $Findings.Add((New-Finding "mpp_device_missing" "warning" "The Rockchip MPP service device was not found."))
    }
    if (-not $RgaDevice) {
        $Findings.Add((New-Finding "rga_device_missing" "warning" "The RGA device was not found; resize/color conversion may require another path."))
    }
    if ($null -ne $MemoryAvailableBytes -and $MemoryAvailableBytes -lt 1GB) {
        $Findings.Add((New-Finding "memory_available_low" "warning" "Less than 1 GiB memory is currently available."))
    }
    if ($null -ne $FilesystemAvailableBytes -and $FilesystemAvailableBytes -lt 2GB) {
        $Findings.Add((New-Finding "filesystem_available_low" "blocker" "Less than 2 GiB is available under the isolated project filesystem."))
    }
    if (($RestoreWorkerCount -gt 0) -or ($FfmpegProcessCount -gt 0) -or ($VideoWorkerCount -gt 0)) {
        $Findings.Add((New-Finding "media_processing_active" "warning" "A media worker is active; do not start performance tests until it finishes."))
    }
    if ($Services.photo_restore_api_service_active -ne "active") {
        $Findings.Add((New-Finding "photo_api_not_active" "warning" "The existing photo API is not active."))
    }
    if ($Services.cloudflared_service_active -ne "active") {
        $Findings.Add((New-Finding "cloudflared_not_active" "warning" "Cloudflare Tunnel is not active."))
    }
    if ($null -ne $MaxTemperature -and $MaxTemperature -ge 80) {
        $Findings.Add((New-Finding "temperature_high" "blocker" "Board temperature is at or above 80 C."))
    }
    if ($Python.opencv_available -ne "true") {
        $Findings.Add((New-Finding "opencv_not_installed" "info" "OpenCV is not installed in the project venv; the first prototype should prefer FFmpeg/Pillow or add it only after review."))
    }

    $BlockerCount = @($Findings | Where-Object severity -eq "blocker").Count
    $WarningCount = @($Findings | Where-Object severity -eq "warning").Count
    $Assessment = if ($BlockerCount -gt 0) {
        "BLOCKED"
    } elseif ($HardwareDecodeEvidence -and $HardwareEncodeEvidence) {
        "READY_FOR_CODEC_SMOKE_TEST"
    } else {
        "CONDITIONAL"
    }

    $Recommendations = [System.Collections.Generic.List[string]]::new()
    if ($Assessment -eq "BLOCKED") {
        $Recommendations.Add("Resolve only the reported blockers before downloading or converting an interpolation model.")
    } else {
        $Recommendations.Add("Run an isolated generated-video decode/encode smoke test before selecting an interpolation model.")
    }
    if (-not ($HardwareDecodeEvidence -and $HardwareEncodeEvidence)) {
        $Recommendations.Add("Confirm the vendor MPP/GStreamer path with an actual short clip; do not assume FFmpeg software codecs are hardware accelerated.")
    }
    $Recommendations.Add("Keep the existing photo API and Cloudflare services unchanged during video research.")
    $Recommendations.Add("Start model experiments with a fixed small frame pair, then 640x360/10-second video, before attempting 720p.")

    return [ordered]@{
        schema_version = 1
        checked_at_utc = [DateTime]::UtcNow.ToString("o")
        source = $Source
        assessment = $Assessment
        finding_counts = [ordered]@{ blockers = $BlockerCount; warnings = $WarningCount; total = $Findings.Count }
        platform = $Platform
        tools = $Tools
        ffmpeg = [ordered]@{
            available = [bool]$FfmpegAvailable
            ffprobe_available = [bool]$FfprobeAvailable
            version = $Tools.ffmpeg_version
            configuration = @($Sections.FFMPEG_CONFIGURATION)
            hardware_accelerators = $Hwaccels
            selected_decoders = $Decoders
            selected_encoders = $Encoders
            selected_filters = $FilterNames
        }
        rockchip = [ordered]@{
            mpp_device_present = $MppDevice
            rga_device_present = $RgaDevice
            render_device_present = $RenderDevice
            video_device_present = $VideoDevice
            ffmpeg_hardware_decode_evidence = $FfmpegHardwareDecode
            ffmpeg_hardware_encode_evidence = $FfmpegHardwareEncode
            gstreamer_hardware_decode_evidence = $GstreamerHardwareDecode
            gstreamer_hardware_encode_evidence = $GstreamerHardwareEncode
            hardware_decode_evidence = $HardwareDecodeEvidence
            hardware_encode_evidence = $HardwareEncodeEvidence
            devices = $Devices
            gstreamer_plugins = $Gstreamer
        }
        python = $Python
        resources = [ordered]@{
            memory_total_bytes = ConvertTo-NullableInt64 $Resources.memory_total_bytes
            memory_available_bytes = $MemoryAvailableBytes
            swap_total_bytes = ConvertTo-NullableInt64 $Resources.swap_total_bytes
            filesystem_total_bytes = ConvertTo-NullableInt64 $Resources.filesystem_total_bytes
            filesystem_used_bytes = ConvertTo-NullableInt64 $Resources.filesystem_used_bytes
            filesystem_available_bytes = $FilesystemAvailableBytes
            filesystem_used_percent = $Resources.filesystem_used_percent
            uptime_seconds = ConvertTo-NullableInt64 $Resources.uptime_seconds
            npu_load = $Resources.npu_load
            temperatures_c = $Temperatures
            max_temperature_c = $MaxTemperature
        }
        production = [ordered]@{
            services = $Services
            restore_worker_count = $RestoreWorkerCount
            ffmpeg_process_count = $FfmpegProcessCount
            video_worker_count = $VideoWorkerCount
        }
        raw_evidence = [ordered]@{
            v4l2_devices = @($Sections.V4L2_DEVICES)
            packages = @($Sections.PACKAGES)
            kernel_modules = @($Sections.KERNEL_MODULES)
        }
        findings = @($Findings)
        recommendations = @($Recommendations)
    }
}

Assert-SafeRemoteRoot $RemoteRoot

if ($ValidateOnly) {
    if ($InputFile) { throw "-ValidateOnly and -InputFile cannot be combined" }
    $InputFile = $FixturePath
}

if ($InputFile) {
    $ResolvedInput = (Resolve-Path -LiteralPath $InputFile).Path
    $RawText = Get-Content -LiteralPath $ResolvedInput -Raw
    $Source = "file:$ResolvedInput"
} else {
    Write-Output "Collecting a read-only RK3588 video capability inventory..."
    Write-Output "No packages, services, models or user data will be changed."
    $RawText = Invoke-BoardCollector
    $Source = "ssh:$SshHost"
}

$Report = ConvertTo-VideoPreflightReport $RawText $Source

if ($ValidateOnly) {
    if ($Report.assessment -ne "READY_FOR_CODEC_SMOKE_TEST") { throw "Fixture assessment mismatch: $($Report.assessment)" }
    if (-not $Report.rockchip.hardware_decode_evidence) { throw "Fixture did not detect hardware decode evidence" }
    if (-not $Report.rockchip.hardware_encode_evidence) { throw "Fixture did not detect hardware encode evidence" }
    if ($Report.platform.architecture -ne "aarch64") { throw "Fixture architecture mismatch" }
    Write-Output "Fixture: $FixturePath"
    Write-Output "RESULT=PASS_VIDEO_PREFLIGHT_VALIDATION"
    return
}

if ($InputFile) {
    Write-Output "Parsed report: $ResolvedInput"
    Write-Output "Assessment: $($Report.assessment); blockers=$($Report.finding_counts.blockers); warnings=$($Report.finding_counts.warnings)"
    foreach ($Finding in $Report.findings) {
        Write-Output "[$($Finding.severity.ToUpperInvariant())] $($Finding.code): $($Finding.message)"
    }
    Write-Output "RESULT=PASS_VIDEO_PREFLIGHT_PARSE"
    return
}

New-Item -ItemType Directory -Force -Path $ReportDirectory | Out-Null
$RawText | Set-Content -LiteralPath $RawReportPath -Encoding utf8
$Report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $JsonReportPath -Encoding utf8

$MemoryAvailableGiB = if ($null -ne $Report.resources.memory_available_bytes) { [Math]::Round($Report.resources.memory_available_bytes / 1GB, 2) } else { "unknown" }
$FilesystemAvailableGiB = if ($null -ne $Report.resources.filesystem_available_bytes) { [Math]::Round($Report.resources.filesystem_available_bytes / 1GB, 2) } else { "unknown" }
Write-Output "Platform: $($Report.platform.architecture); $($Report.platform.os_pretty)"
Write-Output "FFmpeg: $($Report.ffmpeg.available); ffprobe=$($Report.ffmpeg.ffprobe_available)"
Write-Output "Rockchip evidence: decode=$($Report.rockchip.hardware_decode_evidence); encode=$($Report.rockchip.hardware_encode_evidence); MPP=$($Report.rockchip.mpp_device_present); RGA=$($Report.rockchip.rga_device_present)"
Write-Output "Resources: memory available=$MemoryAvailableGiB GiB; filesystem available=$FilesystemAvailableGiB GiB; max temperature=$($Report.resources.max_temperature_c) C"
Write-Output "Production: API=$($Report.production.services.photo_restore_api_service_active); tunnel=$($Report.production.services.cloudflared_service_active); active media workers=$($Report.production.restore_worker_count + $Report.production.ffmpeg_process_count + $Report.production.video_worker_count)"
Write-Output "Assessment: $($Report.assessment); blockers=$($Report.finding_counts.blockers); warnings=$($Report.finding_counts.warnings)"
foreach ($Finding in $Report.findings) {
    Write-Output "[$($Finding.severity.ToUpperInvariant())] $($Finding.code): $($Finding.message)"
}
Write-Output "Raw report: $RawReportPath"
Write-Output "JSON report: $JsonReportPath"
Write-Output "RESULT=PASS_VIDEO_PREFLIGHT"
