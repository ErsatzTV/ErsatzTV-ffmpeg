#!/usr/bin/env bash
#
# Reproducer for
#   0028-avcodec-amfdec-drop-leading-frames-before-the-first-keyframe.patch
#
# A stream that starts on an open GOP has leading pictures that reference the
# GOP that was cut off. Software decoders drop them. Without 0028 AMF outputs
# them as concealed pictures, so the picture starts with garbage and the output
# has extra frames.
#
# Cases:
#   h264_open_gop   H.264 that starts on a non-IDR I-frame followed by a
#                   leading B-frame.
#   h264_no_sei     Same H.264 pictures with SEI stripped. Compare against the
#                   SEI-bearing reference's 90 frames: software decoding the
#                   stripped input suppresses two valid buffered pictures.
#   mpeg2_open_gop  MPEG-2 that starts on an open GOP's I-frame followed by a
#                   leading B-frame with the same pts.
#   hevc_open_gop   HEVC that starts on a CRA picture followed by a RASL
#                   picture. The runtime doesn't drop RASL pictures itself.
#                   All three: AMF must output the same frames as software: same
#                   count, same first pts, and min PSNR at least MIN_PSNR with
#                   frames paired in order.
#   hevc_radl       Valid RADL pictures before an IDR must be preserved.
#   mpeg2_closed    Valid backward-predicted leading B-picture in a closed GOP
#                   must be preserved. Both must match software in full.
#   intra_refresh   H.264 with periodic intra refresh, cut mid-refresh, no
#                   I-frames. A guard: AMF must not output fewer frames than
#                   software.
#
# Point INIT_HW_DEVICE at the AMD adapter on multi-GPU Windows boxes, e.g.
#   INIT_HW_DEVICE="-init_hw_device d3d11va=dx:2 -init_hw_device amf=hw@dx"
#
# Usage: amfdec-leading-frames.sh [/path/to/ffmpeg]
#        FFMPEG=/path/to/ffmpeg amfdec-leading-frames.sh
#        CASES="h264_open_gop" amfdec-leading-frames.sh /path/to/ffmpeg
#
# Exit: 0 all runnable cases passed, 1 any case failed, 77 nothing was runnable.

set -uo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"

CASES="${CASES:-h264_open_gop h264_no_sei mpeg2_open_gop hevc_open_gop hevc_radl mpeg2_closed intra_refresh}"
INIT_HW_DEVICE="${INIT_HW_DEVICE:--init_hw_device amf=hw}"
TIMEOUT="${TIMEOUT:-60}"
MIN_PSNR="${MIN_PSNR:-40}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

logdir="$(mktemp -d)"
trap 'rm -rf "$logdir"' EXIT

if ! "$FFMPEG" -version >/dev/null 2>&1; then
    echo "ERROR: cannot run ffmpeg: $FFMPEG" >&2
    exit 2
fi

pass=0; fail=0; skip=0

run_bounded() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
        return $?
    fi

    "$@" &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$secs" ]; then
            kill -9 "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 124
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "$pid"
    return $?
}

# decode <log> <sample> [hw]: one decode with showinfo, frame timestamps in <log>
decode() {
    local log="$1" sample="$2" hw="${3:-}"
    if [ -n "$hw" ]; then
        # shellcheck disable=SC2086
        run_bounded "$TIMEOUT" "$FFMPEG" -nostdin -hide_banner -nostats -loglevel info \
            $INIT_HW_DEVICE \
            -hwaccel amf -hwaccel_output_format amf -hwaccel_device hw -i "$sample" \
            -fps_mode passthrough -vf hwdownload,format=nv12,showinfo -f null - >"$log" 2>&1
    else
        run_bounded "$TIMEOUT" "$FFMPEG" -nostdin -hide_banner -nostats -loglevel info \
            -i "$sample" -fps_mode passthrough -vf showinfo -f null - >"$log" 2>&1
    fi
}

frames() { grep -c 'n: *[0-9]* pts:' "$1"; }
first_pts() { grep -m1 -oE 'pts_time:[-0-9.]+' "$1" | cut -d: -f2; }

run_case() {
    local name="$1" sample="$here/../samples/$2"
    local reference="$here/../samples/${3:-$2}"
    local sw="$logdir/$name-sw.log" amf="$logdir/$name-amf.log" cmp="$logdir/$name-psnr.log"
    local rc

    if [ ! -f "$sample" ] || [ ! -f "$reference" ]; then
        echo "ERROR: sample or reference not found: $sample / $reference" >&2
        exit 2
    fi

    if ! decode "$sw" "$reference"; then
        echo "FAIL: $name - software reference decode failed"
        tail -5 "$sw"
        fail=$((fail + 1))
        return
    fi
    decode "$amf" "$sample" amf
    rc=$?

    if [ $rc -eq 124 ]; then
        echo "FAIL: $name - ffmpeg did not exit within ${TIMEOUT}s"
        fail=$((fail + 1))
        return
    fi

    if [ $rc -ne 0 ]; then
        if [ $rc -ne 139 ] && [ $rc -ne 134 ] && grep -qiE 'Device creation failed:|Unrecognized hwaccel:|Unknown decoder ' "$amf"; then
            echo "SKIP: $name - AMF device or decoder unavailable"
            skip=$((skip + 1))
        else
            echo "FAIL: $name - AMF decode exited $rc"
            fail=$((fail + 1))
        fi
        tail -5 "$amf"
        return
    fi

    local nsw namf
    nsw=$(frames "$sw"); namf=$(frames "$amf")
    if [ "$nsw" -eq 0 ] || [ "$namf" -eq 0 ]; then
        echo "FAIL: $name - no decoded frames (software $nsw, AMF $namf)"
        fail=$((fail + 1))
        return
    fi

    if [ "$name" = intra_refresh ]; then
        if [ "$namf" -lt "$nsw" ]; then
            echo "FAIL: $name - AMF output $namf frames, software $nsw: AMF dropped frames it should keep"
            fail=$((fail + 1))
            return
        fi
        echo "PASS: $name - AMF output $namf frames, software $nsw"
        pass=$((pass + 1))
        return
    fi

    local fsw famf
    fsw=$(first_pts "$sw"); famf=$(first_pts "$amf")
    if [ "$namf" -ne "$nsw" ] || [ "$famf" != "$fsw" ]; then
        echo "FAIL: $name - AMF output $namf frames from $famf s, software $nsw from $fsw s"
        fail=$((fail + 1))
        return
    fi

    # shellcheck disable=SC2086
    run_bounded "$TIMEOUT" "$FFMPEG" -nostdin -hide_banner -nostats -loglevel info \
        $INIT_HW_DEVICE \
        -i "$reference" \
        -hwaccel amf -hwaccel_output_format amf -hwaccel_device hw -i "$sample" \
        -filter_complex "[0:v]format=nv12,settb=1/30,setpts=N[sw];[1:v]hwdownload,format=nv12,settb=1/30,setpts=N[hw];[hw][sw]psnr=shortest=1" \
        -f null - >"$cmp" 2>&1
    rc=$?
    if [ $rc -ne 0 ]; then
        echo "FAIL: $name - PSNR comparison exited $rc"
        tail -5 "$cmp"
        fail=$((fail + 1))
        return
    fi

    local min
    min=$(grep -oE 'PSNR .* min:[0-9.inf]+' "$cmp" | tail -1 | sed 's/.* min://')
    if [ -z "$min" ]; then
        echo "FAIL: $name - no frames compared"
        fail=$((fail + 1))
        return
    fi
    if [ "$min" != "inf" ] && awk -v m="$min" -v t="$MIN_PSNR" 'BEGIN { exit !(m < t) }'; then
        echo "FAIL: $name - AMF frames differ from software: min PSNR $min dB"
        fail=$((fail + 1))
        return
    fi

    echo "PASS: $name - $namf frames from $famf s as in software, min PSNR $min dB"
    pass=$((pass + 1))
}

echo "ffmpeg:  $FFMPEG"
echo "version: $("$FFMPEG" -version 2>/dev/null | head -1)"
echo "device:  $INIT_HW_DEVICE"
echo

for case in $CASES; do
    case "$case" in
        h264_open_gop)  run_case h264_open_gop h264-320x240-open-gop-start.mkv ;;
        h264_no_sei)    run_case h264_no_sei h264-320x240-open-gop-nosei.nut h264-320x240-open-gop-start.mkv ;;
        mpeg2_open_gop) run_case mpeg2_open_gop mpeg2-320x240-open-gop-dup-pts.mkv ;;
        hevc_open_gop)  run_case hevc_open_gop hevc-320x240-open-gop-start.mkv ;;
        hevc_radl)     run_case hevc_radl hevc-320x240-radl-start.mkv ;;
        mpeg2_closed)  run_case mpeg2_closed mpeg2-320x240-closed-gop-leading.mkv ;;
        intra_refresh)  run_case intra_refresh h264-320x240-intra-refresh-mid.mkv ;;
        *) echo "unknown case: $case" >&2; exit 2 ;;
    esac
done

echo
echo "$pass passed, $fail failed, $skip skipped"

[ $fail -gt 0 ] && exit 1
[ $pass -eq 0 ] && exit 77
exit 0
