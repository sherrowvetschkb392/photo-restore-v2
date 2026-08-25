param(
    [string]$InputImage,
    [ValidateRange(30, 1800)]
    [int]$TimeoutSeconds = 300,
    [string]$SshHost = "rk3588",
    [string]$RemoteRoot = "/userdata/photo-restore-v2"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
if ([string]::IsNullOrWhiteSpace($InputImage)) {
    $InputImage = Join-Path $ProjectRoot "data\validation\div2k-x4-sample\raw\0810x4.png"
}
$InputPath = (Resolve-Path -LiteralPath $InputImage).Path
$OutputRoot = Join-Path $ProjectRoot "benchmarks\web-api-smoke"
$OutputPath = Join-Path $OutputRoot "api-smoke-output.png"
$ReportPath = Join-Path $OutputRoot "api-smoke-report.json"
$RemoteInput = "${RemoteRoot}/storage/tmp/api-smoke-input$([System.IO.Path]::GetExtension($InputPath).ToLowerInvariant())"
$RemoteOutput = "${RemoteRoot}/storage/tmp/api-smoke-output.png"
$RemoteReport = "${RemoteRoot}/storage/tmp/api-smoke-report.json"
$SshOptions = @("-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3")

function Invoke-CaptureChecked {
    param([scriptblock]$Command, [string]$Description)
    $Previous = $ErrorActionPreference
    try { $ErrorActionPreference = "Continue"; $Lines = @(& $Command); $Code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $Previous }
    if ($Code -ne 0) { throw "$Description failed with exit code $Code" }
    return (($Lines | ForEach-Object { "$_" }) -join "`n").Trim()
}

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
foreach ($Path in @($OutputPath, $ReportPath)) { if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force } }

Write-Output "Uploading one isolated API smoke-test image..."
& scp @SshOptions $InputPath "${SshHost}:${RemoteInput}"
if ($LASTEXITCODE -ne 0) { throw "Uploading the API smoke-test image failed" }

Write-Output "Creating an HTTP restoration job..."
$CreateText = Invoke-CaptureChecked { ssh @SshOptions $SshHost "curl --fail --silent --show-error -F 'file=@${RemoteInput}' http://127.0.0.1:8080/api/jobs" } "Creating the API job"
$Created = $CreateText | ConvertFrom-Json
$JobId = [string]$Created.id
if ($JobId -notmatch '^[0-9a-f]{32}$') { throw "API returned an invalid job id" }
Write-Output "API_JOB_ID=$JobId"

$Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$LastState = ""
$Final = $null
while ([DateTime]::UtcNow -lt $Deadline) {
    Start-Sleep -Seconds 5
    $StatusText = Invoke-CaptureChecked { ssh @SshOptions $SshHost "curl --fail --silent --show-error http://127.0.0.1:8080/api/jobs/${JobId}" } "Reading API job status"
    $Status = $StatusText | ConvertFrom-Json
    if ($Status.state -ne $LastState) { Write-Output "API_JOB_STATUS=$($Status.state)"; $LastState = $Status.state }
    if ($Status.state -eq "COMPLETE") { $Final = $Status; break }
    if ($Status.state -eq "FAILED") { throw "API job failed: $($Status.error)" }
}
if ($null -eq $Final) { throw "API job timed out after $TimeoutSeconds seconds" }

Write-Output "Downloading output and report through HTTP..."
Invoke-CaptureChecked { ssh @SshOptions $SshHost "curl --fail --silent --show-error http://127.0.0.1:8080/api/jobs/${JobId}/output -o '${RemoteOutput}' && curl --fail --silent --show-error http://127.0.0.1:8080/api/jobs/${JobId}/report -o '${RemoteReport}'" } "Downloading API results on the board" | Out-Null
& scp @SshOptions "${SshHost}:${RemoteOutput}" $OutputPath
if ($LASTEXITCODE -ne 0) { throw "Downloading API output failed" }
& scp @SshOptions "${SshHost}:${RemoteReport}" $ReportPath
if ($LASTEXITCODE -ne 0) { throw "Downloading API report failed" }
$OutputHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $OutputPath).Hash.ToLowerInvariant()
if ($OutputHash -ne $Final.output_sha256) { throw "Downloaded output SHA-256 mismatch" }

Write-Output "Deleting the verified API job..."
$DeleteText = Invoke-CaptureChecked { ssh @SshOptions $SshHost "curl --fail --silent --show-error -X DELETE http://127.0.0.1:8080/api/jobs/${JobId}" } "Deleting the API smoke-test job"
$Deleted = $DeleteText | ConvertFrom-Json
if (-not $Deleted.deleted) { throw "API did not confirm job deletion" }
Invoke-CaptureChecked { ssh @SshOptions $SshHost "rm -f '${RemoteInput}' '${RemoteOutput}' '${RemoteReport}'" } "Cleaning API smoke-test transfer files" | Out-Null

Write-Output "Output: $OutputPath"
Write-Output "Report: $ReportPath"
Write-Output "RESULT=PASS_WEB_API_SMOKE_TEST"
