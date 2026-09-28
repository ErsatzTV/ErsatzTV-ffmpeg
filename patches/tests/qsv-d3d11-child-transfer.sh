#!/usr/bin/env bash
#
# Reproducer for
#   0015-avutil-hwcontext_qsv-transfer-d3d11-frames-through-the-child-context.patch
#
# Windows/QSV. hwcontext_qsv copies frames between system and video memory
# (hwupload, hwdownload) with an internal VPP session per direction. On legacy
# Media SDK runtimes (verified on API 1.20, Haswell) one of the first one or two
# transfers of a process can fail with MFX_ERR_DEVICE_FAILED:
#
#   [AVHWFramesContext] Error synchronizing the operation: -17
#   [hwdownload] Failed to download frame: -1313558101.
#
# The session is unusable after that, so a retry does not help. The failure is
# intermittent and grows with the frame size: almost never at 720p, about half
# of the runs at 1440p. Later transfers in a run that got past the first two
# never fail. The patch copies d3d11 frames through the child d3d11va frames
# context instead, so the runtime does not do the copy.
#
# Each stability case runs RUNS times (default 20) and fails if any run shows
# the transfer error. Most runs pass without the patch, so a small RUNS value
# can miss it.
#
# The exact-* cases check that a round trip returns the same pixels as the
# software path. They cover a frame height that is not a multiple of 16
# (1080), where hwcontext_qsv otherwise downloads into a realigned copy.
#
# Linux VA-API frames do not take the new path (the child device is vaapi), so
# there the script only shows that the runtime's own transfers work.
#
# Cases, all synthetic (lavfi) except decode-download, which encodes its own
# 1440p H.264 sample with libx264 first:
#
#   roundtrip      2560x1440 hwupload -> hwdownload.
#   vpp-download   hwupload -> vpp_qsv 2560x1440 -> hwdownload.
#   decode-download  h264_qsv 1440p decode -> hwdownload.
#   exact-1080p    1920x1080 round trip compared with software, bit exact.
#   exact-720p     1280x720 round trip compared with software, bit exact.
#
# Usage: qsv-d3d11-child-transfer.sh [/path/to/ffmpeg]
#        FFMPEG=/path/to/ffmpeg qsv-d3d11-child-transfer.sh
#        RUNS=50 CASES="roundtrip" qsv-d3d11-child-transfer.sh /path/to/ffmpeg
#        INIT_HW_DEVICE="qsv=hw,child_device_type=d3d11va" qsv-d3d11-child-transfer.sh
#
# Exit: 0 all runnable cases passed, 1 any case failed, 77 nothing was runnable.

set -uo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"

CASES="${CASES:-roundtrip vpp-download decode-download exact-1080p exact-720p}"
INIT_HW_DEVICE="${INIT_HW_DEVICE:-qsv=hw}"
RUNS="${RUNS:-20}"
TIMEOUT="${TIMEOUT:-60}"

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

TRANSFER_ERROR="Error synchronizing the operation|Error (downloading|uploading) the surface"

# $1 log file, remaining args: ffmpeg options after the device setup
ffmpeg_hw() {
    local log="$1"; shift
    run_bounded "$TIMEOUT" \
        "$FFMPEG" -nostdin -hide_banner -nostats -loglevel info \
        -init_hw_device "$INIT_HW_DEVICE" -filter_hw_device hw \
        "$@" >"$log" 2>&1
}

skip_case() {
    local name="$1" log="$2" why="$3"
    echo "SKIP: $name - $why"
    sed -n 's/^/       | /p' <<<"$(grep -iE "error|not (supported|available|found)|no such|failed|cannot|unknown" "$log" | tail -3)"
    skip=$((skip + 1))
}

# $1 case name, remaining args: the input and filter options for ffmpeg
run_stability() {
    local name="$1"; shift
    local failed=0 ok=0 rc i log

    for i in $(seq "$RUNS"); do
        log="$logdir/$name.$i.log"
        ffmpeg_hw "$log" "$@" -f null -
        rc=$?

        if grep -qE "$TRANSFER_ERROR" "$log"; then
            failed=$((failed + 1))
            [ $failed -eq 1 ] && cp "$log" "$logdir/$name.fail.log"
        elif [ $rc -eq 124 ]; then
            echo "FAIL: $name - ffmpeg did not exit within ${TIMEOUT}s (run $i)"
            sed -n 's/^/       | /p' <<<"$(tail -3 "$log")"
            fail=$((fail + 1))
            return
        elif [ $rc -ne 0 ]; then
            # not this bug: no QSV device, runtime not found, decoder missing.
            # skip rather than fail so the script is safe on other hosts
            skip_case "$name" "$log" "ffmpeg exited $rc for an unrelated reason"
            return
        else
            ok=$((ok + 1))
        fi
    done

    if [ $failed -gt 0 ]; then
        echo "FAIL: $name - $failed/$RUNS runs failed a system/video memory transfer; 0015 is missing"
        sed -n 's/^/       | /p' <<<"$(grep -E "$TRANSFER_ERROR|Failed to (up|down)load" "$logdir/$name.fail.log" | head -2)"
        fail=$((fail + 1))
        return
    fi

    echo "PASS: $name ($ok/$RUNS runs)"
    pass=$((pass + 1))
}

# pixel hashes of the frames, one per line, without timestamps
frame_hashes() {
    grep -v '^#' "$1" | awk -F, '{gsub(/ /, "", $6); print $6}'
}

# $1 case name, $2 size
run_exact() {
    local name="$1" size="$2"
    local src="testsrc2=size=$size:rate=24"
    local log="$logdir/$name.log" ref="$logdir/$name.ref" out="$logdir/$name.md5"
    local rc

    if ! "$FFMPEG" -nostdin -hide_banner -loglevel error -f lavfi -i "$src" \
            -vf format=nv12 -frames:v 10 -f framemd5 "$ref" 2>"$log"; then
        skip_case "$name" "$log" "software reference failed"
        return
    fi

    ffmpeg_hw "$log" -f lavfi -i "$src" -vf "format=nv12,hwupload,hwdownload,format=nv12" \
        -frames:v 10 -f framemd5 "$out"
    rc=$?

    if grep -qE "$TRANSFER_ERROR" "$log"; then
        echo "FAIL: $name - a system/video memory transfer failed; 0015 is missing"
        fail=$((fail + 1))
        return
    fi

    if [ $rc -ne 0 ]; then
        skip_case "$name" "$log" "ffmpeg exited $rc for an unrelated reason"
        return
    fi

    if [ "$(frame_hashes "$ref")" != "$(frame_hashes "$out")" ]; then
        echo "FAIL: $name - round trip differs from the software frames"
        fail=$((fail + 1))
        return
    fi

    echo "PASS: $name"
    pass=$((pass + 1))
}

echo "ffmpeg:  $FFMPEG"
echo "version: $("$FFMPEG" -version 2>/dev/null | head -1)"
echo "device:  $INIT_HW_DEVICE"
echo "runs:    $RUNS"
echo

for case in $CASES; do
    case "$case" in
        roundtrip)
            run_stability roundtrip -f lavfi -i "color=black:size=2560x1440:rate=24" \
                -vf "format=nv12,hwupload,hwdownload,format=nv12" -frames:v 5 ;;
        vpp-download)
            run_stability vpp-download -f lavfi -i "color=black:size=854x480:rate=24" \
                -vf "format=nv12,hwupload,vpp_qsv=w=2560:h=1440,hwdownload,format=nv12" -frames:v 5 ;;
        decode-download)
            sample="$logdir/1440p.mp4"
            if ! "$FFMPEG" -nostdin -hide_banner -loglevel error \
                    -f lavfi -i "testsrc2=size=2560x1440:rate=24:duration=1" \
                    -c:v libx264 -pix_fmt yuv420p "$sample" 2>"$logdir/sample.log"; then
                skip_case decode-download "$logdir/sample.log" "cannot encode the H.264 sample"
                continue
            fi
            run_stability decode-download -hwaccel qsv -hwaccel_output_format qsv -i "$sample" \
                -vf "hwdownload,format=nv12" -frames:v 5 ;;
        exact-1080p)
            run_exact exact-1080p 1920x1080 ;;
        exact-720p)
            run_exact exact-720p 1280x720 ;;
        *) echo "unknown case: $case" >&2; exit 2 ;;
    esac
done

echo
echo "$pass passed, $fail failed, $skip skipped"

[ $fail -gt 0 ] && exit 1
[ $pass -eq 0 ] && exit 77
exit 0
