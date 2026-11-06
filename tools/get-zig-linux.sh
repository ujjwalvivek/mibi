#!/usr/bin/env bash
# Installs the pinned Zig (0.16.0, x86_64 Linux) into tools/zig-linux/ inside
# this project. Nothing is installed globally and PATH is not touched. This is
# the Linux twin of tools/get-zig.ps1.
#
# Source: the official release tarball from https://ziglang.org/download/.
# The SHA-256 is the one index.json publishes for this exact file; the script
# refuses to unpack anything that does not match it.

set -euo pipefail

VERSION=0.16.0
URL="https://ziglang.org/download/$VERSION/zig-x86_64-linux-$VERSION.tar.xz"
SHA256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00

root=$(cd "$(dirname "$0")/.." && pwd)
dest="$root/tools/zig-linux"
dl="$root/tools/dl"
download="$dl/zig-$VERSION-x86_64-linux.tar.xz"
staging="$dl/zig-linux-staging"

if [ -x "$dest/zig" ] && [ "$("$dest/zig" version)" = "$VERSION" ]; then
    echo "Zig $VERSION is already in tools/zig-linux."
    exit 0
fi

mkdir -p "$dl"
echo "Downloading Zig $VERSION for x86_64 Linux (about 53 MB)..."
curl --fail --location --silent --show-error "$URL" --output "$download"

actual=$(sha256sum "$download" | cut -d' ' -f1)
if [ "$actual" != "$SHA256" ]; then
    rm -f "$download"
    echo "SHA-256 mismatch: expected $SHA256, got $actual. Nothing was installed." >&2
    exit 1
fi
echo "SHA-256 verified."

rm -rf "$staging" "$dest"
mkdir -p "$staging"
tar -xJf "$download" --strip-components=1 -C "$staging"
mv "$staging" "$dest"
rm -f "$download"

echo "Installed Zig $("$dest/zig" version) in tools/zig-linux."
