#!/usr/bin/env bash
#
# Reproducer for
#   0029-avcodec-amfdec-fix-duplicate-hdr-side-data.patch
#
# The sample is HDR10 AV1 in Matroska with mastering display and content light
# metadata both in the bitstream and in the container. av1_amf adds the
# runtime's copy to frames that already carry the container's, and the filter
# graph refuses the duplicate while it configures its links:
#
#   [vf#0:0] Task finished with error code: -17 (File exists)
#
# Needs AV1 hardware decode (RDNA2 or newer); other GPUs skip.
#
# Any filter triggers it, even none at all, since fftools copies the side
# data while it sets up the output. The cases keep the frames on the GPU, so
# 0030's frames context bug (hwdownload and vpp_amf fail on 10-bit AV1) does
# not affect them.
#
# Cases:
#   decode       av1_amf decode into showinfo. Also checks the first frame
#                carries one mastering display and one content light entry
#                with the same values as libdav1d's decode. The runtime's
#                AV1 values need their own units and primaries order, and
#                amfdec copied max_luminance into min_luminance.
#   passthrough  av1_amf decode with no filter.
#
# Pass criteria: ffmpeg exits 0 and decodes every frame.
#
# Point INIT_HW_DEVICE at the AMD adapter on multi-GPU Windows boxes, e.g.
#   INIT_HW_DEVICE="-init_hw_device d3d11va=dx:2 -init_hw_device amf=hw@dx"
#
# Usage: amfdec-hdr-side-data.sh [/path/to/ffmpeg]
#        FFMPEG=/path/to/ffmpeg amfdec-hdr-side-data.sh
#        CASES="decode" amfdec-hdr-side-data.sh /path/to/ffmpeg
#
# Exit: 0 all runnable cases passed, 1 any case failed, 77 nothing was runnable.

set -uo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"

CASES="${CASES:-decode passthrough}"
INIT_HW_DEVICE="${INIT_HW_DEVICE:--init_hw_device amf=hw}"
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

if ! "$FFMPEG" -hide_banner -decoders 2>/dev/null | grep -E '^ V[^ ]* +av1_amf ' >/dev/null; then
    echo "this ffmpeg has no av1_amf decoder; nothing to test" >&2
    exit 77
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

side_data_lines() {
    # showinfo prints each side data entry of the first frame on its own line
    awk '/Parsed_showinfo/ && /n: *0 /{f=1; next} f && /Parsed_showinfo/ && /n: *1 /{exit} f' "$1" |
        grep -E "side data - (Mastering display|Content light level) metadata" | sed 's/.*side data - //'
}

check_metadata() {
    local log="$1" ref="$logdir/reference.log"
    local got want

    got="$(side_data_lines "$log")"
    if [ "$(grep -c "^Mastering display" <<<"$got")" -ne 1 ] || [ "$(grep -c "^Content light" <<<"$got")" -ne 1 ]; then
        echo "metadata: first frame should carry one mastering display and one content light entry:"
        printf '%s\n' "$got" | sed 's/^/       | /'
        return 1
    fi

    if ! run_bounded "$TIMEOUT" "$FFMPEG" -nostdin -hide_banner -nostats -loglevel verbose -c:v libdav1d \
            -i "$sample" -map 0:v:0 -frames:v 2 -vf showinfo -f null - >"$ref" 2>&1; then
        echo "metadata: one entry each (no libdav1d reference to compare values)"
        return 0
    fi
    want="$(side_data_lines "$ref")"
    if [ "$got" != "$want" ]; then
        echo "metadata: values differ from libdav1d:"
        printf '%s\n' "$got" | sed 's/^/       | av1_amf  /'
        printf '%s\n' "$want" | sed 's/^/       | libdav1d /'
        return 1
    fi
    echo "metadata: matches libdav1d"
}

run_case() {
    local name="$1"; shift
    local log="$logdir/$name.log"
    local rc

    # shellcheck disable=SC2086
    run_bounded "$TIMEOUT" \
        "$FFMPEG" -nostdin -hide_banner -nostats -loglevel verbose \
        $INIT_HW_DEVICE -filter_hw_device hw \
        -hwaccel amf -hwaccel_output_format amf \
        -i "$sample" -map 0:v:0 "$@" -f null - >"$log" 2>&1
    rc=$?

    if grep -q "error code: -17 (File exists)" "$log"; then
        echo "FAIL: $name - av1_amf exported duplicate HDR side data; 0029 is missing"
        fail=$((fail + 1))
        return
    fi

    if [ $rc -eq 124 ]; then
        echo "FAIL: $name - ffmpeg did not exit within ${TIMEOUT}s"
        sed -n 's/^/       | /p' <<<"$(tail -3 "$log")"
        fail=$((fail + 1))
        return
    fi

    if ! grep -q "dec:av1_amf" "$log" || grep -q "Error while opening decoder" "$log"; then
        echo "SKIP: $name - ffmpeg did not decode with av1_amf (no AV1 hardware decode?)"
        sed -n 's/^/       | /p' <<<"$(grep -iE "error|not (supported|available|found)|no such|failed|cannot|unknown" "$log" | tail -3)"
        skip=$((skip + 1))
        return
    fi

    if [ $rc -ne 0 ]; then
        echo "FAIL: $name - ffmpeg exited $rc"
        sed -n 's/^/       | /p' <<<"$(grep -iE "error|failed" "$log" | tail -3)"
        fail=$((fail + 1))
        return
    fi

    local decoded
    decoded=$(grep -o '[0-9]* frames decoded' "$log" | head -1 | cut -d' ' -f1)
    if [ "${decoded:-0}" -lt "$EXPECTED_FRAMES" ]; then
        echo "FAIL: $name - ${decoded:-0}/$EXPECTED_FRAMES frames decoded"
        fail=$((fail + 1))
        return
    fi

    if [ "$name" = decode ]; then
        local result
        if ! result="$(check_metadata "$log")"; then
            echo "FAIL: $name - $result"
            fail=$((fail + 1))
            return
        fi
        echo "PASS: $name - $decoded frames decoded; $result"
    else
        echo "PASS: $name - $decoded frames decoded"
    fi
    pass=$((pass + 1))
}

echo "ffmpeg:  $FFMPEG"
echo "version: $("$FFMPEG" -version 2>/dev/null | head -1)"
echo "device:  $INIT_HW_DEVICE"
echo

for case in $CASES; do
    case "$case" in
        decode)      run_case decode -vf showinfo ;;
        passthrough) run_case passthrough ;;
        *) echo "unknown case: $case" >&2; exit 2 ;;
    esac
done

echo
echo "$pass passed, $fail failed, $skip skipped"

[ $fail -gt 0 ] && exit 1
[ $pass -eq 0 ] && exit 77
exit 0
