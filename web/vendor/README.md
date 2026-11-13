# Vendored web dependencies

The web host is the only part of mibi with third-party code. It is kept out of
the Zig build and the native binary; these files are copied here so
`zig-out/web` is self-contained and works offline.

| File | Package | Version | Licence |
| --- | --- | --- | --- |
| `xterm.js`, `xterm.css` | `@xterm/xterm` | 5.5.0 | MIT |
| `addon-fit.js` | `@xterm/addon-fit` | 0.10.0 | MIT |
| `MapleMono-NF-Regular.woff2` | Maple Mono NF (WOFF2 subset) | — | OFL-1.1 |

`LICENSE.xterm` and `LICENSE.addon-fit` are the upstream licences.
`LICENSE.MapleMono-NF.txt` has the font's copyright and the full OFL text. The
subset was made with `fontTools.subset` from `MapleMono-NF-Regular.ttf`; it
covers Latin, punctuation, box drawing and the Nerd Font icon ranges the file
tree uses. The CSS family is "Maple Mono NF". Regenerate it with
`tools/subset-font.ps1`.

To update, run `npm install` in `web/` and copy the files from
`web/node_modules/@xterm/...` again. `web/node_modules` is not committed.
