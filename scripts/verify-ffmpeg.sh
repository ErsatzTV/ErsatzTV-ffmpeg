#!/bin/sh
# Usage: verify-ffmpeg.sh <bin dir> <upstream version> <extra version>
# Checks a built ffmpeg/ffprobe pair: version banner, GPLv3 (not nonfree)
# license, built-in aac without libfdk_aac, and a short software encode/probe
# with codec long names and profile names.
# Windows builds print CRLF; strip it so this also runs under Git Bash.
set -eu

bindir=$1 version=$2 extra=$3

fail() {
    echo "verify-ffmpeg: $*" >&2
    exit 1
}

for tool in ffmpeg ffprobe; do
    banner=$("$bindir/$tool" -hide_banner -version | head -n 1 | tr -d '\r')
    # tarball builds take the version from VERSION, git builds from the tag
    case "$banner" in
        "$tool version $version-$extra "* | "$tool version n$version-$extra "*) ;;
        *) fail "unexpected $tool banner: $banner" ;;
    esac
done

# the nonfree notice replaces this text entirely
"$bindir/ffmpeg" -hide_banner -L | tr -d '\r' | tr '\n' ' ' |
    grep -q 'GNU General Public License as published by the Free Software Foundation; either version 3' ||
    fail "license is not GPLv3"

"$bindir/ffmpeg" -hide_banner -encoders | tr -d '\r' |
    awk '$2 == "aac" { aac = 1 } $2 == "libfdk_aac" { fdk = 1 } END { exit !(aac && !fdk) }' ||
    fail "expected built-in aac and no libfdk_aac"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# an 8-bit yuv upscale to a multiple of 32 wide takes x86 swscale's runtime-generated
# fast_bilinear scaler, which a hardened runtime without an exec-memory entitlement kills
"$bindir/ffmpeg" -hide_banner -loglevel error -nostdin \
    -f lavfi -i testsrc2=size=320x240:rate=25:duration=1 \
    -f lavfi -i sine=duration=1 \
    -vf format=yuv420p,scale=640:480:flags=fast_bilinear \
    -c:v libx264 -c:a aac "$tmp/out.mkv"
streams=$("$bindir/ffprobe" -v error -show_entries stream=codec_name -of csv=p=0 "$tmp/out.mkv" | tr -d '\r' | tr '\n' ' ')
[ "$streams" = "h264 aac " ] || fail "unexpected streams in test encode: $streams"
# --enable-small blanks codec long names and profile names, which ErsatzTV's probes read
names=$("$bindir/ffprobe" -v error -select_streams v:0 -show_entries stream=codec_long_name,profile -of csv=p=0 "$tmp/out.mkv" | tr -d '\r')
[ "$names" = "H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10,High" ] || fail "missing codec long name or profile: $names"

echo "verify-ffmpeg: ok ($("$bindir/ffmpeg" -hide_banner -version | head -n 1 | tr -d '\r'))"
