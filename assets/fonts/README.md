# Fonts

mibi is a terminal application: the terminal renders the glyphs, so mibi cannot
embed a font. What it can do is ship one and point your terminal at it.

The file tree uses Nerd Font glyphs (folders, per-language file icons). Install
[Maple Mono NF](https://github.com/subframe7536/maple-font) and set it as your
terminal font:

```powershell
# 1. download the Maple Mono NF .ttf files into assets/fonts/
# 2. install them for the current user (no admin)
.\tools\install-font.ps1
# 3. install the mibi Windows Terminal profile, which sets
#    "font": { "face": "Maple Mono NF" } for the mibi profile only
.\assets\windows-terminal\install.ps1
```

On Linux/macOS, drop the TTFs in `~/.local/share/fonts` (or `~/Library/Fonts`)
and set the font in your terminal's config.

Without a Nerd Font, set `icons = ascii` in `mibi.ini` to get letter markers
instead of missing-glyph boxes.
