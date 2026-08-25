param(
    [int[]]$TileSizes = @(64, 80, 96, 112, 128),
    [int]$Runs = 7,
    [int]$OverlapPerSide = 8,
    [string]$Distribution = "Ubuntu",
    [string]$CondaEnvironment = "photo-restore-rknn232",
    [string]$LinuxRoot = "/home/ljd/photo-restore-rknn232",
    [string]$SshHost = "rk3588"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$PipelineScript = Join-Path $PSScriptRoot "build-and-validate-model.ps1"
$BenchmarkDirectory = Join-Path $ProjectRoot "benchmarks"
$AllowedSizes = @(64, 80, 96, 112, 128)

foreach ($TileSize in $TileSizes) {
    if ($AllowedSizes -notcontains $TileSize) {
        throw "Unsupported matrix tile size: $TileSize. Allowed: $($AllowedSizes -join ', ')"
    }
}

if ($Runs -lt 3) {
    throw "Runs must be at least 3"
}
if ($OverlapPerSide -lt 0) {
    throw "OverlapPerSide cannot be negative"
}

foreach ($TileSize in $TileSizes) {
    Write-Output "`n############################################################"
    Write-Output "Benchmark tile $TileSize"
    Write-Output "############################################################"
    & $PipelineScript `
        -TileSize $TileSize `
        -Runs $Runs `
        -Distribution $Distribution `
        -CondaEnvironment $CondaEnvironment `
        -LinuxRoot $LinuxRoot `
        -SshHost $SshHost
    if ($LASTEXITCODE -ne 0) {
        throw "Tile $TileSize pipeline failed with exit code $LASTEXITCODE"
    }
}

$Rows = foreach ($TileSize in $TileSizes) {
    $ReportPath = Join-Path $BenchmarkDirectory "tile${TileSize}-board-report.json"
    if (-not (Test-Path -LiteralPath $ReportPath)) {
        throw "Board report missing: $ReportPath"
    }

    $Report = Get-Content -Raw -LiteralPath $ReportPath | ConvertFrom-Json
    $Seconds = [double]$Report.steady_mean_seconds
    $EffectiveEdge = $TileSize - (2 * $OverlapPerSide)
    if ($EffectiveEdge -le 0) {
        throw "Overlap $OverlapPerSide is too large for tile $TileSize"
    }

    [pscustomobject]@{
        Tile = $TileSize
        SecondsPerTile = [math]::Round($Seconds, 6)
        RawPixelsPerSecond = [math]::Round(($TileSize * $TileSize) / $Seconds, 0)
        EffectiveEdge = $EffectiveEdge
        EffectivePixelsPerSecond = [math]::Round(($EffectiveEdge * $EffectiveEdge) / $Seconds, 0)
        PeakRssMiB = [math]::Round(([double]$Report.max_rss_kib / 1024), 1)
        MeanAbsError = [double]$Report.mean_abs_error
        MaxAbsError = [double]$Report.max_abs_error
        NpuBeforeC = [double]$Report.temperature_before_c.'npu-thermal'
        NpuAfterC = [double]$Report.temperature_after_c.'npu-thermal'
    }
}

$Ranked = $Rows | Sort-Object EffectivePixelsPerSecond -Descending
$CsvPath = Join-Path $BenchmarkDirectory "tile-matrix-overlap${OverlapPerSide}.csv"
$JsonPath = Join-Path $BenchmarkDirectory "tile-matrix-overlap${OverlapPerSide}.json"
$Ranked | Export-Csv -NoTypeInformation -Encoding UTF8 -LiteralPath $CsvPath
$Ranked | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath $JsonPath

Write-Output "`n================ TILE MATRIX RESULT ================"
$Ranked | Format-Table -AutoSize
$Winner = $Ranked | Select-Object -First 1
Write-Output "Recommended tile for overlap ${OverlapPerSide}px/side: $($Winner.Tile)"
Write-Output "CSV report: $CsvPath"
Write-Output "JSON report: $JsonPath"
Write-Output "RESULT=PASS_TILE_MATRIX"

