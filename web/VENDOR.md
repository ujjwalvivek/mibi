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
| `MapleMono-NF-Regular.woff2` | Maple Mono NF, subset | — | OFL-1.1 (`LICENSE.MapleMono-NF.txt`) | `8fd6008b87e4a5a59b28b3f8bd4680e686bf15aed355b58d4a9bc65eb8839df2` |
| `MapleMono-NF-Bold.woff2` | Maple Mono NF Bold, subset | — | OFL-1.1 (`LICENSE.MapleMono-NF.txt`) | `5a98ba0df41ade99de6cd50ae15f931a81f1de86af4d402c28dff8e75a645fa5` |

The xterm files are byte for byte the files the npm packages ship at those
versions. The licence files are the upstream ones; each is served with
the site and linked from the page's `?` panel, as MIT and the OFL require.

The font is a WOFF2 subset of `MapleMono-NF-Regular.ttf` made with
`fontTools.subset` (`tools/subset-font.ps1`): Latin, punctuation, arrows, box
drawing, block elements, geometric shapes and the Nerd Font icon ranges the
file tree uses. The bold face only sets the page's title and dialog
headings, so its subset is Latin, Latin-1 and punctuation (36 KB):

    python -m fontTools.subset MapleMono-NF-Bold.ttf --flavor=woff2 \
      --unicodes=U+0020-007E,U+00A0-00FF,U+2010-2027,U+2190-2193,U+2039-203A \
      --output-file=web/site/vendor/MapleMono-NF-Bold.woff2

The OFL allows subsetting; Maple Mono declares no Reserved
Font Name, so the subset keeps the family name "Maple Mono NF".

To update xterm.js, change the versions in `web/package.json`, run
`npm install` in `web/`, copy `node_modules/@xterm/xterm/lib/xterm.js`,
`node_modules/@xterm/xterm/css/xterm.css` and
`node_modules/@xterm/addon-fit/lib/addon-fit.js` into `web/site/vendor/`,
and update this table. `web/node_modules` is not committed.
