#!/usr/bin/env bash
#
# Reproducer for
#   0026-avcodec-qsvdec-add-vc1-start-codes.patch
#
# ASF stores VC-1 Advanced (WVC1) frames without start codes and keeps the
# sequence header and entry point in the extradata. Without 0026 vc1_qsv never
# finds a sequence header and decodes nothing ("video_get_buffer: image
# parameters invalid" for every packet).
#
# Cases:
#   bare         VC-1 Advanced in Matroska, packets laid out as in ASF. QSV
#                must output the same frames as software, bit-exact (framemd5
#                of NV12).
#   start_codes  The same frames with start codes and the header in-band, as
#                in Blu-ray VC-1. A guard, not a reproducer: it passes with
#                and without 0026, and 0026 must leave it alone.
#
# Needs a runtime that decodes VC-1. Arc (DG2) and later have no VC-1 decode.
# Without 0026 the bare case fails before the runtime reports that, so the
# start_codes sample decides whether the device can decode VC-1 at all, and
# both cases are skipped if it can't.
#
# Usage: qsvdec-vc1-start-codes.sh [/path/to/ffmpeg]
#        FFMPEG=/path/to/ffmpeg qsvdec-vc1-start-codes.sh
#
# Exit: 0 all runnable cases passed, 1 any case failed, 77 nothing was runnable.

set -uo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"

CASES="${CASES:-bare start_codes}"
INIT_HW_DEVICE="${INIT_HW_DEVICE:-qsv=hw}"
TIMEOUT="${TIMEOUT:-60}"

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

# decode <out> <log> <sample> [hw]: framemd5 of NV12 frames in <out>
decode() {
    local out="$1" log="$2" sample="$3" hw="${4:-}"
    if [ -n "$hw" ]; then
        run_bounded "$TIMEOUT" "$FFMPEG" -nostdin -hide_banner -nostats -loglevel warning \
            -init_hw_device "$INIT_HW_DEVICE" -filter_hw_device hw \
            -c:v vc1_qsv -i "$sample" \
            -fps_mode passthrough -vf format=nv12 -f framemd5 "$out" >"$log" 2>&1
    else
        run_bounded "$TIMEOUT" "$FFMPEG" -nostdin -hide_banner -nostats -loglevel warning \
            -i "$sample" -fps_mode passthrough -vf format=nv12 -f framemd5 "$out" >"$log" 2>&1
    fi
}

# no_vc1_decode: the runtime can't decode VC-1 on this device (DG2 and later)
no_vc1_decode() {
    if [ -z "${vc1_probe:-}" ]; then
        decode "$logdir/probe.md5" "$logdir/probe.log" "$here/../samples/vc1-320x240-start-codes.mkv" qsv
        if grep -q 'Error querying IO surface: unsupported' "$logdir/probe.log"; then
            vc1_probe=none
        else
            vc1_probe=ok
        fi
    fi
    [ "$vc1_probe" = none ]
}

hashes() { grep -v '^#' "$1" | awk -F, '{ gsub(/ /, "", $6); print $6 }'; }

run_case() {
    local name="$1" sample="$here/../samples/$2"
    local sw="$logdir/$name-sw.md5" qsv="$logdir/$name-qsv.md5"
    local swlog="$logdir/$name-sw.log" qsvlog="$logdir/$name-qsv.log"
    local rc

    if [ ! -f "$sample" ]; then
        echo "ERROR: sample not found: $sample" >&2
        exit 2
    fi

    if no_vc1_decode; then
        echo "SKIP: $name - the runtime has no VC-1 decode on this device"
        skip=$((skip + 1))
        return
    fi

    decode "$sw" "$swlog" "$sample"
    if [ $? -ne 0 ]; then
        echo "ERROR: $name - software decode failed" >&2
        sed -n 's/^/       | /p' "$swlog" | tail -3 >&2
        exit 2
    fi

    decode "$qsv" "$qsvlog" "$sample" qsv
    rc=$?

    if [ $rc -eq 124 ]; then
        echo "FAIL: $name - ffmpeg did not exit within ${TIMEOUT}s"
        fail=$((fail + 1))
        return
    fi

    if grep -q 'image parameters invalid' "$qsvlog"; then
        echo "FAIL: $name - vc1_qsv found no sequence header (image parameters invalid); 0026 is missing"
        fail=$((fail + 1))
        return
    fi

    if [ $rc -ne 0 ]; then
        echo "SKIP: $name - ffmpeg exited $rc for an unrelated reason (no QSV device?)"
        sed -n 's/^/       | /p' <<<"$(grep -iE "error|not (supported|available|found)|no such|failed|cannot|unknown" "$qsvlog" | tail -3)"
        skip=$((skip + 1))
        return
    fi

    local nsw nqsv
    nsw=$(hashes "$sw" | wc -l); nqsv=$(hashes "$qsv" | wc -l)
    if [ "$nqsv" -ne "$nsw" ]; then
        echo "FAIL: $name - QSV output $nqsv frames, software $nsw"
        fail=$((fail + 1))
        return
    fi

    local differ
    differ=$(paste -d' ' <(hashes "$sw") <(hashes "$qsv") | awk '$1 != $2' | wc -l)
    if [ "$differ" -ne 0 ]; then
        echo "FAIL: $name - $differ of $nqsv QSV frames differ from software"
        fail=$((fail + 1))
        return
    fi

    echo "PASS: $name - $nqsv frames, bit-exact with software"
    pass=$((pass + 1))
}

echo "ffmpeg:  $FFMPEG"
echo "version: $("$FFMPEG" -version 2>/dev/null | head -1)"
echo "device:  $INIT_HW_DEVICE"
echo

for case in $CASES; do
    case "$case" in
        bare)        run_case bare vc1-320x240-bare-frames.mkv ;;
        start_codes) run_case start_codes vc1-320x240-start-codes.mkv ;;
        *) echo "unknown case: $case" >&2; exit 2 ;;
    esac
done

echo
echo "$pass passed, $fail failed, $skip skipped"

[ $fail -gt 0 ] && exit 1
[ $pass -eq 0 ] && exit 77
exit 0
