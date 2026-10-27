#!/usr/bin/env bash
#
# Reproducer for
#   0022-avcodec-qsvdec-keep-timestamps-positive-for-the-runtime.patch
#
# An -ss input seek starts decoding at the keyframe before the seek point; the
# frames in between have negative pts. Without 0022 the runtime gets them as
# unsigned TimeStamps, treats them as missing and makes up positive times, so
# ffmpeg keeps them and every later frame is late by about as many frames. In
# ErsatzTV every QSV item that starts mid-GOP plays its video 100-200 ms late.
#
# The nopts case strips every packet's pts, as in a raw stream or H.264 in AVI.
# The runtime then makes up times from 0 that never carried 0022's bias, and a
# version of 0022 that removed the bias anyway put every frame at -95443 s.
#
# Each case decodes the sample twice in one ffmpeg run, in software and with
# -hwaccel qsv, both from -ss 1.4, and compares the frames psnr pairs by
# timestamp. The picture scrolls every frame, so a timing error scores ~15 dB;
# a correct decode scores inf (H.264, bit-exact) or ~70 dB (MPEG-2, whose IDCT
# isn't bit-exact between decoders).
#
# Cases:
#   h264    h264_qsv, B-frames, keyframe every 30 frames
#   mpeg2   mpeg2_qsv, B-frames, open GOPs every 15 frames
#   nopts   h264_qsv, the h264 sample from the start with no packet pts
#
# Pass criteria: ffmpeg exits 0 and the minimum frame PSNR is at least MIN_PSNR.
#
# Usage: qsvdec-negative-pts.sh [/path/to/ffmpeg]
#        FFMPEG=/path/to/ffmpeg qsvdec-negative-pts.sh
#        CASES="h264" qsvdec-negative-pts.sh /path/to/ffmpeg
#
# Exit: 0 all runnable cases passed, 1 any case failed, 77 nothing was runnable.

set -uo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"

CASES="${CASES:-h264 mpeg2 nopts}"
INIT_HW_DEVICE="${INIT_HW_DEVICE:-qsv=hw}"
TIMEOUT="${TIMEOUT:-60}"
SEEK="${SEEK:-1.4}"
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

run_case() {
    local name="$1" sample="$here/../samples/$2"
    shift 2
    local input=("$@")
    local log="$logdir/$name.log"
    local rc

    if [ ! -f "$sample" ]; then
        echo "ERROR: sample not found: $sample" >&2
        exit 2
    fi

    run_bounded "$TIMEOUT" \
        "$FFMPEG" -nostdin -hide_banner -nostats -loglevel info \
        -init_hw_device "$INIT_HW_DEVICE" \
        "${input[@]}" -i "$sample" \
        -hwaccel qsv -hwaccel_output_format qsv -hwaccel_device hw \
        "${input[@]}" -i "$sample" \
        -filter_complex "[0:v]format=nv12[sw];[1:v]hwdownload,format=nv12[hw];[hw][sw]psnr=shortest=1" \
        -f null - >"$log" 2>&1
    rc=$?

    if [ $rc -eq 124 ]; then
        echo "FAIL: $name - ffmpeg did not exit within ${TIMEOUT}s"
        sed -n 's/^/       | /p' <<<"$(tail -3 "$log")"
        fail=$((fail + 1))
        return
    fi

    if [ $rc -ne 0 ]; then
        echo "SKIP: $name - ffmpeg exited $rc for an unrelated reason (no QSV device?)"
        sed -n 's/^/       | /p' <<<"$(grep -iE "error|not (supported|available|found)|no such|failed|cannot|unknown" "$log" | tail -3)"
        skip=$((skip + 1))
        return
    fi

    local min
    min=$(grep -oE 'PSNR .* min:[0-9.inf]+' "$log" | tail -1 | sed 's/.* min://')
    if [ -z "$min" ]; then
        echo "FAIL: $name - no frames compared: QSV and software timestamps never overlap"
        fail=$((fail + 1))
        return
    fi

    if [ "$min" != "inf" ] && awk -v m="$min" -v t="$MIN_PSNR" 'BEGIN { exit !(m < t) }'; then
        echo "FAIL: $name - QSV frames are mistimed: min PSNR $min dB against software; 0022 is missing"
        fail=$((fail + 1))
        return
    fi

    echo "PASS: $name - min PSNR $min dB against software"
    pass=$((pass + 1))
}

echo "ffmpeg:  $FFMPEG"
echo "version: $("$FFMPEG" -version 2>/dev/null | head -1)"
echo "device:  $INIT_HW_DEVICE"
echo

for case in $CASES; do
    case "$case" in
        h264)  run_case h264 h264-320x240-scroll-gop30.mkv -ss "$SEEK" -t 0.5 ;;
        mpeg2) run_case mpeg2 mpeg2-320x240-scroll-gop15.mkv -ss "$SEEK" -t 0.5 ;;
        nopts) run_case nopts h264-320x240-scroll-gop30.mkv -t 0.5 -bsf:v setts=pts=NOPTS ;;
        *) echo "unknown case: $case" >&2; exit 2 ;;
    esac
done

echo
echo "$pass passed, $fail failed, $skip skipped"

[ $fail -gt 0 ] && exit 1
[ $pass -eq 0 ] && exit 77
exit 0
