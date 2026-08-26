param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('BasicVSR++', 'RealBasicVSR')]
    [string]$Candidate,
    [switch]$DownloadWeights,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$OutputDirectory = Join-Path $ProjectRoot "data\video-development\model-candidates\$Candidate"
$WeightsDirectory = Join-Path $OutputDirectory 'weights'
$Artifacts = switch ($Candidate) {
    'BasicVSR++' { @(
        @{ Name = 'basicvsr_plusplus_x4.pth'; Url = 'https://download.openmmlab.com/mmediting/restorers/basicvsr_plusplus/basicvsr_plusplus_c64n7_8x1_600k_reds4_20210217-db622b2f.pth'; Purpose = 'BasicVSR++ official BIx4/BDx4 checkpoint'; Sha256 = 'db622b2fd4caae0a4c63ab5e54f1cfef7a62a0f3b8ad101aba2eae068d928549' },
        @{ Name = 'spynet.pth'; Url = 'https://download.openmmlab.com/mmediting/restorers/basicvsr/spynet_20210409-c6c1bd09.pth'; Purpose = 'SPyNet optical-flow dependency'; Sha256 = 'c6c1bd09b52d05ba17f3e701f549d6faf5e314aabce8ae462c1c171a8d6c4914' }
    ) }
    'RealBasicVSR' { @(
        @{ Name = 'realbasicvsr_1x.pth'; Url = 'https://download.openmmlab.com/mmediting/restorers/real_basicvsr/realbasicvsr_c64b20_1x30x8_lr5e-5_150k_reds_20211104-52f77c2c.pth'; Purpose = 'RealBasicVSR official 1x cleanup checkpoint'; Sha256 = $null }
    ) }
}
if (-not $DownloadWeights) {
    Write-Output "Candidate: $Candidate"
    Write-Output "Artifacts: $($Artifacts.Count)"
    $Artifacts | ForEach-Object { Write-Output "PLAN=$($_.Name) $($_.Url)" }
    Write-Output 'No files downloaded. Re-run with -DownloadWeights to download into the ignored project cache.'
    Write-Output 'RESULT=PASS_VIDEO_MODEL_ARTIFACT_PLAN'
    return
}
if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null }
if (-not (Test-Path -LiteralPath $WeightsDirectory)) { New-Item -ItemType Directory -Force -Path $WeightsDirectory | Out-Null }
$Headers = @{ 'User-Agent' = 'photo-restore-v2-model-fetch' }
$Records = @()
foreach ($artifact in $Artifacts) {
    $destination = Join-Path $WeightsDirectory $artifact.Name
    if ((Test-Path -LiteralPath $destination) -and -not $Force) {
        Write-Output "REUSE=$destination"
    } else {
        Write-Output "Downloading $($artifact.Name) into the isolated project cache..."
        $temporary = "$destination.part"
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        try {
            Invoke-WebRequest -Uri $artifact.Url -Headers $Headers -UseBasicParsing -OutFile $temporary
            Move-Item -LiteralPath $temporary -Destination $destination -Force
        } finally {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not (Test-Path -LiteralPath $destination) -or (Get-Item $destination).Length -le 0) { throw "Downloaded artifact is empty: $destination" }
    $ActualSha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($artifact.Sha256 -and $ActualSha256 -ne $artifact.Sha256) {
        throw "SHA-256 mismatch for $($artifact.Name): $ActualSha256 != $($artifact.Sha256)"
    }
    $Records += [ordered]@{ name = $artifact.Name; purpose = $artifact.Purpose; url = $artifact.Url; path = $destination; bytes = (Get-Item $destination).Length; sha256 = $ActualSha256; expected_sha256 = $artifact.Sha256 }
}
$record = [ordered]@{ schema_version = 1; candidate = $Candidate; downloaded_at_utc = [DateTime]::UtcNow.ToString('o'); weights_downloaded = $true; board_upload = $false; artifacts = $Records; status = 'downloaded_pending_onnx_export_and_license_review' }
$record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'weights-record.json') -Encoding utf8
Write-Output "Output: $WeightsDirectory"
Write-Output 'Board upload: False'
Write-Output 'RESULT=PASS_VIDEO_MODEL_ARTIFACT_DOWNLOAD'
