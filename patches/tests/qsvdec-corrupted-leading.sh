#!/usr/bin/env bash
#
# Reproducer for
#   0025-avcodec-qsvdec-drop-corrupted-leading-frames.patch
#
# A stream that starts on an open GOP has leading pictures that reference the
# GOP that was cut off. Software decoders drop them. Without 0025 QSV outputs
# them as concealed pictures, so the picture starts with garbage and the
# output has extra frames.
#
# Cases:
#   open_gop       H.264 that starts on a non-IDR I-frame followed by a
#                  leading B-frame. QSV must output the same frames as
#                  software: same count, same first pts, and min PSNR at least
#                  MIN_PSNR with frames paired by timestamp.
#   intra_refresh  H.264 with periodic intra refresh, cut mid-refresh. A guard,
#                  not a reproducer: the runtime may mark these pictures
#                  corrupted until the refresh completes, and QSV must not
#                  output fewer frames than software (it outputs more without
#                  and with 0025 on the runtimes tested).
#
# Usage: qsvdec-corrupted-leading.sh [/path/to/ffmpeg]
#        FFMPEG=/path/to/ffmpeg qsvdec-corrupted-leading.sh
#        CASES="open_gop" qsvdec-corrupted-leading.sh /path/to/ffmpeg
#
# Exit: 0 all runnable cases passed, 1 any case failed, 77 nothing was runnable.

set -uo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"

CASES="${CASES:-open_gop intra_refresh}"
INIT_HW_DEVICE="${INIT_HW_DEVICE:-qsv=hw}"
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
        run_bounded "$TIMEOUT" "$FFMPEG" -nostdin -hide_banner -nostats -loglevel info \
            -init_hw_device "$INIT_HW_DEVICE" \
            -hwaccel qsv -hwaccel_output_format qsv -hwaccel_device hw -i "$sample" \
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
    local sw="$logdir/$name-sw.log" qsv="$logdir/$name-qsv.log" cmp="$logdir/$name-psnr.log"
    local rc

    if [ ! -f "$sample" ]; then
        echo "ERROR: sample not found: $sample" >&2
        exit 2
    fi

    decode "$sw" "$sample"
    decode "$qsv" "$sample" qsv
    rc=$?

    if [ $rc -eq 124 ]; then
        echo "FAIL: $name - ffmpeg did not exit within ${TIMEOUT}s"
        fail=$((fail + 1))
        return
    fi

    if [ $rc -ne 0 ]; then
        echo "SKIP: $name - ffmpeg exited $rc for an unrelated reason (no QSV device?)"
        sed -n 's/^/       | /p' <<<"$(grep -iE "error|not (supported|available|found)|no such|failed|cannot|unknown" "$qsv" | tail -3)"
        skip=$((skip + 1))
        return
    fi

    local nsw nqsv
    nsw=$(frames "$sw"); nqsv=$(frames "$qsv")

    if [ "$name" = intra_refresh ]; then
        if [ "$nqsv" -lt "$nsw" ]; then
            echo "FAIL: $name - QSV output $nqsv frames, software $nsw: QSV dropped frames it should keep"
            fail=$((fail + 1))
            return
        fi
        echo "PASS: $name - QSV output $nqsv frames, software $nsw"
        pass=$((pass + 1))
        return
    fi

    local fsw fqsv
    fsw=$(first_pts "$sw"); fqsv=$(first_pts "$qsv")
    if [ "$nqsv" -ne "$nsw" ] || [ "$fqsv" != "$fsw" ]; then
        echo "FAIL: $name - QSV output $nqsv frames from $fqsv s, software $nsw from $fsw s; 0025 is missing"
        fail=$((fail + 1))
        return
    fi

    run_bounded "$TIMEOUT" "$FFMPEG" -nostdin -hide_banner -nostats -loglevel info \
        -init_hw_device "$INIT_HW_DEVICE" \
        -i "$sample" \
        -hwaccel qsv -hwaccel_output_format qsv -hwaccel_device hw -i "$sample" \
        -filter_complex "[0:v]format=nv12[sw];[1:v]hwdownload,format=nv12[hw];[hw][sw]psnr=shortest=1" \
        -f null - >"$cmp" 2>&1

    local min
    min=$(grep -oE 'PSNR .* min:[0-9.inf]+' "$cmp" | tail -1 | sed 's/.* min://')
    if [ -z "$min" ]; then
        echo "FAIL: $name - no frames compared"
        fail=$((fail + 1))
        return
    fi
    if [ "$min" != "inf" ] && awk -v m="$min" -v t="$MIN_PSNR" 'BEGIN { exit !(m < t) }'; then
        echo "FAIL: $name - QSV frames differ from software: min PSNR $min dB"
        fail=$((fail + 1))
        return
    fi

    echo "PASS: $name - $nqsv frames from $fqsv s as in software, min PSNR $min dB"
    pass=$((pass + 1))
}

echo "ffmpeg:  $FFMPEG"
echo "version: $("$FFMPEG" -version 2>/dev/null | head -1)"
echo "device:  $INIT_HW_DEVICE"
echo

for case in $CASES; do
    case "$case" in
        open_gop)      run_case open_gop h264-320x240-open-gop-start.mkv ;;
        intra_refresh) run_case intra_refresh h264-320x240-intra-refresh-mid.mkv ;;
        *) echo "unknown case: $case" >&2; exit 2 ;;
    esac
done

echo
echo "$pass passed, $fail failed, $skip skipped"

[ $fail -gt 0 ] && exit 1
[ $pass -eq 0 ] && exit 77
exit 0
