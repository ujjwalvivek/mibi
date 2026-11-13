#!/usr/bin/env bash
# mibi size gate for Unix hosts and CI: the twin of tools/check-size.ps1.
#
# Cross-compiles every release target and fails when an artifact is over its
# budget or the 1 MB hard ceiling. The budgets are the same numbers as in
# check-size.ps1; change them in both files together.
#
#   tools/check-size.sh                 # uses tools/zig-linux/zig, or zig on PATH
#   ZIG="python3 -m ziglang" tools/check-size.sh

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

if [ -z "${ZIG:-}" ]; then
    if [ -x tools/zig-linux/zig ]; then ZIG=tools/zig-linux/zig; else ZIG=zig; fi
fi

KB=1024
ceiling=$((1024 * KB))
# target:budget in KB (see check-size.ps1 for how they were measured)
targets="
x86_64-linux-gnu:208
aarch64-linux-gnu:184
x86_64-macos:220
aarch64-macos:232
x86_64-windows-gnu:264
"
# The browser build (zig build web), in KB; see check-size.ps1.
wasm_budget=208

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
failed=0
printf '%-20s %9s %9s  %s\n' Target Bytes Budget Status
for entry in $targets; do
    t=${entry%%:*}
    budget=$(( ${entry##*:} * KB ))
    # A fresh prefix per target, so a stale artifact is never measured.
    if ! log=$($ZIG build "-Dtarget=$t" -p "$out/$t" 2>&1); then
        echo "BUILD FAILED: $t"
        echo "$log" | tail -8 | sed 's/^/  /'
        failed=1
        continue
    fi
    exe="$out/$t/bin/mibi"
    [ -f "$exe" ] || exe="$exe.exe"
    size=$(wc -c < "$exe" | tr -d ' ')
    status=ok
    if [ "$size" -gt "$budget" ] || [ "$size" -gt "$ceiling" ]; then
        status=OVER
        failed=1
    fi
    printf '%-20s %9s %9s  %s\n' "$t" "$size" "$budget" "$status"
done

budget=$((wasm_budget * KB))
if ! log=$($ZIG build web -p "$out/wasm32" 2>&1); then
    echo "BUILD FAILED: wasm32"
    echo "$log" | tail -8 | sed 's/^/  /'
    failed=1
else
    size=$(wc -c < "$out/wasm32/web/mibi.wasm" | tr -d ' ')
    status=ok
    if [ "$size" -gt "$budget" ] || [ "$size" -gt "$ceiling" ]; then
        status=OVER
        failed=1
    fi
    printf '%-20s %9s %9s  %s\n' wasm32 "$size" "$budget" "$status"
fi

if [ "$failed" -ne 0 ]; then
    echo "size gate: FAILED"
    exit 1
fi
echo "size gate: ok - every artifact is under its budget (hard ceiling $((ceiling / KB)) KB)"
