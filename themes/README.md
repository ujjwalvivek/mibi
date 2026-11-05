# themes

Colour themes for mibi, one `.ini` per theme (same `[theme]` keys as
`mibi.ini`). Data files, not code: adding a theme costs nothing in binary size.

Select one in `mibi.ini`:

```ini
[editor]
theme = catppuccin-mocha
```

Keys in `mibi.ini`'s own `[theme]` section override the named theme, so you can
start from a shipped palette and tweak a colour or two.

Lookup order: `./themes` in the working directory first, then `themes/` next to
the executable. Colours are `#rrggbb` or `#rgb`; unknown keys are ignored and
missing keys keep the built-in default.

## Included

- `ayu-dark`
- `catppuccin-frappe`
- `catppuccin-latte`
- `catppuccin-macchiato`
- `catppuccin-mocha`
- `dracula`
- `everforest`
- `flexoki-dark`
- `github-dark`
- `github-light`
- `gruvbox-dark`
- `horizon`
- `kanagawa`
- `material-palenight`
- `monokai`
- `nightfox`
- `nord`
- `one-dark`
- `oxocarbon`
- `rose-pine`
- `rose-pine-dawn`
- `rose-pine-moon`
- `solarized-dark`
- `tokyonight`
- `tokyonight-storm`
- `vs-dark`
- `vs-light`

The palettes are the well-known ones from the corresponding editors and colour
schemes (VS Code, Dracula, Nord, Gruvbox, One Dark, Monokai, Solarized,
Catppuccin, Rose Pine, Horizon, Tokyo Night, Kanagawa, Everforest, GitHub, Ayu,
Material Palenight, Nightfox, Oxocarbon, Flexoki).
