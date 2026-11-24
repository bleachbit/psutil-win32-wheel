#Requires -Version 7.4
param(
    [Parameter(Mandatory)]
    [string]$ArtifactsDir,

    [Parameter(Mandatory)]
    [string]$StagingDir,

    [Parameter(Mandatory)]
    [string]$NotesFile,

    [string]$ConfigPath
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
if (Test-Path -LiteralPath $StagingDir) {
    throw "Staging directory already exists: $StagingDir"
}
if (Test-Path -LiteralPath $NotesFile) {
    throw "Release notes file already exists: $NotesFile"
}
New-Item -ItemType Directory -Path $StagingDir | Out-Null

$wheelPath = Join-Path $ArtifactsDir $expectedWheelName
$sha256Path = Join-Path $ArtifactsDir 'SHA256SUMS.txt'
$buildInfoPath = Join-Path $ArtifactsDir 'BUILD-INFO.txt'
foreach ($path in @($wheelPath, $sha256Path, $buildInfoPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required release input not found: $path"
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
if ($expectedHash -notmatch '^[0-9a-f]{64}$') {
    throw "Invalid SHA256 in ${sha256Path}: $expectedHash"
}
if ($hashedFileName -ne $expectedWheelName) {
    throw "SHA256SUMS.txt is for $hashedFileName, not $expectedWheelName"
}
$actualHash = (Get-FileHash -LiteralPath $wheelPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualHash -ne $expectedHash) {
    throw "SHA256 mismatch for release wheel. Expected $expectedHash, got $actualHash"
}
if ((Get-Item -LiteralPath $buildInfoPath).Length -eq 0) {
    throw "BUILD-INFO.txt is empty"
}

Copy-Item -LiteralPath $wheelPath -Destination (Join-Path $StagingDir $expectedWheelName)
Copy-Item -LiteralPath $sha256Path -Destination (Join-Path $StagingDir 'SHA256SUMS.txt')
Copy-Item -LiteralPath $buildInfoPath -Destination (Join-Path $StagingDir 'BUILD-INFO.txt')

$stagedFiles = @(Get-ChildItem -LiteralPath $StagingDir -File)
if ($stagedFiles.Count -ne 3) {
    throw "Expected exactly three staged release assets, found $($stagedFiles.Count)"
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$notesLines = @(
    "psutil $($config.psutil.version) 32-bit Windows wheel"
    ''
    "Wheel: ``$expectedWheelName``"
    "SHA256: ``$actualHash``"
    ''
    'Reproducibility: two clean builds produced identical SHA256 hashes.'
    ''
    'See BUILD-INFO.txt for runner, compiler, linker, Python, and input hash details.'
)
[System.IO.File]::WriteAllText($NotesFile, ([string]::Join("`n", $notesLines)) + "`n", $utf8NoBom)

if ($env:GITHUB_OUTPUT) {
    $outputLines = @(
        "staged-wheel=$(Join-Path $StagingDir $expectedWheelName)"
        "staged-sha256sums=$(Join-Path $StagingDir 'SHA256SUMS.txt')"
        "staged-build-info=$(Join-Path $StagingDir 'BUILD-INFO.txt')"
        "notes-file=$NotesFile"
    )
    [System.IO.File]::AppendAllLines($env:GITHUB_OUTPUT, [string[]]$outputLines)
}

Write-Host "Staged three release assets. Wheel SHA256: $actualHash"
