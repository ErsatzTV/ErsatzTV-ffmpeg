#!/bin/sh
# Usage: build.sh <macos64|macosarm64> <ErsatzTV-ffmpeg commit> [dev|release]
# Builds ffmpeg from the verified release.json tag with this repo's patch set,
# statically linked against native/macos/work/<target>/prefix (built first by
# build-deps.sh unless a complete one is already there, e.g. from the CI
# cache). The archive lands in native/macos/artifacts/.
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
target=$1 commit=$2 mode=${3:-dev}
. "$root/native/macos/env.sh"

vars=$(sh "$root/scripts/release-vars.sh" "$commit" "$mode")
var() { printf '%s\n' "$vars" | sed -n "s/^$1=//p"; }

[ -f "$prefix/.complete" ] || sh "$root/native/macos/build-deps.sh" "$target"

src="$work/ffmpeg"
rm -rf "$src"
git clone --quiet --depth 1 --branch "$(var FFMPEG_TAG)" https://github.com/FFmpeg/FFmpeg.git "$src"
head=$(git -C "$src" rev-parse HEAD)
[ "$head" = "$(var FFMPEG_COMMIT)" ] || {
    echo "build: $(var FFMPEG_TAG) is $head, release.json expects $(var FFMPEG_COMMIT)" >&2
    exit 1
}
for p in "$root"/patches/*.patch; do
    echo "Applying FFmpeg patch: $p"
    git -C "$src" apply --verbose "$p"
done

# D7: docker arm64's list without libv4l2 and fontconfig (libass uses CoreText).
# Apple frameworks are enabled explicitly so a missed autodetect fails here.
cd "$src"
set --
[ "$cross" = 0 ] || set -- --enable-cross-compile --target-os=darwin
./configure "$@" \
    --cc=clang \
    --arch="$arch" \
    --pkg-config-flags=--static \
    --extra-cflags="$archflags -I$prefix/include" \
    --extra-ldflags="$archflags -L$prefix/lib" \
    --extra-libs=-lc++ \
    --disable-debug \
    --disable-doc \
    --disable-ffplay \
    --disable-sdl2 \
    --disable-xlib \
    --disable-libxcb \
    --enable-ffprobe \
    --enable-gpl \
    --enable-version3 \
    --enable-audiotoolbox \
    --enable-videotoolbox \
    --enable-libaom \
    --enable-libdav1d \
    --enable-libass \
    --enable-libfreetype \
    --enable-libharfbuzz \
    --enable-libkvazaar \
    --enable-libmp3lame \
    --enable-libopencore-amrnb \
    --enable-libopencore-amrwb \
    --enable-libopenjpeg \
    --enable-libopus \
    --enable-libsrt \
    --enable-libtheora \
    --enable-libvidstab \
    --enable-libvorbis \
    --enable-libvpx \
    --enable-libwebp \
    --enable-libxml2 \
    --enable-libx264 \
    --enable-libx265 \
    --enable-libxvid \
    --enable-libzimg \
    --enable-openssl \
    --enable-small \
    --enable-stripping \
    --extra-version="$(var FFMPEG_EXTRA_VERSION)"
make -j"$jobs"

# a dependency that misses its assembler or detects the wrong CPU still builds,
# C-only; the unstripped ffmpeg_g shows which SIMD code was linked
case "$arch" in
    x86_64) simd=avx2 ;;
    arm64) simd=neon ;;
esac
nm -j ffmpeg_g > "$work/symbols.txt"
for lib in x264 x265 dav1d 'vpx|vp8|vp9' 'aom|av1'; do
    count=$(grep -Ec "^_($lib)_.*_$simd\$" "$work/symbols.txt" || true)
    [ "$count" -gt 0 ] || { echo "build: no $simd functions from $lib" >&2; exit 1; }
    echo "build: $lib has $count $simd functions"
done

name="ffmpeg-n$(var FFMPEG_VERSION)-$(var FFMPEG_EXTRA_VERSION)-$target-gpl-8.1"
stage="$work/package"
rm -rf "$stage"
mkdir -p "$stage/$name/bin" "$root/native/macos/artifacts"
cp ffmpeg ffprobe "$stage/$name/bin/"
cp COPYING.GPLv3 "$stage/$name/LICENSE.txt"
# no AppleDouble ._ entries for extended attributes
COPYFILE_DISABLE=1 tar -cJf "$root/native/macos/artifacts/$name.tar.xz" -C "$stage" "$name"
echo "build: native/macos/artifacts/$name.tar.xz"
