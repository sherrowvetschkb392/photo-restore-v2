param(
    [string]$SshHost = "rk3588",
    [string]$RemoteRoot = "/userdata/photo-restore-v2",
    [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$ReportDirectory = Join-Path $ProjectRoot "benchmarks\production-health"
$ReportPath = Join-Path $ReportDirectory "latest.json"
$SshOptions = @(
    "-o", "ConnectTimeout=10",
    "-o", "ServerAliveInterval=15",
    "-o", "ServerAliveCountMax=3"
)

function Invoke-SshCapture {
    param([string]$RemoteCommand, [string]$Description)
    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $Lines = @(& ssh @SshOptions $SshHost $RemoteCommand 2>&1)
        $Code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $Previous
    }
    if ($Code -ne 0) {
        throw "$Description failed with exit code $Code`n$($Lines -join "`n")"
    }
    return ($Lines | ForEach-Object { "$_" }) -join "`n"
}

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    throw "Required command is unavailable: ssh"
}

if ($ValidateOnly) {
    Write-Output "SSH host: $SshHost"
    Write-Output "Remote root: $RemoteRoot"
    Write-Output "Report: $ReportPath"
    Write-Output "RESULT=PASS_PRODUCTION_HEALTH_PREFLIGHT"
    return
}

Write-Output "Checking production API health..."
$HealthText = Invoke-SshCapture `
    "curl --fail --silent --show-error http://127.0.0.1:8080/api/health" `
    "Reading the local API health endpoint"
$Health = $HealthText | ConvertFrom-Json

Write-Output "Checking systemd services..."
$ServiceText = Invoke-SshCapture `
    "printf 'api_enabled='; systemctl is-enabled photo-restore-api.service 2>/dev/null || true; printf 'api_active='; systemctl is-active photo-restore-api.service 2>/dev/null || true; printf 'tunnel_enabled='; systemctl is-enabled cloudflared.service 2>/dev/null || true; printf 'tunnel_active='; systemctl is-active cloudflared.service 2>/dev/null || true" `
    "Checking production services"
$Services = @{}
foreach ($Line in $ServiceText -split "`r?`n") {
    if ($Line -match '^(?<key>[a-z_]+)=(?<value>.*)$') {
        $Services[$Matches.key] = $Matches.value.Trim()
    }
}

Write-Output "Checking NPU, temperature, filesystem and worker processes..."
$BoardText = Invoke-SshCapture `
    "export LC_ALL=C LANG=C; printf '%s\n' '---NPU---'; sudo -n cat /sys/kernel/debug/rknpu/load 2>/dev/null || printf 'unavailable\n'; printf '%s\n' '---THERMAL---'; for zone in /sys/class/thermal/thermal_zone*; do test -r `"`$zone/temp`" || continue; name=`$(cat `"`$zone/type`" 2>/dev/null || basename `"`$zone`"); value=`$(cat `"`$zone/temp`"); printf '%s=%s\n' `"`$name`" `"`$value`"; done; printf '%s\n' '---FILESYSTEM---'; df -Pk '${RemoteRoot}' | tail -1; printf '%s\n' '---PROCESSES---'; pgrep -fc '^${RemoteRoot}/venv/bin/python ${RemoteRoot}/app/worker/restore_image.py ' || true; printf '%s\n' '---UPTIME---'; cut -d. -f1 /proc/uptime" `
    "Reading board production diagnostics"

$Sections = @{}
$CurrentSection = $null
foreach ($Line in $BoardText -split "`r?`n") {
    if ($Line -match '^---(?<name>[A-Z]+)---$') {
        $CurrentSection = $Matches.name
        $Sections[$CurrentSection] = @()
    } elseif ($null -ne $CurrentSection) {
        $Sections[$CurrentSection] += $Line
    }
}

$NpuText = (($Sections.NPU | Where-Object { $_ }) -join " ").Trim()
$CoreLoads = @()
foreach ($Match in [regex]::Matches($NpuText, 'Core\d+:\s*(\d+)%')) {
    $CoreLoads += [int]$Match.Groups[1].Value
}
$MaxNpuLoad = if ($CoreLoads.Count) { ($CoreLoads | Measure-Object -Maximum).Maximum } else { $null }

$Temperatures = [ordered]@{}
foreach ($Line in $Sections.THERMAL) {
    if ($Line -match '^(?<name>[^=]+)=(?<value>-?\d+)$') {
        $Temperatures[$Matches.name] = [Math]::Round(([double]$Matches.value / 1000), 1)
    }
}
$MaxTemperature = if ($Temperatures.Count) {
    ($Temperatures.Values | Measure-Object -Maximum).Maximum
} else { $null }

$FilesystemLine = (($Sections.FILESYSTEM | Where-Object { $_ }) -join " ").Trim()
$FilesystemParts = $FilesystemLine -split '\s+'
if ($FilesystemParts.Count -lt 6) {
    throw "Unexpected filesystem diagnostic output: $FilesystemLine"
}
$FilesystemAvailableBytes = [int64]$FilesystemParts[3] * 1024
$FilesystemUsedPercent = [int]($FilesystemParts[4] -replace '%', '')
$RestoreProcessValue = $Sections.PROCESSES | Select-Object -First 1
$UptimeValue = $Sections.UPTIME | Select-Object -First 1
$RestoreProcessCount = if ($null -eq $RestoreProcessValue) { 0 } else { [int]$RestoreProcessValue }
$UptimeSeconds = if ($null -eq $UptimeValue) { 0 } else { [int64]$UptimeValue }

$Alerts = [System.Collections.Generic.List[string]]::new()
foreach ($Alert in @($Health.alerts)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$Alert)) { $Alerts.Add([string]$Alert) }
}
if ($Services.api_enabled -ne "enabled") { $Alerts.Add("api_not_enabled") }
if ($Services.api_active -ne "active") { $Alerts.Add("api_not_active") }
if ($Services.tunnel_enabled -ne "enabled") { $Alerts.Add("tunnel_not_enabled") }
if ($Services.tunnel_active -ne "active") { $Alerts.Add("tunnel_not_active") }
if ($null -ne $MaxTemperature -and $MaxTemperature -ge 80) { $Alerts.Add("temperature_high") }
if ($FilesystemAvailableBytes -lt [int64]$Health.min_free_bytes) { $Alerts.Add("filesystem_reserve_low") }
if ($RestoreProcessCount -gt 1) { $Alerts.Add("multiple_restore_workers") }
if ($Health.jobs.stalled -and $null -ne $MaxNpuLoad -and $MaxNpuLoad -ge 95) {
    $Alerts.Add("npu_driver_stall_suspected")
}
$UniqueAlerts = @($Alerts | Select-Object -Unique)
$OverallStatus = if ($UniqueAlerts.Count -eq 0 -and $Health.status -eq "ok") { "PASS" } else { "ATTENTION" }

$Report = [ordered]@{
    checked_at_utc = [DateTime]::UtcNow.ToString("o")
    overall_status = $OverallStatus
    api = $Health
    services = [ordered]@{
        api_enabled = $Services.api_enabled
        api_active = $Services.api_active
        tunnel_enabled = $Services.tunnel_enabled
        tunnel_active = $Services.tunnel_active
    }
    board = [ordered]@{
        uptime_seconds = $UptimeSeconds
        npu_load_text = $NpuText
        max_npu_load_percent = $MaxNpuLoad
        temperatures_c = $Temperatures
        max_temperature_c = $MaxTemperature
        filesystem_available_bytes = $FilesystemAvailableBytes
        filesystem_used_percent = $FilesystemUsedPercent
        restore_process_count = $RestoreProcessCount
    }
    alerts = $UniqueAlerts
}

New-Item -ItemType Directory -Force -Path $ReportDirectory | Out-Null
$Report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ReportPath -Encoding utf8

Write-Output "API: $($Health.status) v$($Health.version); uploads=$($Health.accepting_uploads); queue=$($Health.queue_size)"
Write-Output "Jobs: queued=$($Health.jobs.counts.QUEUED) running=$($Health.jobs.counts.RUNNING) complete=$($Health.jobs.counts.COMPLETE) failed=$($Health.jobs.counts.FAILED)"
Write-Output "Services: api=$($Services.api_active); tunnel=$($Services.tunnel_active)"
Write-Output "Storage: API=$([Math]::Round([double]$Health.storage_used_bytes / 1GB, 3)) GiB; filesystem free=$([Math]::Round($FilesystemAvailableBytes / 1GB, 2)) GiB"
Write-Output "Board: NPU max=$MaxNpuLoad%; temperature max=$MaxTemperature C; restore processes=$RestoreProcessCount"
if ($UniqueAlerts.Count) { Write-Output "Alerts: $($UniqueAlerts -join ', ')" } else { Write-Output "Alerts: none" }
Write-Output "Report: $ReportPath"
Write-Output "RESULT=$($OverallStatus)_PRODUCTION_HEALTH"
if ($OverallStatus -ne "PASS") { exit 2 }
