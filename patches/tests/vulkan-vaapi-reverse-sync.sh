#!/usr/bin/env bash
#
# Reproducer for
#   0019-avutil-vulkan-vaapi-reverse-sync.patch
#
# A reverse hwmap (hwmap=derive_device=vaapi:reverse=1) gives the Vulkan
# filters in front of it frames that are mappings of VAAPI surfaces. The unmap
# in av_hwframe_map() hands the original VAAPI surface to the next filter
# without waiting for the Vulkan work that wrote it, so the encoder can read a
# half-written surface. Nothing errors; the output shows displaced fragments on
# motion and cuts.
#
# Builds a synthetic H.264 source with hard cuts (h264_vaapi), then runs
#
#   VAAPI decode -> hwmap drm -> libplacebo (upscale, rgba) ->
#   scale_vulkan (nv12) -> reverse hwmap to VAAPI -> pad_vaapi -> h264_vaapi
#
# and compares every decoded frame (framemd5) with the same graph using
# hwdownload/hwupload as the handoff instead of the reverse hwmap. The
# reference is run twice to show it is deterministic.
#
#   unpatched: most frames differ from the reference, varying run to run
#   patched:   every run matches the reference exactly
#
# libplacebo has to take DRM_PRIME input and render rgba here: it cannot import
# a Vulkan frame mapped straight from VAAPI, and it cannot render into the
# reverse-mapped nv12 surfaces, so scale_vulkan writes them.
#
# Usage: vulkan-vaapi-reverse-sync.sh [/path/to/ffmpeg]
#        FFMPEG=/path/to/ffmpeg vulkan-vaapi-reverse-sync.sh
#        RUNS=5 DRM_DEVICE=/dev/dri/renderD129 vulkan-vaapi-reverse-sync.sh
#
# Exit: 0 every run matches, 1 any run differs, 2 reference not deterministic,
#       77 VAAPI, Vulkan or libplacebo unavailable.

set -uo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"
RUNS="${RUNS:-3}"
DRM_DEVICE="${DRM_DEVICE:-/dev/dri/renderD128}"

logdir="$(mktemp -d)"
trap 'rm -rf "$logdir"' EXIT

if ! "$FFMPEG" -version >/dev/null 2>&1; then
    echo "ERROR: cannot run ffmpeg: $FFMPEG" >&2
    exit 2
fi

echo "ffmpeg:   $FFMPEG"
echo "device:   $DRM_DEVICE"

# 12 s at 30 fps, a hard cut every 2 s
src="$logdir/src.mp4"
if ! "$FFMPEG" -nostdin -hide_banner -loglevel error -y \
    -init_hw_device vaapi=va:"$DRM_DEVICE" -filter_hw_device va \
    -f lavfi -i "testsrc2=s=480x360:r=30:d=2" \
    -f lavfi -i "mandelbrot=s=480x360:r=30,trim=duration=2" \
    -f lavfi -i "life=s=480x360:r=30:mold=10:ratio=0.1,trim=duration=2" \
    -f lavfi -i "rgbtestsrc=s=480x360:r=30:d=2,rotate=a=t" \
    -f lavfi -i "cellauto=s=480x360:r=30,trim=duration=2" \
    -f lavfi -i "testsrc=s=480x360:r=30:d=2,hue=h=t*90" \
    -filter_complex "[0][1][2][3][4][5]concat=n=6:v=1,format=nv12,hwupload" \
    -c:v h264_vaapi -qp 20 "$src" >"$logdir/src.log" 2>&1; then
    echo "SKIP: h264_vaapi encode failed on $DRM_DEVICE" >&2
    tail -5 "$logdir/src.log" >&2
    exit 77
fi

run() { # <handoff filters> <out>
    "$FFMPEG" -nostdin -hide_banner -loglevel error -y \
        -init_hw_device drm=dr:"$DRM_DEVICE" \
        -init_hw_device vaapi=va@dr -init_hw_device vulkan=vk@dr \
        -filter_hw_device vk -hwaccel vaapi -hwaccel_device va \
        -hwaccel_output_format vaapi -extra_hw_frames 16 -i "$src" \
        -vf "hwmap=derive_device=drm,format=drm_prime,libplacebo=w=1440:h=1080:format=rgba:colorspace=bt709,scale_vulkan=format=nv12,$1,format=vaapi,pad_vaapi=w=1920:h=1080:x=-1:y=-1" \
        -c:v h264_vaapi -qp 18 "$2" >"$2.log" 2>&1 &&
        "$FFMPEG" -nostdin -loglevel error -i "$2" -map 0:v:0 -f framemd5 "$2.md5" 2>>"$2.log" &&
        grep -v '^#' "$2.md5" | awk -F, '{ print $NF }' >"$2.hashes"
}

reverse='hwmap=derive_device=vaapi:reverse=1'
copy='hwdownload,format=nv12,hwupload=derive_device=vaapi'

if ! run "$copy" "$logdir/ref.mp4"; then
    echo "SKIP: Vulkan/libplacebo pipeline failed on $DRM_DEVICE" >&2
    tail -5 "$logdir/ref.mp4.log" >&2
    exit 77
fi
total=$(wc -l <"$logdir/ref.mp4.hashes")

if ! run "$copy" "$logdir/ref2.mp4" || ! cmp -s "$logdir/ref.mp4.hashes" "$logdir/ref2.mp4.hashes"; then
    echo "ERROR: hwdownload/hwupload reference is not deterministic; cannot judge" >&2
    exit 2
fi
echo "reference: $total frames, deterministic"

fail=0
for i in $(seq "$RUNS"); do
    out="$logdir/run$i.mp4"
    if ! run "$reverse" "$out"; then
        echo "FAIL: run $i: pipeline failed"
        sed 's/^/      /' "$out.log"
        fail=1
        continue
    fi
    same=$(paste -d' ' "$logdir/ref.mp4.hashes" "$out.hashes" | awk '$1 == $2' | wc -l)
    if [ "$same" -eq "$total" ] && [ "$(wc -l <"$out.hashes")" -eq "$total" ]; then
        echo "PASS: run $i: $same/$total frames match"
    else
        echo "FAIL: run $i: $same/$total frames match"
        fail=1
    fi
done

exit $fail
