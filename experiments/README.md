# Size probes

Measured with the project-local Zig 0.16.0, `-OReleaseSmall -fstrip`, native
`x86_64-windows` unless noted. Each file is a standalone `zig build-exe` probe.

## Zig 0.16 size traps (the reason for src/os.zig and the `main() void` rule)

| Probe | Bytes | What it shows |
| --- | ---: | --- |
| `empty.zig` | 4,608 | The Zig floor: an empty program. |
| `winhello.zig` | 4,608 | Raw `kernel32!WriteFile` with no `std` at all. |
| `errmain.zig` (`main() !void {}`) | 4,608 | A `!void` main is free **if it can never return an error**. |
| `errtry.zig` (`main() !void { try ... }`) | 488,448 | **A fallible `try` in `main` costs ~484 KB.** The runtime keeps the error/trace path, which pulls in `std.debug` + `std.os.windows`. |
| `errtry_opts.zig` (+ `std_options` off) | 488,448 | `std_options` does **not** remove it. |
| `errtry_panic.zig` (+ custom panic) | 486,400 | A custom panic barely helps. |
| `errtry_nested.zig` (`main() void`, `run() !void` with `try`) | 4,608 | **The fix:** keep `main` returning `void` and `catch` at the boundary. `try` inside helpers is free. |
| `dbgprint.zig` (`std.debug.print`) | 483,840 | Debug printing drags in the same machinery. |
| `iothreaded.zig` (`std.Io.Threaded` + `File.stdout`) | 488,960 | The std I/O runtime costs ~480 KB. Use raw OS calls. |

**Rule for mibi:** `pub fn main() void`, call `run() !void` and `catch` at the
boundary; never print via `std.debug` or `std.Io.Threaded`.

## What is actually cheap

| Probe | Bytes | Marginal cost |
| --- | ---: | --- |
| `winfmt.zig` (`std.fmt.bufPrint`) | 48,128 | ~43 KB (Windows); ~4 KB on Linux |
| `unicode2.zig` (`std.unicode`) | 5,120 | ~0.5 KB |
| `pagealloc2.zig` (`std.heap.page_allocator`) | 4,608 | ~0 |
| `arraylist2.zig` (`std.ArrayList`) | 4,608 | ~0 |
| `hashmap2.zig` (`std.StringHashMap`) | 49,664 | ~45 KB |

## mibi binary size by phase, cross-compiled

| Target | Phase 1 (skeleton) | Phase 2 (editing) | Current (Phase 2 hardened + Phase 3 features) |
| --- | ---: | ---: | ---: |
| `x86_64-linux-gnu` | 8,960 | 26,168 | 59,552 |
| `aarch64-linux-gnu` | 8,816 | 24,752 | 53,384 |
| `x86_64-macos` | 16,994 | 33,922 | 66,854 |
| `aarch64-macos` | 50,304 | 69,392 | 90,216 |
| `x86_64-windows-gnu` | 50,176 | 71,680 | 107,520 |
| `x86_64-windows` | 55,808 | 69,632 | 107,520 |

The hardening pass (cached line index, UTF-8 `putStr`, file-safety guards,
richer error reporting) cost ~1.5-2 KB per target. Current numbers are explicit
`-Dtarget=` builds (baseline CPU); a native build with host CPU features is
105,984 bytes on Windows. `tools/check-size.ps1` (`.\build.ps1 size`) rebuilds
all six targets and fails if one exceeds its budget, so a size trap cannot
return unnoticed.

For comparison, kibi's Rust binary is ~437-446 KB uncompressed and ox's is
~5.3 MB. Zig's floor is roughly **1/40th** of Rust's, so the 1 MB ceiling is
now a loose constraint rather than a tight one.

## Unicode width table (`width_table.py`, Unicode 15.1)

A terminal editor must *predict* cell widths, because the terminal owns the
font. (A GUI editor like nib just asks the font for the glyph advance and needs
no table.) The table we need is small:

| Class | Ranges | Codepoints |
| --- | ---: | ---: |
| wide / fullwidth (2 cells) | 120 | 182,521 |
| zero-width (Mn/Me/Cf) | 357 | 2,168 |

Encoding those 477 ranges: **3,816 bytes** as `(u32,u32)`, **~1,908 bytes** as
varint deltas. Emoji (U+1F000-1FAFF) are entirely wide, which is why they
matter. Nerd Font icons live in the Private Use Area and are normally 1 cell.

Rebuild any probe with:

```powershell
$env:ZIG_GLOBAL_CACHE_DIR="$PWD\.zig-cache-global"
.\tools\zig\zig.exe build-exe experiments\<name>.zig -OReleaseSmall -fstrip `
  -fno-unwind-tables -femit-bin=experiments/out/<name>.exe
```
