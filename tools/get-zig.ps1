# Installs the pinned Zig (0.16.0, x86_64 Windows) into tools\zig\ inside this
# project. Nothing is installed globally and PATH is not touched.
#
# Source: the official "ziglang" package on PyPI (published by the Zig project,
# https://codeberg.org/ziglang/zig-pypi). A .whl file is a plain zip archive.
# The SHA-256 below is the one PyPI publishes for this exact file; the script
# refuses to unpack anything that does not match it.
#
# Same approach as nib/tools/get-zig.ps1: the toolchain lives in the repo.

$ErrorActionPreference = 'Stop'
$Version = '0.16.0'
$Url = 'https://files.pythonhosted.org/packages/a6/3c/baff40b3fc8ab4e83530246a52e8f3a5186c3606562712dfb58483b04f79/ziglang-0.16.0-py3-none-win_amd64.whl'
$Sha256 = '089a16a4eb5a2f45151993342f8fabad24ff1a0723dc146642895c29208a3939'

$Root = Split-Path -Parent $PSScriptRoot
$Tools = Join-Path $Root 'tools'
$Dest = Join-Path $Tools 'zig'
$Download = Join-Path $Tools "ziglang-$Version-win_amd64.zip"
$Staging = Join-Path $Tools 'zig-staging'

if (Test-Path (Join-Path $Dest 'zig.exe')) {
    $have = & (Join-Path $Dest 'zig.exe') version
    if ($have -eq $Version) { Write-Host "Zig $Version is already in tools\zig."; exit 0 }
    Write-Host "tools\zig holds Zig $have; replacing it with $Version."
    Remove-Item -Recurse -Force $Dest
}

Write-Host "Downloading Zig $Version (about 95 MB)..."
$ProgressPreference = 'SilentlyContinue'   # the progress bar makes downloads very slow
Invoke-WebRequest -Uri $Url -OutFile $Download -UseBasicParsing

$actual = (Get-FileHash -Algorithm SHA256 $Download).Hash.ToLower()
if ($actual -ne $Sha256) {
    Remove-Item -Force $Download
    throw "SHA-256 mismatch: expected $Sha256, got $actual. Nothing was installed."
}
Write-Host "SHA-256 verified."

if (Test-Path $Staging) { Remove-Item -Recurse -Force $Staging }
Expand-Archive -Path $Download -DestinationPath $Staging
# The archive holds ziglang\zig.exe next to ziglang\lib\ (zig.exe needs lib\ beside it).
Move-Item (Join-Path $Staging 'ziglang') $Dest
Remove-Item -Recurse -Force $Staging
Remove-Item -Force $Download

$have = & (Join-Path $Dest 'zig.exe') version
Write-Host "Installed Zig $have in tools\zig."
