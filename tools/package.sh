#!/usr/bin/env bash
# Builds the release archives: one per target, each a folder with the binary,
# syntax.d, themes, the example config, the README and the licence.
#
#   tools/package.sh                    # -> dist/mibi-<version>-<target>.tar.gz / .zip
#   ZIG="python3 -m ziglang" tools/package.sh
#
# The version is the one the binary reports (`version` in src/app.zig). Every
# target is cross-compiled from this machine, so one runner makes them all.
# dist/SHA256SUMS lists the archives.

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

if [ -z "${ZIG:-}" ]; then
    if [ -x tools/zig-linux/zig ]; then ZIG=tools/zig-linux/zig; else ZIG=zig; fi
fi

version=$(sed -n 's/^pub const version = "\(.*\)";$/\1/p' src/app.zig)
if [ -z "$version" ]; then
    echo "package: could not read the version from src/app.zig" >&2
    exit 1
fi

# target:name-in-the-archive
targets="
x86_64-linux-gnu:x86_64-linux
aarch64-linux-gnu:aarch64-linux
x86_64-macos:x86_64-macos
aarch64-macos:aarch64-macos
x86_64-windows-gnu:x86_64-windows
"

dist="$root/dist"
rm -rf "$dist"
mkdir -p "$dist"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for entry in $targets; do
    t=${entry%%:*}
    name="mibi-$version-${entry##*:}"
    # A fresh prefix per target, so nothing stale is ever packaged.
    $ZIG build "-Dtarget=$t" -p "$work/$t"
    stage="$work/stage/$name"
    mkdir -p "$stage"
    cp -R "$work/$t/bin/." "$stage/"
    cp LICENSE README.md "$stage/"
    cp config/mibi.ini.example "$stage/mibi.ini.example"
    case "$t" in
    *windows*)
        cp -R assets/windows-terminal "$stage/windows-terminal"
        (cd "$work/stage" && zip -q -r "$dist/$name.zip" "$name")
        ;;
    *)
        chmod 755 "$stage/mibi"
        # Fixed owner and order, so the same sources give the same archive
        # layout on any machine.
        tar -C "$work/stage" --owner=0 --group=0 --numeric-owner --sort=name -czf "$dist/$name.tar.gz" "$name"
        ;;
    esac
done

(cd "$dist" && sha256sum mibi-* > SHA256SUMS)
echo "packaged mibi $version:"
(cd "$dist" && ls -l | sed 1d | awk '{printf "  %9s  %s\n", $5, $9}')
