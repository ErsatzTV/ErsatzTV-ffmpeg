#!/usr/bin/env bash
#
# Reproducer for
#   0014-qsv-set-the-subresource-index-for-individual-textures-in-get_hdl.patch
#
# Windows/QSV, legacy Media SDK runtime only. Render-target pools (hwupload's
# MFX_MEMTYPE_VIDEO_MEMORY_PROCESSOR_TARGET, vpp_qsv's MFX_MEMTYPE_FROM_VPPOUT)
# are individual D3D11 textures (0003), and hwcontext_qsv gives each surface a
# handle pair whose index is MFX_INFINITE. The frame allocators' get_hdl
# callbacks then copy only the texture and leave the index half of the output
# pair untouched. A legacy runtime (API 1.20 on Haswell) uses that stale value
# as the subresource index, so every VPP pass whose INPUT comes from such a
# pool fails with "Error running VPP: device failed (-17)". The encoder and VPP
# on decoder surfaces (array textures with real indexes) are unaffected.
#
# Linux VA-API with vpl-gpu-rt (verified on Arc) passes every case with or
# without the patch, so a pass there only shows that the patch does no harm.
#
# Cases, all synthetic (lavfi) so no sample file is needed:
#
#   upload-vpp     hwupload -> vpp_qsv scale. VPP input is a hwupload surface.
#   vpp-vpp        hwupload -> vpp_qsv scale -> vpp_qsv scale. The second VPP
#                  reads the first one's output pool.
#   upload-rgb4    bgra hwupload -> vpp_qsv to nv12, the canvas/watermark path.
#   overlay        overlay_qsv of an uploaded bgra canvas onto uploaded nv12.
#
# The fixed-pool runtimes this affects are also the ones that cannot reach
# QSV at all through an unpatched libvpl dispatcher when the Intel GPU is not
# the primary adapter, so run this with a build that has the FFmpeg-Builds
# libvpl patch (native/FFmpeg-Builds/patches/libvpl).
#
# Usage: qsv-get-hdl-subresource-index.sh [/path/to/ffmpeg]
#        FFMPEG=/path/to/ffmpeg qsv-get-hdl-subresource-index.sh
#        CASES="overlay" qsv-get-hdl-subresource-index.sh /path/to/ffmpeg
#        INIT_HW_DEVICE="qsv=hw,child_device_type=d3d11va" qsv-get-hdl-subresource-index.sh
#
# Exit: 0 all runnable cases passed, 1 any case failed, 77 nothing was runnable.

set -uo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"

CASES="${CASES:-upload-vpp vpp-vpp upload-rgb4 overlay}"
INIT_HW_DEVICE="${INIT_HW_DEVICE:-qsv=hw}"
ENCODER="${ENCODER:-h264_qsv}"
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

# $1 case name, remaining args: the input and filter options for ffmpeg
run_case() {
    local name="$1"; shift
    local log="$logdir/$name.log"
    local rc

    run_bounded "$TIMEOUT" \
        "$FFMPEG" -nostdin -hide_banner -nostats -loglevel info \
        -init_hw_device "$INIT_HW_DEVICE" -filter_hw_device hw \
        "$@" -c:v "$ENCODER" -f null - >"$log" 2>&1
    rc=$?

    if grep -q "Error running VPP: device failed (-17)" "$log"; then
        echo "FAIL: $name - VPP rejected a surface from an individual-texture pool (MFX_ERR_DEVICE_FAILED); 0014 is missing"
        fail=$((fail + 1))
        return
    fi

    if [ $rc -eq 124 ]; then
        echo "FAIL: $name - ffmpeg did not exit within ${TIMEOUT}s"
        sed -n 's/^/       | /p' <<<"$(tail -3 "$log")"
        fail=$((fail + 1))
        return
    fi

    # Anything else non-zero is not this bug: no QSV device, a runtime that
    # cannot be found, encoder not built in. Skip rather than fail so the
    # script is safe to run on a host without Intel graphics.
    if [ $rc -ne 0 ]; then
        echo "SKIP: $name - ffmpeg exited $rc for an unrelated reason"
        sed -n 's/^/       | /p' <<<"$(grep -iE "error|not (supported|available|found)|no such|failed|cannot|unknown" "$log" | tail -3)"
        skip=$((skip + 1))
        return
    fi

    if ! grep -q "^Output #0" "$log"; then
        echo "SKIP: $name - ffmpeg produced no output stream"
        skip=$((skip + 1))
        return
    fi

    echo "PASS: $name"
    pass=$((pass + 1))
}

SRC="testsrc2=size=640x480:rate=24:duration=2"

echo "ffmpeg:  $FFMPEG"
echo "version: $("$FFMPEG" -version 2>/dev/null | head -1)"
echo "device:  $INIT_HW_DEVICE"
echo

for case in $CASES; do
    case "$case" in
        upload-vpp)
            run_case upload-vpp -f lavfi -i "$SRC" \
                -vf "format=nv12,hwupload,vpp_qsv=w=1280:h=720" ;;
        vpp-vpp)
            run_case vpp-vpp -f lavfi -i "$SRC" \
                -vf "format=nv12,hwupload,vpp_qsv=w=1280:h=720,vpp_qsv=w=640:h=360" ;;
        upload-rgb4)
            run_case upload-rgb4 -f lavfi -i "$SRC" \
                -vf "format=bgra,hwupload,vpp_qsv=format=nv12" ;;
        overlay)
            run_case overlay -f lavfi -i "$SRC" \
                -f lavfi -i "color=red@0.5:size=320x180:rate=24:duration=2,format=bgra" \
                -filter_complex "[0:v]format=nv12,hwupload[m];[1:v]hwupload[o];[m][o]overlay_qsv=x=0:y=0:eof_action=pass" ;;
        *) echo "unknown case: $case" >&2; exit 2 ;;
    esac
done

echo
echo "$pass passed, $fail failed, $skip skipped"

[ $fail -gt 0 ] && exit 1
[ $pass -eq 0 ] && exit 77
exit 0
