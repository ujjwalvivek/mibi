# Packages a built mibi for release.
#
#   .\tools\package.ps1                        # host target -> dist\mibi-<version>-<target>.zip
#   .\tools\package.ps1 -Target x86_64-linux-gnu
#   .\tools\package.ps1 -NoBuild               # pack what is already in zig-out\bin
#
# The version is read from `pub const version` in src/main.zig, so the archive
# cannot drift from the binary. The staged directory holds mibi[.exe],
# syntax.d/, themes/, LICENSE, README.md and config/mibi.ini.example; the
# archive is dist/mibi-<version>-<target>.zip with that directory at its root.
# Nothing outside dist\ and zig-out\ is written.

[CmdletBinding()]
param(
    [string]$Target = '',
    [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

$main = Get-Content (Join-Path $Root 'src\main.zig') -Raw
if ($main -notmatch 'pub const version = "([^"]+)"') {
    throw 'cannot read `pub const version` from src/main.zig'
}
$Version = $Matches[1]

# The target names match the ones tools/check-size.ps1 builds.
if (-not $Target) {
    $arch = switch ($env:PROCESSOR_ARCHITECTURE) {
        'ARM64' { 'aarch64' }
        'AMD64' { 'x86_64' }
        default { 'x86_64' }
    }
    if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        $Target = "$arch-windows"
    } elseif ($IsMacOS) {
        $Target = "$arch-macos"
    } elseif ($IsLinux) {
        $Target = "$arch-linux-gnu"
    } else {
        throw 'cannot detect the host target; pass -Target'
    }
}

$exe = if ($Target -like '*windows*') { 'mibi.exe' } else { 'mibi' }
$bin = Join-Path $Root "zig-out\bin\$exe"

if (-not $NoBuild) {
    & (Join-Path $Root 'build.ps1') "-Dtarget=$Target"
    if ($LASTEXITCODE -ne 0) { throw "build failed for $Target" }
}
if (-not (Test-Path $bin)) {
    throw "no binary at $bin - build it first (or drop -NoBuild)"
}

$name = "mibi-$Version-$Target"
$dist = Join-Path $Root 'dist'
$stage = Join-Path $dist $name
$zip = Join-Path $dist "$name.zip"

if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force (Join-Path $stage 'config') | Out-Null

Copy-Item $bin (Join-Path $stage $exe)
Copy-Item (Join-Path $Root 'syntax.d') (Join-Path $stage 'syntax.d') -Recurse
Copy-Item (Join-Path $Root 'themes') (Join-Path $stage 'themes') -Recurse
Copy-Item (Join-Path $Root 'LICENSE'), (Join-Path $Root 'README.md') $stage
Copy-Item (Join-Path $Root 'config\mibi.ini.example') (Join-Path $stage 'config\mibi.ini.example')

if (Test-Path $zip) { Remove-Item -Force $zip }
# The archive holds the staged directory itself, not just its contents.
Compress-Archive -Path $stage -DestinationPath $zip -CompressionLevel Optimal

$files = (Get-ChildItem -Recurse -File $stage).Count
Write-Host "packaged $zip"
Write-Host ("  {0:N0} bytes, {1} files, version {2}, target {3}" -f `
    (Get-Item $zip).Length, $files, $Version, $Target)
