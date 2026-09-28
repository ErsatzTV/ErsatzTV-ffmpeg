#!/usr/bin/env bash
#
# Reproducer for
#   0013-lavc-qsvdec-keep-a-fixed-frame-pool-across-a-parameter-change.patch
#
# The sample changes its SPS mid-stream without changing size or format. The
# QSV decoder answers MFX_ERR_INCOMPATIBLE_VIDEO_PARAM and reinitialises, and
# upstream always allocates a new frame pool there because ff_get_format()
# drops avctx->hw_frames_ctx. ffmpeg then reconfigures the filter graph
# ("hwaccel changed"), and the already-open encoder (and any vpp_qsv) cannot
# take surfaces from the new pool:
#
#   [h264_qsv] Error submitting the frame for encoding.
#   Error encoding a frame: Internal bug, should not have happened
#
# Only FIXED pools are affected: legacy Media SDK runtimes (API < 2.9, i.e.
# Gen9-Gen11 without a VPL runtime) and D3D9. On a oneVPL 2.9+ runtime the
# pools are dynamic, both builds pass, and the reproducer cannot tell them
# apart - run it on a legacy-runtime host to verify the patch.
#
# Cases:
#   decode-encode        hevc/h264 qsv decode straight into h264_qsv.
#   decode-vpp-encode    the same with a vpp_qsv scale in between, which is
#                        how ErsatzTV normally drives it.
#
# Pass criteria: ffmpeg exits 0 and the filter graph was not reconfigured for
# a new hw frames context. The second check matters on dynamic runtimes too:
# the patch leaves them alone, so "hwaccel changed" still appears there and
# the case is reported as unaffected rather than passed.
#
# Usage: qsvdec-reinit-fixed-pool.sh [/path/to/ffmpeg]
#        FFMPEG=/path/to/ffmpeg qsvdec-reinit-fixed-pool.sh
#        CASES="decode-encode" qsvdec-reinit-fixed-pool.sh /path/to/ffmpeg
#
# Exit: 0 all runnable cases passed, 1 any case failed, 77 nothing was runnable.

set -uo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"

CASES="${CASES:-decode-encode decode-vpp-encode}"
INIT_HW_DEVICE="${INIT_HW_DEVICE:-qsv=hw}"
ENCODER="${ENCODER:-h264_qsv}"
TIMEOUT="${TIMEOUT:-60}"
# every frame in the sample must come out; see the pool-starvation check
EXPECTED_FRAMES="${EXPECTED_FRAMES:-45}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sample="$here/../samples/h264-640x480-sps-change.ts"

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
    local name="$1" vf="$2"
    local log="$logdir/$name.log"
    local rc
    local vf_args=()
    [ -n "$vf" ] && vf_args=(-vf "$vf")

    run_bounded "$TIMEOUT" \
        "$FFMPEG" -nostdin -hide_banner -nostats -loglevel verbose \
        -init_hw_device "$INIT_HW_DEVICE" -filter_hw_device hw \
        -hwaccel qsv -hwaccel_output_format qsv \
        -i "$sample" -map 0:v:0 "${vf_args[@]}" -noautoscale \
        -c:v "$ENCODER" -f null - >"$log" 2>&1
    rc=$?

    if grep -q "Error encoding a frame: Internal bug" "$log"; then
        echo "FAIL: $name - encoder rejected a surface from the reallocated decoder pool; 0013 is missing"
        fail=$((fail + 1))
        return
    fi

    if [ $rc -eq 124 ]; then
        echo "FAIL: $name - ffmpeg did not exit within ${TIMEOUT}s"
        sed -n 's/^/       | /p' <<<"$(tail -3 "$log")"
        fail=$((fail + 1))
        return
    fi

    # without -noautoscale the rebuilt graph fails earlier, in the auto-inserted
    # scaler, but it is the same replaced pool
    if [ $rc -ne 0 ] && grep -q "hwaccel changed" "$log"; then
        echo "FAIL: $name - the decoder replaced its pool mid-stream and the pipeline could not follow; 0013 is missing"
        sed -n 's/^/       | /p' <<<"$(grep -iE "error" "$log" | tail -2)"
        fail=$((fail + 1))
        return
    fi

    if [ $rc -ne 0 ]; then
        echo "SKIP: $name - ffmpeg exited $rc for an unrelated reason"
        sed -n 's/^/       | /p' <<<"$(grep -iE "error|not (supported|available|found)|no such|failed|cannot|unknown" "$log" | tail -3)"
        skip=$((skip + 1))
        return
    fi

    # a kept pool that is too small starves the decoder instead: ffmpeg still
    # exits 0, but frames are dropped as "Cannot allocate memory" decode errors
    local decoded errors
    decoded=$(grep -o '[0-9]* frames decoded' "$log" | head -1 | cut -d' ' -f1)
    errors=$(grep -o '[0-9]* decode errors' "$log" | head -1 | cut -d' ' -f1)
    if [ "${errors:-0}" -gt 0 ] || [ "${decoded:-0}" -lt "$EXPECTED_FRAMES" ]; then
        echo "FAIL: $name - ${decoded:-0}/$EXPECTED_FRAMES frames decoded, ${errors:-?} decode errors; the kept pool is too small for the new stream"
        sed -n 's/^/       | /p' <<<"$(grep -E "Fixed frame pool|Cannot allocate" "$log" | sort | uniq -c | head -3)"
        fail=$((fail + 1))
        return
    fi

    # the patch logs the first line at verbose; fftools logs the second when
    # the decoder hands it a new pool
    if grep -q "Keeping the fixed frame pool" "$log"; then
        echo "PASS: $name - $(grep -o '[0-9]* frames decoded' "$log" | head -1), fixed pool kept across the parameter change"
        pass=$((pass + 1))
    elif grep -q "hwaccel changed" "$log"; then
        echo "SKIP: $name - the decoder replaced its pool and the encoder coped; this runtime uses dynamic pools and is unaffected"
        skip=$((skip + 1))
    else
        echo "SKIP: $name - the decoder never reinitialised, so the sample did not exercise the bug"
        skip=$((skip + 1))
    fi
}

echo "ffmpeg:  $FFMPEG"
echo "version: $("$FFMPEG" -version 2>/dev/null | head -1)"
echo "device:  $INIT_HW_DEVICE"
echo

for case in $CASES; do
    case "$case" in
        decode-encode)     run_case decode-encode "" ;;
        decode-vpp-encode) run_case decode-vpp-encode "vpp_qsv=w=1280:h=720" ;;
        *) echo "unknown case: $case" >&2; exit 2 ;;
    esac
done

echo
echo "$pass passed, $fail failed, $skip skipped"

[ $fail -gt 0 ] && exit 1
[ $pass -eq 0 ] && exit 77
exit 0
