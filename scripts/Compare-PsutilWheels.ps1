#Requires -Version 7.4
param(
    [Parameter(Mandatory)]
    [string]$ArtifactsDir,

    [Parameter(Mandatory)]
    [string]$OutputDir,

    [string]$ConfigPath,

    [ValidateRange(2, 2)]
    [int]$ExpectedReplicaCount = 2
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $repoRoot 'build-inputs.json'
}
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$expectedWheelName = [string]$config.psutil.expectedWheelFileName

if (-not (Test-Path -LiteralPath $ArtifactsDir -PathType Container)) {
    throw "Artifacts directory not found at $ArtifactsDir"
}
if (Test-Path -LiteralPath $OutputDir) {
    throw "Output directory already exists: $OutputDir"
}
New-Item -ItemType Directory -Path $OutputDir | Out-Null

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$replicaResults = @{}

for ($replica = 1; $replica -le $ExpectedReplicaCount; $replica++) {
    $carrierName = $expectedWheelName -replace '\.whl$', ".replica$replica.whl"
    $carrierPath = Join-Path $ArtifactsDir $carrierName
    $hashPath = Join-Path $ArtifactsDir "SHA256SUMS.replica$replica.txt"
    $buildInfoPath = Join-Path $ArtifactsDir "BUILD-INFO.replica$replica.txt"

    foreach ($path in @($carrierPath, $hashPath, $buildInfoPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required artifact not found: $path"
        }
    }

    $hashLines = @(Get-Content -LiteralPath $hashPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($hashLines.Count -ne 1) {
        throw "Expected exactly one hash line in $hashPath, found $($hashLines.Count)"
    }
    $parts = ($hashLines[0]) -split '\s+', 2
    if ($parts.Count -ne 2) {
        throw "Could not parse hash line in $hashPath"
    }
    $expectedHash = $parts[0].Trim()
    $hashedFileName = $parts[1].Trim()
    if ($expectedHash -notmatch '^[0-9a-f]{64}$') {
        throw "Invalid SHA256 in ${hashPath}: $expectedHash"
    }
    if ($hashedFileName -ne $expectedWheelName) {
        throw "Hash file $hashPath is for $hashedFileName, not $expectedWheelName"
    }

    $actualHash = (Get-FileHash -LiteralPath $carrierPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        throw "SHA256 mismatch for replica $replica. Expected $expectedHash, got $actualHash"
    }

    $replicaResults[$replica] = [pscustomobject]@{
        CarrierPath   = $carrierPath
        Hash          = $actualHash
        BuildInfoPath = $buildInfoPath
        Length        = (Get-Item -LiteralPath $carrierPath).Length
    }
}

$firstHash = $replicaResults[1].Hash
$firstLength = $replicaResults[1].Length
for ($replica = 2; $replica -le $ExpectedReplicaCount; $replica++) {
    if ($replicaResults[$replica].Hash -ne $firstHash) {
        throw "Replica $replica SHA256 $($replicaResults[$replica].Hash) differs from replica 1 SHA256 $firstHash"
    }
    if ($replicaResults[$replica].Length -ne $firstLength) {
        throw "Replica $replica length differs from replica 1 length"
    }
}

$finalWheel = Join-Path $OutputDir $expectedWheelName
Copy-Item -LiteralPath $replicaResults[1].CarrierPath -Destination $finalWheel
$finalHash = (Get-FileHash -LiteralPath $finalWheel -Algorithm SHA256).Hash.ToLowerInvariant()
if ($finalHash -ne $firstHash) {
    throw "Final wheel hash changed while copying"
}

$finalSha256File = Join-Path $OutputDir 'SHA256SUMS.txt'
[System.IO.File]::WriteAllText($finalSha256File, "$finalHash  $expectedWheelName`n", $utf8NoBom)

$builder = [System.Text.StringBuilder]::new()
[void]$builder.AppendLine('psutil win32 wheel build')
[void]$builder.AppendLine()
[void]$builder.AppendLine("Reproducibility: $ExpectedReplicaCount clean builds produced identical SHA256 hashes.")
[void]$builder.AppendLine("Wheel filename: $expectedWheelName")
[void]$builder.AppendLine("Wheel SHA256: $finalHash")
[void]$builder.AppendLine()
for ($replica = 1; $replica -le $ExpectedReplicaCount; $replica++) {
    [void]$builder.AppendLine("--- Replica $replica ---")
    [void]$builder.AppendLine()
    [void]$builder.AppendLine((Get-Content -LiteralPath $replicaResults[$replica].BuildInfoPath -Raw).TrimEnd())
    [void]$builder.AppendLine()
}
$finalBuildInfoFile = Join-Path $OutputDir 'BUILD-INFO.txt'
[System.IO.File]::WriteAllText($finalBuildInfoFile, $builder.ToString(), $utf8NoBom)

if ($env:GITHUB_OUTPUT) {
    $outputLines = @(
        "final-wheel=$finalWheel"
        "sha256sums=$finalSha256File"
        "build-info=$finalBuildInfoFile"
    )
    [System.IO.File]::AppendAllLines($env:GITHUB_OUTPUT, [string[]]$outputLines)
}

Write-Host "Replicas are bit-for-bit identical by SHA256: $finalHash"
