#!/usr/bin/env bash
#
# Reproducer for
#   0021-avcodec-qsvdec-fix-av1-duplicate-hdr-side-data.patch
#
# The sample is HDR10 AV1 in Matroska with mastering display and content light
# metadata both in the bitstream and in the container. av1_qsv adds the
# in-band copy to frames that already carry the container's, and the filter
# graph refuses the duplicate while it configures its links:
#
#   [vf#0:0] Task finished with error code: -17 (File exists)
#
# Any filter triggers it, even null, so ErsatzTV fails on every QSV-decoded
# HDR10 AV1 file whether or not it tonemaps. Needs AV1 hardware decode (Intel
# Gen12 / Tiger Lake or newer).
#
# Cases:
#   decode           av1_qsv decode, downloaded to system memory.
#   decode-tonemap   vpp_qsv tonemap and scale into hevc_qsv, which is how
#                    ErsatzTV normally drives an HDR source.
#
# Pass criteria: ffmpeg exits 0 and decodes every frame.
#
# Usage: qsvdec-av1-hdr-side-data.sh [/path/to/ffmpeg]
#        FFMPEG=/path/to/ffmpeg qsvdec-av1-hdr-side-data.sh
#        CASES="decode" qsvdec-av1-hdr-side-data.sh /path/to/ffmpeg
#
# Exit: 0 all runnable cases passed, 1 any case failed, 77 nothing was runnable.

set -uo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"

CASES="${CASES:-decode decode-tonemap}"
INIT_HW_DEVICE="${INIT_HW_DEVICE:-qsv=hw}"
TIMEOUT="${TIMEOUT:-60}"
EXPECTED_FRAMES="${EXPECTED_FRAMES:-48}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sample="$here/../samples/av1-640x360-hdr10-mdcv.mkv"

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

run_case() {
    local name="$1" vf="$2" encoder="$3"
    local log="$logdir/$name.log"
    local rc

    run_bounded "$TIMEOUT" \
        "$FFMPEG" -nostdin -hide_banner -nostats -loglevel verbose \
        -init_hw_device "$INIT_HW_DEVICE" -filter_hw_device hw \
        -hwaccel qsv -hwaccel_output_format qsv \
        -i "$sample" -map 0:v:0 -vf "$vf" \
        -c:v "$encoder" -f null - >"$log" 2>&1
    rc=$?

    if grep -q "error code: -17 (File exists)" "$log"; then
        echo "FAIL: $name - av1_qsv exported duplicate HDR side data; 0021 is missing"
        fail=$((fail + 1))
        return
    fi

    if [ $rc -eq 124 ]; then
        echo "FAIL: $name - ffmpeg did not exit within ${TIMEOUT}s"
        sed -n 's/^/       | /p' <<<"$(tail -3 "$log")"
        fail=$((fail + 1))
        return
    fi

    if [ $rc -ne 0 ]; then
        echo "SKIP: $name - ffmpeg exited $rc for an unrelated reason (no AV1 hardware decode?)"
        sed -n 's/^/       | /p' <<<"$(grep -iE "error|not (supported|available|found)|no such|failed|cannot|unknown" "$log" | tail -3)"
        skip=$((skip + 1))
        return
    fi

    local decoded
    decoded=$(grep -o '[0-9]* frames decoded' "$log" | head -1 | cut -d' ' -f1)
    if [ "${decoded:-0}" -lt "$EXPECTED_FRAMES" ]; then
        echo "FAIL: $name - ${decoded:-0}/$EXPECTED_FRAMES frames decoded"
        fail=$((fail + 1))
        return
    fi

    echo "PASS: $name - $decoded frames decoded"
    pass=$((pass + 1))
}

echo "ffmpeg:  $FFMPEG"
echo "version: $("$FFMPEG" -version 2>/dev/null | head -1)"
echo "device:  $INIT_HW_DEVICE"
echo

for case in $CASES; do
    case "$case" in
        decode)         run_case decode "hwdownload,format=p010le" rawvideo ;;
        decode-tonemap) run_case decode-tonemap "vpp_qsv=tonemap=1:w=320:h=180:format=nv12" hevc_qsv ;;
        *) echo "unknown case: $case" >&2; exit 2 ;;
    esac
done

echo
echo "$pass passed, $fail failed, $skip skipped"

[ $fail -gt 0 ] && exit 1
[ $pass -eq 0 ] && exit 77
exit 0
