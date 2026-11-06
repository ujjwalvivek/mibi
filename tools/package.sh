#!/usr/bin/env bash
# Packages a built mibi for release.
#
#   ./tools/package.sh                        # host target -> dist/mibi-<version>-<target>.tar.gz
#   ./tools/package.sh x86_64-linux-gnu
#   NO_BUILD=1 ./tools/package.sh             # pack what is already in zig-out/bin
#
# The version is read from `pub const version` in src/main.zig, so the archive
# cannot drift from the binary. The staged directory holds mibi[.exe],
# syntax.d/, themes/, LICENSE, README.md and config/mibi.ini.example; the
# archive is dist/mibi-<version>-<target>.tar.gz with that directory at its
# root. Nothing outside dist/ and zig-out/ is written.

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
target=${1:-}

version=$(grep -oE 'pub const version = "[^"]+"' "$root/src/main.zig" | head -n 1 | sed 's/.*"\(.*\)"/\1/')
if [ -z "$version" ]; then
    echo "cannot read the version from src/main.zig" >&2
    exit 1
fi

if [ -z "$target" ]; then
    case "$(uname -s)" in
        Linux) os=linux-gnu ;;
        Darwin) os=macos ;;
        *) echo "unknown host OS; pass a target (e.g. x86_64-linux-gnu)" >&2; exit 1 ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64) arch=x86_64 ;;
        arm64|aarch64) arch=aarch64 ;;
        *) echo "unknown host architecture; pass a target" >&2; exit 1 ;;
    esac
    target="$arch-$os"
fi

case "$target" in
    *windows*) exe=mibi.exe ;;
    *) exe=mibi ;;
esac

if [ "${NO_BUILD:-0}" != "1" ]; then
    if [ -x "$root/tools/zig-linux/zig" ]; then
        zig="$root/tools/zig-linux/zig"
    elif [ -x "$root/tools/zig/zig" ]; then
        zig="$root/tools/zig/zig"
    else
        zig=zig
    fi
    ZIG_GLOBAL_CACHE_DIR="$root/.zig-cache-global" "$zig" build -Dtarget="$target"
fi

bin="$root/zig-out/bin/$exe"
if [ ! -f "$bin" ]; then
    echo "no binary at $bin - build it first (or unset NO_BUILD)" >&2
    exit 1
fi

name="mibi-$version-$target"
stage="$root/dist/$name"
archive="$root/dist/$name.tar.gz"

rm -rf "$stage" "$archive"
mkdir -p "$stage/config"
cp "$bin" "$stage/$exe"
cp -R "$root/syntax.d" "$stage/syntax.d"
cp -R "$root/themes" "$stage/themes"
cp "$root/LICENSE" "$root/README.md" "$stage/"
cp "$root/config/mibi.ini.example" "$stage/config/mibi.ini.example"

# The archive holds the staged directory itself, not just its contents.
tar -czf "$archive" -C "$root/dist" "$name"

files=$(find "$stage" -type f | wc -l | tr -d ' ')
echo "packaged $archive"
echo "  $(du -h "$archive" | cut -f1), $files files, version $version, target $target"
