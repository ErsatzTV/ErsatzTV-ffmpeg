#!/usr/bin/env bash
#
# Reproducer for
#   0027-avcodec-amfenc_hevc-put-the-vps-first-in-extradata.patch
#
# Some AMF runtimes return hevc_amf's extradata as SPS, PPS, VPS. cbs_h265
# reads the units in order and fails on the SPS ("VPS id 0 not available"),
# so -bsf:v hevc_metadata cannot initialise on hevc_amf output.
#
# Cases:
#   order_8bit    8-bit hevc_amf extradata starts with a VPS and has a VPS, an
#                 SPS and a PPS.
#   order_10bit   The same for 10-bit (P010) input. Skipped when the runtime
#                 refuses 10-bit encode.
#   metadata      hevc_amf with -bsf:v hevc_metadata into Matroska: ffmpeg
#                 succeeds, the output says bt709 primaries (the bsf ran), and
#                 software decodes every frame.
#
# A runtime that already returns VPS first passes every case with and without
# the patch; the patch must leave its extradata unchanged.
#
# Usage: amfenc-hevc-extradata-order.sh [/path/to/ffmpeg]
#        FFMPEG=/path/to/ffmpeg amfenc-hevc-extradata-order.sh
#        INIT_HW_DEVICE="-init_hw_device d3d11va=dx:1 -init_hw_device amf=hw@dx" amfenc-hevc-extradata-order.sh
#
# ffprobe is taken from next to ffmpeg, or set FFPROBE.
#
# Exit: 0 all runnable cases passed, 1 any case failed, 77 nothing was runnable.

set -uo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"
FFPROBE="${FFPROBE:-$(dirname "$FFMPEG")/ffprobe}"
CASES="${CASES:-order_8bit order_10bit metadata}"
INIT_HW_DEVICE="${INIT_HW_DEVICE:--init_hw_device amf=hw}"
TIMEOUT="${TIMEOUT:-60}"

FRAMES=30

if ! "$FFMPEG" -hide_banner -version >/dev/null 2>&1; then
    echo "ffmpeg not runnable: $FFMPEG" >&2
    exit 2
fi
if ! "$FFPROBE" -hide_banner -version >/dev/null 2>&1; then
    echo "ffprobe not runnable: $FFPROBE" >&2
    exit 2
fi
if ! "$FFMPEG" -hide_banner -encoders 2>/dev/null | grep -E '^ V[^ ]* +hevc_amf ' >/dev/null; then
    echo "this ffmpeg has no hevc_amf encoder; nothing to test" >&2
    exit 77
fi

if command -v timeout >/dev/null 2>&1; then
    BOUND=(timeout "$TIMEOUT")
else
    BOUND=()
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0; skip=0

report() {
    if [ "$2" = 1 ]; then
        pass=$((pass + 1)); echo "PASS  $1  $3"
    else
        fail=$((fail + 1)); echo "FAIL  $1  $3"
    fi
}

# encode <out> <log> <pix_fmt> [ffmpeg output options...]
encode() {
    local out="$1" log="$2" fmt="$3"; shift 3
    # shellcheck disable=SC2086
    "${BOUND[@]}" "$FFMPEG" -nostdin -hide_banner -nostats -loglevel error -y \
        $INIT_HW_DEVICE -filter_hw_device hw \
        -f lavfi -i "testsrc2=s=1280x720:r=30:d=1" \
        -vf "format=$fmt,hwupload" -c:v hevc_amf "$@" "$out" >"$log" 2>&1
}

# nal_types <file>: NAL unit types of the video stream's extradata, in order.
# NUT stores the encoder's extradata as it is.
nal_types() {
    local hex i types=""
    hex="$("$FFPROBE" -v error -select_streams v:0 -show_streams -show_data "$1" 2>/dev/null |
        sed -n '/^extradata=/,/^extradata_size=/p' | grep -E '^[0-9a-f]{8}:' |
        cut -c11-49 | tr -d ' \n')"
    for ((i = 0; i + 8 <= ${#hex}; i += 2)); do
        if [ "${hex:i:6}" = 000001 ]; then
            types="$types $(( (16#${hex:i+6:2} >> 1) & 63 ))"
            i=$((i + 6))
        fi
    done
    echo "${types# }"
}

check_order() {
    local name="$1" fmt="$2"
    local out="$WORK/$name.nut" log="$WORK/$name.log"
    if ! encode "$out" "$log" "$fmt" -frames:v 1; then
        if grep -q "10-bit encoder is not supported" "$log"; then
            skip=$((skip + 1)); echo "SKIP  $name  runtime refuses 10-bit encode"
            return
        fi
        report "$name" 0 "encode failed: $(head -2 "$log" | tr '\n' ' ')"
        return
    fi
    local types
    types="$(nal_types "$out")"
    case "$types " in
        "32 "*"33 "*"34 "*) report "$name" 1 "extradata NAL types: $types" ;;
        *) report "$name" 0 "extradata NAL types: ${types:-none} (want VPS 32 first, then SPS 33, PPS 34)" ;;
    esac
}

for c in $CASES; do
    case "$c" in
        order_8bit) check_order "$c" nv12 ;;
        order_10bit) check_order "$c" p010le ;;
        metadata)
            out="$WORK/$c.mkv"; log="$WORK/$c.log"
            if ! encode "$out" "$log" nv12 -bsf:v hevc_metadata=colour_primaries=1:transfer_characteristics=1:matrix_coefficients=1; then
                report "$c" 0 "encode failed: $(head -3 "$log" | tr '\n' ' ')"
                continue
            fi
            primaries="$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=color_primaries -of csv=p=0 "$out")"
            frames="$("${BOUND[@]}" "$FFMPEG" -nostdin -hide_banner -v error -i "$out" -f framemd5 - 2>/dev/null | grep -vc '^#')"
            if [ "$primaries" = bt709 ] && [ "$frames" = "$FRAMES" ]; then
                report "$c" 1 "bt709 primaries, $frames frames decoded"
            else
                report "$c" 0 "primaries=${primaries:-none}, $frames of $FRAMES frames decoded"
            fi
            ;;
        *) echo "unknown case: $c" >&2 ;;
    esac
done

echo "---- $pass passed, $fail failed, $skip skipped"
if [ $((pass + fail)) -eq 0 ]; then
    exit 77
fi
[ "$fail" -eq 0 ]
