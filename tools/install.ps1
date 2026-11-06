param(
    [string]$Target = (Join-Path $env:LOCALAPPDATA 'Programs\Mibi'),
    [string]$Font = 'Maple Mono NF',
    [switch]$Quiet
)
# Installs (or updates) the built editor into %LOCALAPPDATA%\Programs\Mibi:
# binary, syntax.d, themes, a launcher, and the Windows Terminal profile.
$ErrorActionPreference = 'Stop'

$Root = Join-Path $PSScriptRoot '..'
$src = Join-Path $Root 'zig-out\bin'
$exe = Join-Path $src 'mibi.exe'
if (-not (Test-Path $exe)) { throw "No build found at $exe - run .\build.ps1 first" }

New-Item -ItemType Directory -Force $Target | Out-Null
try {
    Copy-Item $exe (Join-Path $Target 'mibi.exe') -Force
} catch {
    # The installed copy is running: update everything else and tell the user.
    if (-not $Quiet) { Write-Host "note: mibi is running, so the binary was not replaced. Close it and run this again." -ForegroundColor Yellow }
}

foreach ($dir in 'syntax.d', 'themes') {
    $from = Join-Path $src $dir
    if (-not (Test-Path $from)) { continue }
    $to = Join-Path $Target $dir
    # Replace the contents, not the directory: `Copy-Item $from $to -Recurse`
    # with an existing $to nests a second copy inside it (syntax.d\syntax.d).
    Remove-Item $to -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $to | Out-Null
    Copy-Item (Join-Path $from '*') $to -Recurse -Force
}

# Keep the user's config: only seed it the first time.
$ini = Join-Path $Target 'mibi.ini'
if (-not (Test-Path $ini)) {
    Copy-Item (Join-Path $Root 'config\mibi.ini.example') $ini -Force
}

# Launcher: run inside the mibi profile so the terminal uses the Nerd Font.
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

# The licence ships with the binary.
$licence = @(
    (Join-Path $src '..\share\mibi\LICENSE'),
    (Join-Path $Root 'LICENSE')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($licence) { Copy-Item $licence (Join-Path $Target 'LICENSE') -Force }

# The vector icon is handy for shortcuts and docs; nothing else is copied.
$svg = @(
    (Join-Path $src '..\share\mibi\icons\mibi.svg'),
    (Join-Path $Root 'assets\mibi.svg')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($svg) { Copy-Item $svg (Join-Path $Target 'mibi.svg') -Force }

# Windows Terminal profile: fill in this machine's paths from the packaged
# template (zig-out\share\mibi\windows-terminal) or the repo's assets.
$fragSrc = @(
    (Join-Path $src '..\share\mibi\windows-terminal\mibi.json'),
    (Join-Path $Root 'assets\windows-terminal\mibi.json')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
$fragDest = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\mibi'
if ($fragSrc) {
    New-Item -ItemType Directory -Force $fragDest | Out-Null
    $json = Get-Content $fragSrc -Raw
    $slashed = (Join-Path $Target 'mibi.exe') -replace '\\', '/'
    $json = $json -replace '"commandline": "[^"]*"', ('"commandline": "' + $slashed + '"')
    $json = $json -replace '"face": "[^"]*"', ('"face": "' + $Font + '"')
    Set-Content -Path (Join-Path $fragDest 'mibi.json') -Value $json -Encoding UTF8
    foreach ($icon in @(
        (Join-Path $src '..\share\mibi\icons\png\mibi-128.png'),
        (Join-Path $Root 'assets\png\mibi-128.png')
    )) {
        if (Test-Path $icon) { Copy-Item $icon $fragDest -Force; break }
    }
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
    Write-Host "  profile:  $fragDest\mibi.json"
    Write-Host "Add $Target to PATH if you want to type 'mibi' anywhere."
}
