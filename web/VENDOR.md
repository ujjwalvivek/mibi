# Vendored web dependencies

The page is the only part of mibi with third-party code, and the Zig build
has none: these files are served next to `mibi.wasm` and never linked into
it. They are committed under `web/site/vendor/` so `zig build web` needs no
network and the site works offline.

| File | Package | Version | Licence | SHA-256 |
| --- | --- | --- | --- | --- |
| `xterm.js` | `@xterm/xterm` | 5.5.0 | MIT (`LICENSE.xterm`) | `1f991ac3b4b283ebf96e60ae23a00a52765dd3a2e46fa6fdda9f1aab032f7495` |
| `xterm.css` | `@xterm/xterm` | 5.5.0 | MIT (`LICENSE.xterm`) | `ba8e6985669488981ccf40c0cefe3aba80722cb6c92de7ad628b0bd717faf2b6` |
| `addon-fit.js` | `@xterm/addon-fit` | 0.10.0 | MIT (`LICENSE.addon-fit`) | `bdaefa370b1bfc42ee88d46fe6072400902a4d4b2d45cd93438dda9b23c97089` |
| `MapleMono-NF-Regular.woff2` | Maple Mono NFo, subset | — | OFL-1.1 (`LICENSE.MapleMono-NF.txt`) | `06f79352cddb6846871ca1cbb0d3e594dc703037c84c9bcb6e5bac11da8e1798` |
| `MapleMono-NF-Bold.woff2` | Maple Mono NFo Bold, subset | — | OFL-1.1 (`LICENSE.MapleMono-NF.txt`) | `c75c272664f6a3932c699aba1898a2a41e17a8af36e4dbdf448d8babd224d65a` |

The xterm files are byte for byte the files the npm packages ship at those
versions. The licence files are the upstream ones; each is served with
the site and linked from the page's `?` panel, as MIT and the OFL require.

The fonts are WOFF2 subsets of `MapleMono-NFo-Regular.ttf` and
`MapleMono-NFo-Bold.ttf` (the NFMono/NFo variant, whose Nerd Font icons are
one cell wide; the plain NF variant's icons are wider than a cell and clip in
xterm.js). Both carry Latin, punctuation, arrows, box drawing, block elements,
geometric shapes and the icon ranges the file tree uses, because the tree bolds
the selected row and its icon must render too. They are made with
`fontTools.subset`.

The OFL allows subsetting; Maple Mono declares no Reserved
Font Name, so the subset keeps the family name "Maple Mono NF".

To update xterm.js, change the versions in `web/package.json`, run
`npm install` in `web/`, copy `node_modules/@xterm/xterm/lib/xterm.js`,
`node_modules/@xterm/xterm/css/xterm.css` and
`node_modules/@xterm/addon-fit/lib/addon-fit.js` into `web/site/vendor/`,
and update this table. `web/node_modules` is not committed.
