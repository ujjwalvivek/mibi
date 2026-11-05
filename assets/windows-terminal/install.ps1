# Installs the mibi profile and colour scheme into Windows Terminal.
# Per-user, no admin: fragments live under %LOCALAPPDATA%.
$ErrorActionPreference = 'Stop'

$dest = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\mibi'
New-Item -ItemType Directory -Force $dest | Out-Null

# Works from the repo (assets/windows-terminal) and from an install tree
# (share/mibi/windows-terminal next to share/mibi/icons).
$iconCandidates = @(
    (Join-Path $PSScriptRoot '..\icons\png\mibi-128.png'),
    (Join-Path $PSScriptRoot '..\png\mibi-128.png')
)
$icoCandidates = @(
    (Join-Path $PSScriptRoot '..\icons\mibi.ico'),
    (Join-Path $PSScriptRoot '..\mibi.ico')
)

Copy-Item (Join-Path $PSScriptRoot 'mibi.json') $dest -Force
foreach ($c in $iconCandidates) {
    if (Test-Path $c) { Copy-Item $c $dest -Force; break }
}
foreach ($c in $icoCandidates) {
    if (Test-Path $c) { Copy-Item $c $dest -Force; break }
}

Write-Host "Installed the mibi profile in $dest"
Write-Host "Restart Windows Terminal; 'mibi' will be in the profile menu."
Write-Host "If mibi.exe is not on PATH, edit 'commandline' in $dest\mibi.json."
