#!/usr/bin/env bash
#
# Reproducer for
#   0024-avcodec-qsvdec-do-not-set-pkt_dts-from-a-later-packet.patch
#
# qsvdec returns each frame several packets after its own, and without 0024
# the frame carries the dts of the packet being decoded then. The sample starts
# on an open GOP whose leading B-frame repeats the I-frame's pts. That one fault
# makes ffmpeg's best_effort_timestamp switch to the dts for the rest of the
# stream, so every QSV frame after the first is late by the decoder's delay.
#
# Decodes the sample twice in one ffmpeg run, in software and with
# -hwaccel qsv, and compares the frames psnr pairs by timestamp. Frames at pts
# 0 are left out: QSV also outputs the leading B-frame there as a concealed
# picture, a separate qsvdec bug. The picture scrolls every frame, so a timing
# error scores ~15 dB; a correct decode scores ~70 dB (MPEG-2's IDCT isn't
# bit-exact between decoders).
#
# Pass criteria: ffmpeg exits 0 and the minimum frame PSNR is at least MIN_PSNR.
#
# Usage: qsvdec-pkt-dts.sh [/path/to/ffmpeg]
#        FFMPEG=/path/to/ffmpeg qsvdec-pkt-dts.sh
#
# Exit: 0 passed, 1 failed, 77 not runnable (no QSV device).

set -uo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"

INIT_HW_DEVICE="${INIT_HW_DEVICE:-qsv=hw}"
TIMEOUT="${TIMEOUT:-60}"
MIN_PSNR="${MIN_PSNR:-40}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sample="$here/../samples/mpeg2-320x240-open-gop-dup-pts.mkv"

logdir="$(mktemp -d)"
trap 'rm -rf "$logdir"' EXIT
log="$logdir/mpeg2.log"

if ! "$FFMPEG" -version >/dev/null 2>&1; then
    echo "ERROR: cannot run ffmpeg: $FFMPEG" >&2
    exit 2
fi

if [ ! -f "$sample" ]; then
    echo "ERROR: sample not found: $sample" >&2
    exit 2
fi

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

echo "ffmpeg:  $FFMPEG"
echo "version: $("$FFMPEG" -version 2>/dev/null | head -1)"
echo "device:  $INIT_HW_DEVICE"
echo

run_bounded "$TIMEOUT" \
    "$FFMPEG" -nostdin -hide_banner -nostats -loglevel info \
    -init_hw_device "$INIT_HW_DEVICE" \
    -i "$sample" \
    -hwaccel qsv -hwaccel_output_format qsv -hwaccel_device hw \
    -i "$sample" \
    -filter_complex "[0:v]select='gt(t,0)',format=nv12[sw];[1:v]hwdownload,select='gt(t,0)',format=nv12[hw];[hw][sw]psnr=shortest=1" \
    -f null - >"$log" 2>&1
rc=$?

if [ $rc -eq 124 ]; then
    echo "FAIL: mpeg2 - ffmpeg did not exit within ${TIMEOUT}s"
    sed -n 's/^/       | /p' <<<"$(tail -3 "$log")"
    exit 1
fi

if [ $rc -ne 0 ]; then
    echo "SKIP: mpeg2 - ffmpeg exited $rc for an unrelated reason (no QSV device?)"
    sed -n 's/^/       | /p' <<<"$(grep -iE "error|not (supported|available|found)|no such|failed|cannot|unknown" "$log" | tail -3)"
    exit 77
fi

min=$(grep -oE 'PSNR .* min:[0-9.inf]+' "$log" | tail -1 | sed 's/.* min://')
if [ -z "$min" ]; then
    echo "FAIL: mpeg2 - no PSNR in the log (no frames compared)"
    exit 1
fi

if [ "$min" != "inf" ] && awk -v m="$min" -v t="$MIN_PSNR" 'BEGIN { exit !(m < t) }'; then
    echo "FAIL: mpeg2 - QSV frames are mistimed: min PSNR $min dB against software; 0024 is missing"
    exit 1
fi

echo "PASS: mpeg2 - min PSNR $min dB against software"
exit 0
