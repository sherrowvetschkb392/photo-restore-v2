param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('RIFE-small', 'IFRNet', 'RealBasicVSR', 'BasicVSR++', 'RVRT')]
    [string]$Candidate,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$OutputRoot = Join-Path $ProjectRoot 'data\video-development\model-candidates'
$CandidateMap = @{
    'RIFE-small' = @{ Repository = 'hzwer/ECCV2022-RIFE'; Family = 'interpolation' }
    'IFRNet' = @{ Repository = 'ltkong218/IFRNet'; Family = 'interpolation' }
    'RealBasicVSR' = @{ Repository = 'open-mmlab/mmagic'; Family = 'video_super_resolution' }
    'BasicVSR++' = @{ Repository = 'open-mmlab/mmagic'; Family = 'video_super_resolution' }
    'RVRT' = @{ Repository = 'JingyunLiang/RVRT'; Family = 'video_super_resolution' }
}
$Selection = $CandidateMap[$Candidate]
$OutputDirectory = Join-Path $OutputRoot $Candidate
if ($OutputDirectory -and (Test-Path -LiteralPath $OutputDirectory) -and -not $Force) {
    throw "Metadata directory already exists: $OutputDirectory. Use -Force to refresh it."
}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$Headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'photo-restore-v2-candidate-review' }
$RepositoryUrl = "https://api.github.com/repos/$($Selection.Repository)"
$MetadataPath = Join-Path $OutputDirectory 'repository.json'
$LicensePath = Join-Path $OutputDirectory 'license.json'
$ReadmePath = Join-Path $OutputDirectory 'readme.json'

Write-Output "Reading public repository metadata for $Candidate..."
Invoke-WebRequest -Uri $RepositoryUrl -Headers $Headers -UseBasicParsing |
    Select-Object -ExpandProperty Content | Set-Content -LiteralPath $MetadataPath -Encoding utf8
try {
    Invoke-WebRequest -Uri "$RepositoryUrl/license" -Headers $Headers -UseBasicParsing |
        Select-Object -ExpandProperty Content | Set-Content -LiteralPath $LicensePath -Encoding utf8
} catch {
    '{"status":"unavailable","reason":"repository has no API-detectable license file or access failed"}' |
        Set-Content -LiteralPath $LicensePath -Encoding utf8
}
Invoke-WebRequest -Uri "$RepositoryUrl/readme" -Headers $Headers -UseBasicParsing |
    Select-Object -ExpandProperty Content | Set-Content -LiteralPath $ReadmePath -Encoding utf8

$Record = [ordered]@{
    schema_version = 1
    candidate = $Candidate
    family = $Selection.Family
    repository = $Selection.Repository
    repository_url = "https://github.com/$($Selection.Repository)"
    metadata_file = $MetadataPath
    license_file = $LicensePath
    readme_file = $ReadmePath
    weights_downloaded = $false
    board_upload = $false
    status = 'metadata_only_pending_manual_license_and_weight_review'
    fetched_at_utc = [DateTime]::UtcNow.ToString('o')
}
$Record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'candidate-record.json') -Encoding utf8
Write-Output "Output: $OutputDirectory"
Write-Output "Weights downloaded: False"
Write-Output "Board upload: False"
Write-Output 'RESULT=PASS_VIDEO_MODEL_METADATA_FETCH'
