# Installs the bundled Nerd Font for the current user and points the mibi
# Windows Terminal profile at it. No admin: per-user fonts live under
# %LOCALAPPDATA%.
$ErrorActionPreference = 'Stop'

$fontDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
$regPath = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
$source = Join-Path $PSScriptRoot '..\fonts'
New-Item -ItemType Directory -Force $fontDir | Out-Null
New-Item -Path $regPath -Force | Out-Null

$fonts = Get-ChildItem $source -Filter *.ttf -ErrorAction SilentlyContinue
if (-not $fonts) {
    Write-Host "No .ttf files in $source"
    Write-Host "Download Maple Mono NF and drop the .ttf files there, then run this again:"
    Write-Host "  https://github.com/subframe7536/maple-font/releases"
    exit 1
}
foreach ($f in $fonts) {
    Copy-Item $f.FullName $fontDir -Force
    $name = "$($f.BaseName) (TrueType)"
    New-ItemProperty -Path $regPath -Name $name -Value (Join-Path $fontDir $f.Name) -PropertyType String -Force | Out-Null
    Write-Host "installed $($f.Name)"
}
Write-Host "Fonts installed. Pick 'Maple Mono NF' in Windows Terminal, or run"
Write-Host "assets\windows-terminal\install.ps1 to get the mibi profile with it."
