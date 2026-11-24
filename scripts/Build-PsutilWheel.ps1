#Requires -Version 7.4
param(
    [Parameter(Mandatory)]
    [ValidateSet('1', '2')]
    [string]$Replica,

    [string]$ConfigPath,
    [string]$BuildRoot
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $repoRoot 'build-inputs.json'
}
if (-not $BuildRoot) {
    $BuildRoot = Join-Path $repoRoot 'build'
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-FileSha256 {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedHash
    )
    $actualHash = Get-FileSha256 $Path
    if ($actualHash -ne $ExpectedHash.ToLowerInvariant()) {
        throw "SHA256 mismatch for $Path. Expected $ExpectedHash, got $actualHash"
    }
    return $actualHash
}

function Get-VerifiedDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile,
        [Parameter(Mandatory)][string]$Sha256
    )
    if (Test-Path -LiteralPath $OutFile -PathType Leaf) {
        Write-Host "Verifying existing download: $OutFile"
    }
    else {
        Write-Host "Downloading $Url"
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -MaximumRetryCount 3 -RetryIntervalSec 5
    }
    $hash = Assert-FileSha256 -Path $OutFile -ExpectedHash $Sha256
    Write-Host "SHA256 verified for $(Split-Path -Leaf $OutFile): $hash"
}

function Get-FirstNativeLine {
    param([Parameter(Mandatory)][string]$Command)
    $oldPreference = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $line = & $Command 2>&1 | Select-Object -First 1
        if ($null -eq $line) {
            return ''
        }
        return $line.ToString().Trim()
    }
    finally {
        $PSNativeCommandUseErrorActionPreference = $oldPreference
    }
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
foreach ($hash in @($config.psutil.sdistSha256, $config.pip.wheelSha256, $config.setuptools.wheelSha256, $config.pygtkwin.archiveSha256)) {
    if ($hash -notmatch '^[0-9a-f]{64}$') {
        throw "Invalid lowercase SHA256 in ${ConfigPath}: $hash"
    }
}

$workDir = Join-Path $BuildRoot "replica$Replica"
if (Test-Path -LiteralPath $workDir) {
    throw "Build workspace already exists: $workDir. Use a clean workspace."
}
New-Item -ItemType Directory -Path $workDir | Out-Null

$downloadDir = Join-Path $workDir 'downloads'
$wheelhouseDir = Join-Path $workDir 'wheelhouse'
$runtimeDir = Join-Path $workDir 'runtime'
$sourceRoot = Join-Path $workDir 'source'
$distDir = Join-Path $workDir 'dist'
foreach ($dir in @($downloadDir, $wheelhouseDir, $runtimeDir, $sourceRoot, $distDir)) {
    New-Item -ItemType Directory -Path $dir | Out-Null
}

$pygtkArchive = Join-Path $downloadDir $config.pygtkwin.archiveFileName
$pipWheel = Join-Path $wheelhouseDir $config.pip.wheelFileName
$setuptoolsWheel = Join-Path $wheelhouseDir $config.setuptools.wheelFileName
$psutilSdist = Join-Path $downloadDir "psutil-$($config.psutil.version).tar.gz"

Get-VerifiedDownload -Url $config.pygtkwin.archiveUrl -OutFile $pygtkArchive -Sha256 $config.pygtkwin.archiveSha256
Get-VerifiedDownload -Url $config.pip.wheelUrl -OutFile $pipWheel -Sha256 $config.pip.wheelSha256
Get-VerifiedDownload -Url $config.setuptools.wheelUrl -OutFile $setuptoolsWheel -Sha256 $config.setuptools.wheelSha256
Get-VerifiedDownload -Url $config.psutil.sdistUrl -OutFile $psutilSdist -Sha256 $config.psutil.sdistSha256

& 7z x -bso0 -bsp0 $pygtkArchive "-o$runtimeDir"

$vcpkgDir = Join-Path $runtimeDir 'vcpkg_installed\x86-windows'
$pythonDir = Join-Path $vcpkgDir 'tools\python3'
$python = Join-Path $pythonDir 'python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    throw "Python executable not found at $python"
}

$pointerSize = (& $python -c 'import struct; print(struct.calcsize("P"))').Trim()
if ($pointerSize -ne '4') {
    throw "Expected 32-bit Python, but struct.calcsize('P') is $pointerSize"
}
$pythonVersion = (& $python -c 'import sys; print(sys.version.replace(chr(10), " "))').Trim()
Write-Host "Python: $pythonVersion"
Write-Host 'Python pointer size confirms a 32-bit interpreter.'

$stableAbiDll = Join-Path $vcpkgDir 'bin\python3.dll'
if (-not (Test-Path -LiteralPath $stableAbiDll -PathType Leaf)) {
    throw "Stable ABI runtime DLL not found at $stableAbiDll"
}
Copy-Item -LiteralPath $stableAbiDll -Destination (Join-Path $pythonDir 'python3.dll') -Force

& $python -m ensurepip --upgrade

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$pipRequirements = Join-Path $workDir 'requirements-pip.txt'
$setuptoolsRequirements = Join-Path $workDir 'requirements-setuptools.txt'
[System.IO.File]::WriteAllText($pipRequirements, "pip==$($config.pip.version) --hash=sha256:$($config.pip.wheelSha256)`n", $utf8NoBom)
[System.IO.File]::WriteAllText($setuptoolsRequirements, "setuptools==$($config.setuptools.version) --hash=sha256:$($config.setuptools.wheelSha256)`n", $utf8NoBom)

$pipInstallArgs = @(
    '--disable-pip-version-check',
    '--no-cache-dir',
    '--no-index',
    "--find-links=$wheelhouseDir",
    '--only-binary', ':all:',
    '--require-hashes',
    '--force-reinstall',
    '--no-deps'
)
& $python -m pip install @pipInstallArgs -r $pipRequirements
& $python -m pip install @pipInstallArgs -r $setuptoolsRequirements

$pipVersionOutput = (& $python -m pip --version).Trim()
$installedPipVersion = ($pipVersionOutput -split '\s+')[1]
if ($installedPipVersion -ne $config.pip.version) {
    throw "Expected pip $($config.pip.version), got $installedPipVersion"
}
$installedSetuptoolsVersion = (& $python -c 'import setuptools; print(setuptools.__version__)').Trim()
if ($installedSetuptoolsVersion -ne $config.setuptools.version) {
    throw "Expected setuptools $($config.setuptools.version), got $installedSetuptoolsVersion"
}
Write-Host "pip: $installedPipVersion"
Write-Host "setuptools: $installedSetuptoolsVersion"

$stableAbiLib = Join-Path $vcpkgDir 'lib\python3.lib'
if (-not (Test-Path -LiteralPath $stableAbiLib -PathType Leaf)) {
    throw "Stable ABI import library not found at $stableAbiLib"
}
$libsDir = Join-Path $pythonDir 'libs'
New-Item -ItemType Directory -Force -Path $libsDir | Out-Null
Copy-Item -LiteralPath $stableAbiLib -Destination (Join-Path $libsDir 'python3.lib') -Force

Push-Location $sourceRoot
try {
    & tar -xf $psutilSdist
}
finally {
    Pop-Location
}
$sourceDir = Join-Path $sourceRoot "psutil-$($config.psutil.version)"
if (-not (Test-Path -LiteralPath $sourceDir -PathType Container)) {
    throw "Extracted psutil source not found at $sourceDir"
}

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
    throw "vswhere not found at $vswhere"
}
$vsPath = (& $vswhere -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
$vsVersion = (& $vswhere -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationVersion).Trim()
$vsDisplayName = (& $vswhere -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property displayName).Trim()
if (-not $vsPath) {
    throw 'No Visual Studio installation with the x86/x64 C++ tools was found'
}
Import-Module (Join-Path $vsPath 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll')
Enter-VsDevShell -VsInstallPath $vsPath -SkipAutomaticLocation -DevCmdArguments '-arch=x86 -host_arch=amd64'

if (-not (Get-Command cl -ErrorAction SilentlyContinue)) {
    throw 'cl.exe is not available after entering the Visual Studio developer environment'
}
if (-not (Get-Command link -ErrorAction SilentlyContinue)) {
    throw 'link.exe is not available after entering the Visual Studio developer environment'
}
if (-not (Get-Command dumpbin -ErrorAction SilentlyContinue)) {
    throw 'dumpbin.exe is not available after entering the Visual Studio developer environment'
}
$compilerVersion = Get-FirstNativeLine -Command 'cl'
$linkerVersion = Get-FirstNativeLine -Command 'link'
Write-Host "Compiler: $compilerVersion"
Write-Host "Linker: $linkerVersion"

$latestSourceWriteTime = [datetime]::MinValue
Get-ChildItem -LiteralPath $sourceDir -Recurse -File | ForEach-Object {
    if ($_.LastWriteTimeUtc -gt $latestSourceWriteTime) {
        $script:latestSourceWriteTime = $_.LastWriteTimeUtc
    }
}
$sourceDateEpoch = [int64]($latestSourceWriteTime - [datetime]::UnixEpoch).TotalSeconds
if ($sourceDateEpoch -lt 315532800) {
    throw "Invalid SOURCE_DATE_EPOCH candidate: $sourceDateEpoch"
}
$env:SOURCE_DATE_EPOCH = [string]$sourceDateEpoch
$env:DISTUTILS_USE_SDK = '1'
if ($env:_LINK_) {
    $env:_LINK_ = "$env:_LINK_ /Brepro"
}
else {
    $env:_LINK_ = '/Brepro'
}
Write-Host "SOURCE_DATE_EPOCH: $env:SOURCE_DATE_EPOCH"
Write-Host "_LINK_: $env:_LINK_"

& $python -m pip wheel `
    --disable-pip-version-check `
    --no-cache-dir `
    --no-deps `
    --no-build-isolation `
    --wheel-dir $distDir `
    $sourceDir

$wheelFiles = @(Get-ChildItem -LiteralPath $distDir -Filter 'psutil-*.whl' -File)
if ($wheelFiles.Count -ne 1) {
    throw "Expected exactly one psutil wheel in $distDir, found $($wheelFiles.Count)"
}
$wheel = $wheelFiles[0]
$expectedWheelName = [string]$config.psutil.expectedWheelFileName
if ($wheel.Name -ne $expectedWheelName) {
    throw "Expected wheel $expectedWheelName, got $($wheel.Name)"
}

$pydInspectDir = Join-Path $workDir 'pyd-inspect'
New-Item -ItemType Directory -Path $pydInspectDir | Out-Null
& $python -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extract("psutil/_psutil_windows.pyd", sys.argv[2])' $wheel.FullName $pydInspectDir
$pydPath = Join-Path $pydInspectDir 'psutil\_psutil_windows.pyd'
if (-not (Test-Path -LiteralPath $pydPath -PathType Leaf)) {
    throw "Could not extract psutil/_psutil_windows.pyd from $($wheel.FullName)"
}
$dumpbinText = (& dumpbin /dependents $pydPath | Out-String)
if ($dumpbinText -notmatch 'python3\.dll') {
    throw "_psutil_windows.pyd does not depend on python3.dll`n$dumpbinText"
}
if ($dumpbinText -match 'python\d{2,}\.dll') {
    throw "_psutil_windows.pyd depends on a versioned Python DLL instead of only python3.dll`n$dumpbinText"
}

$wheelHash = Get-FileSha256 $wheel.FullName
$artifactWheelName = $expectedWheelName -replace '\.whl$', ".replica$Replica.whl"
$artifactWheel = Join-Path $workDir $artifactWheelName
Copy-Item -LiteralPath $wheel.FullName -Destination $artifactWheel
$sha256File = Join-Path $workDir "SHA256SUMS.replica$Replica.txt"
[System.IO.File]::WriteAllText($sha256File, "$wheelHash  $expectedWheelName`n", $utf8NoBom)

$workflowRunUrl = ''
if ($env:GITHUB_SERVER_URL -and $env:GITHUB_REPOSITORY -and $env:GITHUB_RUN_ID) {
    $workflowRunUrl = "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
}

$buildInfoFile = Join-Path $workDir "BUILD-INFO.replica$Replica.txt"
$buildInfoLines = @(
    "Replica: $Replica"
    "Generated UTC: $((Get-Date).ToUniversalTime().ToString('o'))"
    "Runner OS: $env:RUNNER_OS"
    "Runner name: $env:RUNNER_NAME"
    "Runner architecture: $env:RUNNER_ARCH"
    "Runner image: $env:ImageVersion"
    "Workflow run: $workflowRunUrl"
    "Repository: $env:GITHUB_REPOSITORY"
    "Commit: $env:GITHUB_SHA"
    "Python executable: $python"
    "Python version: $pythonVersion"
    "Python pointer size: $pointerSize"
    "Stable ABI runtime copied from: $stableAbiDll"
    "pip version: $installedPipVersion"
    "setuptools version: $installedSetuptoolsVersion"
    "Visual Studio display name: $vsDisplayName"
    "Visual Studio version: $vsVersion"
    "Visual Studio path: $vsPath"
    "Compiler version: $compilerVersion"
    "Linker version: $linkerVersion"
    "SOURCE_DATE_EPOCH: $env:SOURCE_DATE_EPOCH"
    "DISTUTILS_USE_SDK: $env:DISTUTILS_USE_SDK"
    "_LINK_: $env:_LINK_"
    "pygtkwin release: $($config.pygtkwin.releaseTag)"
    "pygtkwin archive SHA256: $($config.pygtkwin.archiveSha256)"
    "pip wheel SHA256: $($config.pip.wheelSha256)"
    "setuptools wheel SHA256: $($config.setuptools.wheelSha256)"
    "psutil sdist SHA256: $($config.psutil.sdistSha256)"
    "Wheel filename: $expectedWheelName"
    "Wheel SHA256: $wheelHash"
)
[System.IO.File]::WriteAllText($buildInfoFile, ([string]::Join("`n", $buildInfoLines)) + "`n", $utf8NoBom)

if ($env:GITHUB_OUTPUT) {
    $outputLines = @(
        "wheel-path=$($wheel.FullName)"
        "wheel-artifact=$artifactWheel"
        "sha256-file=$sha256File"
        "build-info-file=$buildInfoFile"
        "python-path=$python"
    )
    [System.IO.File]::AppendAllLines($env:GITHUB_OUTPUT, [string[]]$outputLines)
}

Write-Host "Built $expectedWheelName"
Write-Host "SHA256: $wheelHash"
