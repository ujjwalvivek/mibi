param(
    [string]$Target = (Join-Path $env:LOCALAPPDATA 'Programs\Mibi'),
    [switch]$Quiet
)
# Installs (or updates) the built editor into %LOCALAPPDATA%\Programs\Mibi:
# the binary, syntax.d, themes and a launcher that opens it in the mibi
# Windows Terminal profile (so it gets the Maple Mono NF font).
$ErrorActionPreference = 'Stop'

$src = Join-Path $PSScriptRoot '..\zig-out\bin'
$exe = Join-Path $src 'mibi.exe'
if (-not (Test-Path $exe)) { throw "No build found at $exe - run .\build.ps1 first" }

New-Item -ItemType Directory -Force $Target | Out-Null
Copy-Item $exe (Join-Path $Target 'mibi.exe') -Force

foreach ($dir in 'syntax.d', 'themes') {
    $from = Join-Path $src $dir
    if (-not (Test-Path $from)) { continue }
    $to = Join-Path $Target $dir
    Remove-Item $to -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item $from $to -Recurse -Force
}

# Keep the user's config: only seed it the first time.
$ini = Join-Path $Target 'mibi.ini'
if (-not (Test-Path $ini)) {
    Copy-Item (Join-Path $PSScriptRoot '..\mibi.ini.example') $ini -Force
}

# Launcher: run inside the mibi profile so the terminal uses Maple Mono NF.
$launcher = @"
@echo off
where wt.exe >nul 2>nul
if errorlevel 1 (
    "%~dp0mibi.exe" %*
    exit /b %errorlevel%
)
wt.exe -p mibi "%~dp0mibi.exe" %*
"@
Set-Content -Path (Join-Path $Target 'mibi.cmd') -Value $launcher -Encoding ASCII

# Point the Windows Terminal profile at the installed binary.
$fragment = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\mibi\mibi.json'
if (Test-Path $fragment) {
    $json = Get-Content $fragment -Raw
    $slashed = (Join-Path $Target 'mibi.exe') -replace '\\', '/'
    $json = $json -replace '"commandline": "[^"]*"', ('"commandline": "' + $slashed + '"')
    Set-Content -Path $fragment -Value $json -Encoding UTF8
}

# Windows Terminal materialises fragment profiles into settings.json the first
# time they are used; those copies do not pick up later fragment changes, so
# make sure the font and commandline are right there too.
$settingsCandidates = @(
    (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
    (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json')
)
foreach ($settingsPath in $settingsCandidates) {
    if (-not (Test-Path $settingsPath)) { continue }
    $text = Get-Content $settingsPath -Raw
    if ($text -notmatch '"name":\s*"mibi"') { continue }
    $text = [regex]::Replace($text, '("name":\s*"mibi")(\s*\})', ('$1,' + "`n" + '                "font": { "face": "' + $Font + '" }$2'), 'None')
    Set-Content -Path $settingsPath -Value $text -Encoding UTF8
    if (-not $Quiet) { Write-Host "  settings.json: font face set for the mibi profile" }
}

if (-not $Quiet) {
    Write-Host "Installed mibi in $Target"
    Write-Host "  binary:   $(Join-Path $Target 'mibi.exe')"
    Write-Host "  launcher: $(Join-Path $Target 'mibi.cmd')  (opens in the mibi profile)"
    Write-Host "  profile:  commandline updated in $fragment"
    Write-Host "Add $Target to PATH if you want to type 'mibi' anywhere."
}
