#!/bin/sh
# Usage: fetch-upstream.sh <ffmpeg version> <sha256> <out file>
# Downloads the FFmpeg release tarball from ffmpeg.org, falling back to the
# copy on this repo's upstream-<version> release. Both must match <sha256>.
set -eu

version=$1 sha256=$2 out=$3

for url in \
    "https://ffmpeg.org/releases/ffmpeg-$version.tar.bz2" \
    "https://github.com/ErsatzTV/ErsatzTV-ffmpeg/releases/download/upstream-$version/ffmpeg-$version.tar.bz2"; do
    # plain --retry skips connection resets, which is how ffmpeg.org fails
    if curl -Lfs --show-error --retry 2 --retry-all-errors --connect-timeout 30 -o "$out" "$url" &&
        echo "$sha256  $out" | sha256sum -c - >/dev/null; then
        echo "fetch-upstream: ffmpeg-$version.tar.bz2 from $url" >&2
        exit 0
    fi
    echo "fetch-upstream: $url failed" >&2
    rm -f "$out"
done
exit 1
