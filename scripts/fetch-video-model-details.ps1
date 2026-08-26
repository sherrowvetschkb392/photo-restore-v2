param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('RealBasicVSR', 'BasicVSR++', 'RVRT', 'RIFE-small', 'IFRNet')]
    [string]$Candidate,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$OutputDirectory = Join-Path $ProjectRoot "data\video-development\model-candidates\$Candidate"
if ((Test-Path -LiteralPath $OutputDirectory) -and -not $Force -and (Test-Path (Join-Path $OutputDirectory 'details-record.json'))) {
    Write-Output "Details already exist; reusing: $OutputDirectory"
    Write-Output 'Weights downloaded: False'
    Write-Output 'RESULT=PASS_VIDEO_MODEL_DETAILS_REUSED'
    return
}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$Headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'photo-restore-v2-candidate-review' }
$Paths = switch ($Candidate) {
    'RealBasicVSR' { @(
        @{ Name = 'config-readme.json'; Url = 'https://api.github.com/repos/open-mmlab/mmagic/contents/configs/real_basicvsr/README.md' },
        @{ Name = 'config-tree.json'; Url = 'https://api.github.com/repos/open-mmlab/mmagic/contents/configs/real_basicvsr' }
    ) }
    'BasicVSR++' { @(
        @{ Name = 'config-readme.json'; Url = 'https://api.github.com/repos/open-mmlab/mmagic/contents/configs/basicvsr_pp/README.md' },
        @{ Name = 'config-tree.json'; Url = 'https://api.github.com/repos/open-mmlab/mmagic/contents/configs/basicvsr_pp' }
    ) }
    'RVRT' { @(
        @{ Name = 'repository-tree.json'; Url = 'https://api.github.com/repos/JingyunLiang/RVRT/contents' },
        @{ Name = 'repository-readme.json'; Url = 'https://api.github.com/repos/JingyunLiang/RVRT/readme' }
    ) }
    'RIFE-small' { @(
        @{ Name = 'repository-tree.json'; Url = 'https://api.github.com/repos/hzwer/ECCV2022-RIFE/contents' },
        @{ Name = 'repository-readme.json'; Url = 'https://api.github.com/repos/hzwer/ECCV2022-RIFE/readme' }
    ) }
    'IFRNet' { @(
        @{ Name = 'repository-tree.json'; Url = 'https://api.github.com/repos/ltkong218/IFRNet/contents' },
        @{ Name = 'repository-readme.json'; Url = 'https://api.github.com/repos/ltkong218/IFRNet/readme' }
    ) }
}
foreach ($item in $Paths) {
    Write-Output "Reading $($item.Url)..."
    Invoke-WebRequest -Uri $item.Url -Headers $Headers -UseBasicParsing |
        Select-Object -ExpandProperty Content |
        Set-Content -LiteralPath (Join-Path $OutputDirectory $item.Name) -Encoding utf8
}
$record = [ordered]@{
    schema_version = 1
    candidate = $Candidate
    fetched_at_utc = [DateTime]::UtcNow.ToString('o')
    paths = $Paths
    weights_downloaded = $false
    board_upload = $false
    status = 'details_only_pending_weight_license_and_checksum_review'
}
$record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'details-record.json') -Encoding utf8
Write-Output "Output: $OutputDirectory"
Write-Output 'Weights downloaded: False'
Write-Output 'Board upload: False'
Write-Output 'RESULT=PASS_VIDEO_MODEL_DETAILS_FETCH'
