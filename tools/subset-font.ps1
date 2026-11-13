# Regenerate the Maple Mono NF subset used by the web build.
#
# The source is the full Maple Mono NF Regular TTF (OFL-1.1). It is not
# committed; point the script at your copy:
#
#   .\tools\subset-font.ps1
#   .\tools\subset-font.ps1 -Source C:\path\to\MapleMono-NF-Regular.ttf
#
# Requires Python with fontTools and brotli:
#   python -m pip install fonttools brotli
#
# The output is web/site/vendor/MapleMono-NF-Regular.woff2. The ranges are the
# editor's text plus the Nerd Font icons the file tree uses; see
# web/site/vendor/LICENSE.MapleMono-NF.txt.

param(
    [string]$Source = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts\MapleMono-NF-Regular.ttf"
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$Out = Join-Path $Root 'web\site\vendor\MapleMono-NF-Regular.woff2'

if (-not (Test-Path $Source)) {
    throw "Font not found: $Source. Pass -Source with the MapleMono-NF-Regular.ttf path."
}

$unicodes = @(
    'U+0020-007E', # Basic Latin
    'U+00A0-00FF', # Latin-1
    'U+2000-206F', # punctuation
    'U+2190-21FF', # arrows
    'U+2500-257F', # box drawing
    'U+2580-259F', # block elements
    'U+25A0-25FF', # geometric shapes
    'U+E0A0-E0B3', # powerline
    'U+E600-E7FF', # Nerd Font file icons
    'U+F000-F8FF', # Font Awesome icons
    'U+FE00-FE0F', # variation selectors
    'U+FFFD'
) -join ','

python -m fontTools.subset $Source `
    --output-file=$Out `
    --flavor=woff2 `
    --unicodes=$unicodes `
    --layout-features='*' `
    --no-hinting `
    --desubroutinize

if ($LASTEXITCODE -ne 0) { throw "fontTools.subset failed with exit code $LASTEXITCODE" }
Write-Host "wrote $Out ($((Get-Item $Out).Length) bytes)"
