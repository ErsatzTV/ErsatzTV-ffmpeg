#!/usr/bin/env bash
#
# Reproducer for
#   0023-avcodec-mpeg12dec-drop-captions-of-skipped-pictures.patch
#
# The sample is MPEG-2 with A53 captions (60 bytes, 20 cc triplets, a frame)
# that starts mid-GOP. Without 0023 the decoder keeps the captions of every
# picture it skips and attaches them to the next frame it outputs: 1680 bytes
# on the first I-frame and 180 on the P-frame after it. cc_count has 5 bits,
# so no frame may carry more than 31 triplets (93 bytes).
#
# Cases:
#   decode   software decode; checks the caption size on every frame. Runs
#            anywhere.
#   vaapi    VAAPI decode into h264_vaapi with captions, which is how ErsatzTV
#            transcodes a broadcast recording. Without 0023 it fails with
#            "Access unit too large". Skipped when VAAPI is unavailable.
#
# Pass criteria: every case decodes the sample, and every frame (of the output,
# for vaapi) carries captions of at most 93 bytes.
#
# Usage: mpeg2dec-skipped-picture-captions.sh [/path/to/ffmpeg]
#        FFMPEG=/path/to/ffmpeg mpeg2dec-skipped-picture-captions.sh
#        CASES="decode" mpeg2dec-skipped-picture-captions.sh /path/to/ffmpeg
#
# Exit: 0 all runnable cases passed, 1 any case failed, 77 nothing was runnable.

set -uo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"

CASES="${CASES:-decode vaapi}"
VAAPI_DEVICE="${VAAPI_DEVICE:-/dev/dri/renderD128}"
TIMEOUT="${TIMEOUT:-60}"
EXPECTED_FRAMES="${EXPECTED_FRAMES:-30}"
MAX_CC_BYTES=93

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sample="$here/../samples/mpeg2-640x480-a53cc-midgop.ts"

logdir="$(mktemp -d)"
trap 'rm -rf "$logdir"' EXIT

if ! "$FFMPEG" -version >/dev/null 2>&1; then
    echo "ERROR: cannot run ffmpeg: $FFMPEG" >&2
    exit 2
fi

if [ ! -f "$sample" ]; then
    echo "ERROR: sample not found: $sample" >&2
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

# prints "<frames> <frames with captions> <largest caption bytes>"
caption_stats() {
    local input="$1" log="$2"
    run_bounded "$TIMEOUT" \
        "$FFMPEG" -nostdin -hide_banner -nostats -loglevel info \
        -i "$input" -map 0:v:0 -vf showinfo -f null - >"$log" 2>&1 || return 1
    awk '
        /Parsed_showinfo.* n: *[0-9]+ / { frames++ }
        /Closed Captions: \([0-9]+ bytes\)/ {
            cc++
            v = $0; sub(/.*Closed Captions: \(/, "", v); sub(/ bytes.*/, "", v)
            if (v + 0 > max) max = v + 0
        }
        END { print frames + 0, cc + 0, max + 0 }' "$log"
}

check_stats() {
    local name="$1" stats="$2" frames cc max
    read -r frames cc max <<<"$stats"

    if [ "$frames" -lt "$EXPECTED_FRAMES" ]; then
        echo "FAIL: $name - $frames/$EXPECTED_FRAMES frames"
        fail=$((fail + 1))
        return
    fi
    if [ "$cc" -ne "$frames" ]; then
        echo "FAIL: $name - captions on $cc of $frames frames"
        fail=$((fail + 1))
        return
    fi
    if [ "$max" -gt "$MAX_CC_BYTES" ]; then
        echo "FAIL: $name - a frame carries $max bytes of captions (limit $MAX_CC_BYTES); 0023 is missing"
        fail=$((fail + 1))
        return
    fi

    echo "PASS: $name - $frames frames, captions on all, largest $max bytes"
    pass=$((pass + 1))
}

case_decode() {
    local stats
    if ! stats=$(caption_stats "$sample" "$logdir/decode.log"); then
        echo "FAIL: decode - ffmpeg failed"
        sed -n 's/^/       | /p' <<<"$(tail -3 "$logdir/decode.log")"
        fail=$((fail + 1))
        return
    fi
    check_stats decode "$stats"
}

case_vaapi() {
    local log="$logdir/vaapi.log" out="$logdir/vaapi.ts" rc stats

    run_bounded "$TIMEOUT" \
        "$FFMPEG" -nostdin -hide_banner -nostats -loglevel error \
        -vaapi_device "$VAAPI_DEVICE" -hwaccel vaapi -hwaccel_output_format vaapi \
        -i "$sample" -map 0:v:0 -c:v h264_vaapi -b:v 4000k -f mpegts "$out" >"$log" 2>&1
    rc=$?

    if grep -q "Access unit too large" "$log"; then
        echo "FAIL: vaapi - h264_vaapi rejected the caption SEI; 0023 is missing"
        sed -n 's/^/       | /p' <<<"$(grep "Access unit too large" "$log" | head -1)"
        fail=$((fail + 1))
        return
    fi

    if [ $rc -eq 124 ]; then
        echo "FAIL: vaapi - ffmpeg did not exit within ${TIMEOUT}s"
        fail=$((fail + 1))
        return
    fi

    if [ $rc -ne 0 ]; then
        echo "SKIP: vaapi - ffmpeg exited $rc for an unrelated reason (no VAAPI H.264 encode?)"
        sed -n 's/^/       | /p' <<<"$(grep -iE "error|not (supported|available|found)|no such|failed|cannot" "$log" | tail -3)"
        skip=$((skip + 1))
        return
    fi

    if ! stats=$(caption_stats "$out" "$logdir/vaapi-check.log"); then
        echo "FAIL: vaapi - output does not decode"
        fail=$((fail + 1))
        return
    fi
    check_stats vaapi "$stats"
}

echo "ffmpeg:  $FFMPEG"
echo "version: $("$FFMPEG" -version 2>/dev/null | head -1)"
echo

for case in $CASES; do
    case "$case" in
        decode) case_decode ;;
        vaapi)  case_vaapi ;;
        *) echo "unknown case: $case" >&2; exit 2 ;;
    esac
done

echo
echo "$pass passed, $fail failed, $skip skipped"

[ $fail -gt 0 ] && exit 1
[ $pass -eq 0 ] && exit 77
exit 0
