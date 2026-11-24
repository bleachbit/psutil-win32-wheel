#Requires -Version 7.4
param(
    [Parameter(Mandatory)]
    [string]$Wheel,

    [Parameter(Mandatory)]
    [string]$Python
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

if (-not (Test-Path -LiteralPath $Wheel -PathType Leaf)) {
    throw "Wheel not found at $Wheel"
}
if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
    throw "Python executable not found at $Python"
}

$resolvedWheel = (Resolve-Path -LiteralPath $Wheel).Path
$resolvedPython = (Resolve-Path -LiteralPath $Python).Path
$testScript = Join-Path $PSScriptRoot 'test_psutil_wheel.py'
if (-not (Test-Path -LiteralPath $testScript -PathType Leaf)) {
    throw "Smoke test script not found at $testScript"
}

$smokeDir = Join-Path ([System.IO.Path]::GetTempPath()) "psutil-smoke-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $smokeDir | Out-Null
$env:PSUTIL_WHEEL = $resolvedWheel

& $resolvedPython -m pip install `
    --disable-pip-version-check `
    --no-cache-dir `
    --no-index `
    --no-deps `
    --force-reinstall `
    --only-binary ':all:' `
    $resolvedWheel

Push-Location $smokeDir
try {
    & $resolvedPython $testScript
}
finally {
    Pop-Location
    Remove-Item -LiteralPath $smokeDir -Recurse -Force -ErrorAction SilentlyContinue
}
