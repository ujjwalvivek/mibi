# Regenerate web/assets.txt, the list of syntax and theme files the web host
# fetches into the editor's virtual filesystem. Run it after adding a language
# or a theme:
#
#   .\tools\web-assets.ps1
#
# The web build installs this file next to mibi.wasm; the host reads it at
# startup and fetches each entry.

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$lines = @()

Get-ChildItem (Join-Path $Root 'syntax.d') -Filter *.ini |
    Sort-Object Name |
    ForEach-Object { $lines += "syntax $($_.Name)" }

Get-ChildItem (Join-Path $Root 'themes') -Filter *.ini |
    Sort-Object Name |
    ForEach-Object { $lines += "theme $($_.Name)" }

$out = Join-Path $Root 'web/assets.txt'
Set-Content -Encoding utf8 $out $lines
Write-Host "wrote $out ($($lines.Count) files)"
