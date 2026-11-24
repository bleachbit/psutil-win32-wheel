#Requires -Version 7.4
param(
    [Parameter(Mandatory)]
    [string]$Tag,

    [Parameter(Mandatory)]
    [string]$StagingDir,

    [Parameter(Mandatory)]
    [string]$NotesFile,

    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Invoke-GhVerification {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $PSNativeCommandUseErrorActionPreference = $false
    $lastOutputText = ''
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        $output = & gh @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        $lastOutputText = ($output | Out-String).Trim()
        if ($exitCode -eq 0) {
            if ($lastOutputText) {
                Write-Host $lastOutputText
            }
            return
        }
        Start-Sleep -Seconds 5
    }
    throw "gh $($Arguments -join ' ') failed after retries: $lastOutputText"
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $repoRoot 'build-inputs.json'
}
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$expectedWheelName = [string]$config.psutil.expectedWheelFileName

if ($Tag -notmatch '^v\d{4}-\d{2}-\d{2}(-r\d+)?$') {
    throw "Tag $Tag is not a date-based release tag like v2026-11-24 or v2026-11-24-r2"
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI gh is not available'
}
if (-not $env:GITHUB_REPOSITORY) {
    throw 'GITHUB_REPOSITORY is not set'
}

$ghVersionLine = (& gh --version | Select-Object -First 1)
if ($ghVersionLine -notmatch 'gh version (\d+\.\d+\.\d+)') {
    throw "Could not parse gh version from: $ghVersionLine"
}
$ghVersion = [version]$Matches[1]
if ($ghVersion -lt [version]'2.81.0') {
    throw "gh 2.81.0 or newer is required for immutable release verification; found $ghVersion"
}

$wheelPath = Join-Path $StagingDir $expectedWheelName
$sha256Path = Join-Path $StagingDir 'SHA256SUMS.txt'
$buildInfoPath = Join-Path $StagingDir 'BUILD-INFO.txt'
foreach ($path in @($wheelPath, $sha256Path, $buildInfoPath, $NotesFile)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required release file not found: $path"
    }
}

$hashLines = @(Get-Content -LiteralPath $sha256Path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($hashLines.Count -ne 1) {
    throw "Expected exactly one hash line in $sha256Path, found $($hashLines.Count)"
}
$parts = ($hashLines[0]) -split '\s+', 2
if ($parts.Count -ne 2) {
    throw "Could not parse hash line in $sha256Path"
}
$expectedHash = $parts[0].Trim()
$hashedFileName = $parts[1].Trim()
if ($hashedFileName -ne $expectedWheelName) {
    throw "SHA256SUMS.txt is for $hashedFileName, not $expectedWheelName"
}
$actualHash = (Get-FileHash -LiteralPath $wheelPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualHash -ne $expectedHash) {
    throw "SHA256 mismatch for release wheel. Expected $expectedHash, got $actualHash"
}

Write-Host 'Publishing release. Immutable releases must already be enabled for the repository.'

$assetPaths = @($wheelPath, $sha256Path, $buildInfoPath)
$createArgs = @('release', 'create', $Tag) + $assetPaths + @(
    '--title', $Tag,
    '--notes-file', $NotesFile,
    '--verify-tag',
    '--repo', $env:GITHUB_REPOSITORY
)
& gh @createArgs

Invoke-GhVerification -Arguments @('release', 'verify', $Tag, '--repo', $env:GITHUB_REPOSITORY)
foreach ($assetPath in $assetPaths) {
    Invoke-GhVerification -Arguments @('release', 'verify-asset', $Tag, $assetPath, '--repo', $env:GITHUB_REPOSITORY)
}

$releaseUrl = (& gh release view $Tag --json url --jq .url --repo $env:GITHUB_REPOSITORY).Trim()
Write-Host "Release: $releaseUrl"
Write-Host "Wheel SHA256: $actualHash"

if ($env:GITHUB_STEP_SUMMARY) {
    $summaryLines = @(
        "Release: $releaseUrl"
        "Wheel: ``$expectedWheelName``"
        "SHA256: ``$actualHash``"
        'Release and asset attestations verified with gh.'
    )
    [System.IO.File]::AppendAllLines($env:GITHUB_STEP_SUMMARY, [string[]]$summaryLines)
}
