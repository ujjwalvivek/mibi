# syntax.d

Language definitions for mibi's highlighter, in kibi's `syntax.d` format.

These 52 files are copied verbatim from [kibi](https://github.com/ilai-deutel/kibi)
(dual-licensed MIT OR Apache-2.0); the license texts are in `LICENSES/`. They
are data, not code: mibi parses them at startup, so adding a language means
dropping in a `.ini` file — no rebuild, no code change.

Lookup order: `syntax.d/` next to the executable first, then `./syntax.d` in the
working directory.

## Format

```
name=Rust
extensions=rs
highlight_numbers=true
singleline_string_quotes=", '
singleline_comment_start=//
multiline_comment_delims=/*, */
multiline_string_delim="
keywords_1=fn, let, mut, pub, impl, ...
keywords_2=u8, i32, f64, bool, ...
```

| Key | Meaning |
| --- | --- |
| `name` | Display name (required) |
| `extensions` | Comma-separated file extensions (required) |
| `highlight_numbers` | `true`/`false` (default true) |
| `singleline_string_quotes` | Quote characters that delimit a one-line string |
| `singleline_comment_start` | Comma-separated tokens that start a line comment |
| `multiline_comment_delims` | `open, close` delimiters for block comments |
| `multiline_string_delim` | Delimiter that opens and closes a multi-line string |
| `keywords_1` | Primary keyword list |
| `keywords_2` | Secondary list (types, constants, builtins) |
