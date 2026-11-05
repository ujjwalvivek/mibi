param(
    [string]$Exe,
    [string]$Font = 'Maple Mono NF'
)
# Installs the mibi profile and colour scheme into Windows Terminal.
# Per-user, no admin: fragments live under %LOCALAPPDATA%.
$ErrorActionPreference = 'Stop'

$dest = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\mibi'
New-Item -ItemType Directory -Force $dest | Out-Null

# Find the built binary so the profile works without mibi.exe being on PATH.
if (-not $Exe) {
    $candidates = @(
        (Join-Path $PSScriptRoot '..\..\zig-out\bin\mibi.exe'),
        (Join-Path $PSScriptRoot '..\..\zig-out\bin\mibi')
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $Exe = (Resolve-Path $c).Path; break }
    }
}

$json = Get-Content (Join-Path $PSScriptRoot 'mibi.json') -Raw
if ($Exe) {
    $slashed = $Exe -replace '\\', '/'
    $json = $json -replace '"commandline": "mibi.exe"', ('"commandline": "' + $slashed + '"')
}
if ($Font) {
    $json = $json -replace '"face": "Maple Mono NF"', ('"face": "' + $Font + '"')
}
Set-Content -Path (Join-Path $dest 'mibi.json') -Value $json -Encoding UTF8

$iconCandidates = @(
    (Join-Path $PSScriptRoot '..\icons\png\mibi-128.png'),
    (Join-Path $PSScriptRoot '..\png\mibi-128.png')
)
$icoCandidates = @(
    (Join-Path $PSScriptRoot '..\icons\mibi.ico'),
    (Join-Path $PSScriptRoot '..\mibi.ico')
)
foreach ($c in $iconCandidates) { if (Test-Path $c) { Copy-Item $c $dest -Force; break } }
foreach ($c in $icoCandidates) { if (Test-Path $c) { Copy-Item $c $dest -Force; break } }

Write-Host "Installed the mibi profile in $dest"
if ($Exe) { Write-Host "  commandline: $Exe" } else { Write-Host "  commandline: mibi.exe (put it on PATH or pass -Exe)" }
Write-Host "  font face:   $Font"
Write-Host "Close ALL Windows Terminal windows and open it again; 'mibi' will be in the profile menu."
