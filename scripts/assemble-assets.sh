#!/bin/sh
# Usage: assemble-assets.sh <tag> <native dir> <macOS deps source tar> <out dir> [release|dev]
# Collects the release assets for <tag> into <out dir>: the five native
# archives, the macOS dependency sources, the upstream tarball, this repo plus
# the native toolchain submodule as source, and SHA256SUMS. Run from a full
# checkout of the built commit with the submodule initialized.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
tag=$1 dist=$2 macos_src=$3 out=$4 mode=${5:-release}

vars=$(sh "$root/scripts/release-vars.sh" "$(git -C "$root" rev-parse HEAD)" "$mode")
var() { printf '%s\n' "$vars" | sed -n "s/^$1=//p"; }
version=$(var FFMPEG_VERSION) extra=$(var FFMPEG_EXTRA_VERSION)

mkdir -p "$out"
for t in linux64 linuxarm64 win64 macos64 macosarm64; do
    ext=tar.xz; [ "$t" = win64 ] && ext=zip
    f="$dist/ffmpeg-n$version-$extra-$t-gpl-8.1.$ext"
    [ -f "$f" ] || { echo "::error::missing $f" >&2; ls "$dist" >&2; exit 1; }
    cp "$f" "$out/"
done
set -- "$dist"/*
[ $# -eq 5 ] || { echo "::error::unexpected native artifacts: $*" >&2; exit 1; }
cp "$macos_src" "$out/ersatztv-ffmpeg-$tag-macos-deps-src.tar"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
sh "$root/scripts/check-upstream.sh" "$tmp/upstream" >&2
cp "$tmp/upstream/ffmpeg-$version.tar.bz2" "$out/"

src="ersatztv-ffmpeg-$tag-src"
git -C "$root" archive --prefix="$src/" -o "$tmp/src.tar" HEAD
git -C "$root/native/FFmpeg-Builds" archive --prefix="$src/native/FFmpeg-Builds/" -o "$tmp/fork.tar" HEAD
tar --concatenate -f "$tmp/src.tar" "$tmp/fork.tar"
xz -9 -T0 -c "$tmp/src.tar" > "$out/$src.tar.xz"

(cd "$out" && sha256sum -- * > "$tmp/SHA256SUMS")
mv "$tmp/SHA256SUMS" "$out/"
cat "$out/SHA256SUMS"
