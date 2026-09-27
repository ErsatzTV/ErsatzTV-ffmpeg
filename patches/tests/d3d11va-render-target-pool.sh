#!/usr/bin/env bash
#
# Reproducer for
#   0003-avutil-hwcontext_d3d11va-restore-render-target-array-restriction.patch
#   0004-avutil-hwcontext_d3d11va-only-clamp-pool-size-for-array-textures.patch
#
# Windows/QSV only: both patches touch libavutil/hwcontext_d3d11va.c, which is
# reached because qsv_get_d3d11va_bind_flags() maps every QSV pool that is not a
# decoder target (hwupload's MFX_MEMTYPE_VIDEO_MEMORY_PROCESSOR_TARGET, vpp_qsv's
# MFX_MEMTYPE_FROM_VPPOUT) to D3D11_BIND_RENDER_TARGET. On Linux the QSV child
# device is VAAPI and none of this code runs.
#
# Two cases, chosen so that they bisect the two patches:
#
#   render-target-array   pool of exactly MAX_ARRAY_SIZE (64) surfaces.
#                         ID3D11Device_CreateTexture2D() cannot allocate an array
#                         texture with D3D11_BIND_RENDER_TARGET and ArraySize > 2;
#                         it returns E_INVALIDARG (0x80070057). 0003 restores the
#                         fall-through to per-frame single textures.
#                         No clamping is involved at exactly 64, so this case is
#                         unaffected by 0004 and isolates 0003.
#
#   oversized-pool        pool of 66 surfaces, above MAX_ARRAY_SIZE.
#                         Upstream clamps ctx->initial_pool_size to 64 before the
#                         branch, which also shrinks pools that never allocate an
#                         array. The parent QSV frames context has already sized
#                         its own surface array from that same field, so it keeps
#                         66 while the d3d11va child gets 64, and the two desync:
#                         "Error synchronizing the operation", then ffmpeg HANGS.
#                         0004 moves the clamp inside the array branch. Requires
#                         0003 as well, so it is the strictly stronger case.
#
# Build-state matrix (all three measured, see the manifests' last_verified):
#
#                        render-target-array   oversized-pool
#   unpatched            E_INVALIDARG          E_INVALIDARG
#   0003 only            pass                  desync + hang
#   0003 + 0004          pass                  pass
#
# No sample file: the bug is in pool construction, not decoding, so a synthetic
# lavfi source is enough and keeps the reproducer dependency-free.
#
# NOTE ON extra_hw_frames: this is the only remaining coverage of these patches.
# ErsatzTV's own pipeline no longer passes extra_hw_frames on QSV hwupload (it
# forces a fixed surface pool, which breaks the encoder across a filter graph
# reinit), so nothing in the ffpipeline test suite builds a pool this large any
# more. Do not "simplify" this reproducer by dropping extra_hw_frames.
#
# Usage: d3d11va-render-target-pool.sh [/path/to/ffmpeg]
#        FFMPEG=/path/to/ffmpeg d3d11va-render-target-pool.sh
#        CASES="oversized-pool" d3d11va-render-target-pool.sh /path/to/ffmpeg
#        INIT_HW_DEVICE="qsv=hw:hw_any,child_device=1" d3d11va-render-target-pool.sh
#
# Exit: 0 all runnable cases passed, 1 any case failed, 77 nothing was runnable.

set -uo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"

CASES="${CASES:-render-target-array oversized-pool}"
INIT_HW_DEVICE="${INIT_HW_DEVICE:-qsv=hw}"
ENCODER="${ENCODER:-h264_qsv}"
SIZE="${SIZE:-1280x720}"

# extra_hw_frames values, chosen relative to MAX_ARRAY_SIZE (64) in
# hwcontext_d3d11va.c. vf_hwupload builds the pool as 2 + extra_hw_frames.
#   62 -> 64 surfaces, exactly MAX_ARRAY_SIZE, no clamp
#   64 -> 66 surfaces, above MAX_ARRAY_SIZE, clamped upstream
# Anything below ~20 exhausts the pool on its own ("Failed to allocate frame to
# upload to") and would fail for an unrelated reason, so do not lower these.
EHF_AT_LIMIT="${EHF_AT_LIMIT:-62}"
EHF_OVER_LIMIT="${EHF_OVER_LIMIT:-64}"

# The oversized-pool case hangs on a 0003-only build rather than exiting, so
# every run is bounded.
TIMEOUT="${TIMEOUT:-60}"

logdir="$(mktemp -d)"
trap 'rm -rf "$logdir"' EXIT

if ! "$FFMPEG" -version >/dev/null 2>&1; then
    echo "ERROR: cannot run ffmpeg: $FFMPEG" >&2
    exit 2
fi

pass=0; fail=0; skip=0

# timeout(1) is present in Git Bash and on Linux, but fall back to a poll loop so
# the reproducer does not silently hang if it is missing.
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

# A QSV pool of $2 surfaces (2 + extra_hw_frames), uploaded and handed to the
# hardware encoder. hwupload is what creates the D3D11 texture, so the failure
# happens while the filter graph is being configured.
run_pool_case() {
    local name="$1" ehf="$2"
    local log="$logdir/$name.log"
    local rc

    run_bounded "$TIMEOUT" \
        "$FFMPEG" -nostdin -hide_banner -nostats -loglevel info \
        -init_hw_device "$INIT_HW_DEVICE" -filter_hw_device hw \
        -f lavfi -i "testsrc2=size=$SIZE:rate=30:duration=1" \
        -vf "format=nv12,hwupload=extra_hw_frames=$ehf" \
        -c:v "$ENCODER" -f null - >"$log" 2>&1
    rc=$?

    if grep -q "Could not create the texture (80070057)" "$log"; then
        echo "FAIL: $name - CreateTexture2D rejected BIND_RENDER_TARGET with ArraySize > 2 (E_INVALIDARG); 0003 is missing"
        fail=$((fail + 1))
        return
    fi

    if grep -q "Error synchronizing the operation" "$log"; then
        echo "FAIL: $name - parent QSV pool ($((2 + ehf)) surfaces) desynced from the clamped d3d11va child (64); 0004 is missing"
        fail=$((fail + 1))
        return
    fi

    if [ $rc -eq 124 ]; then
        echo "FAIL: $name - ffmpeg did not exit within ${TIMEOUT}s"
        sed -n 's/^/       | /p' <<<"$(tail -3 "$log")"
        fail=$((fail + 1))
        return
    fi

    # Anything else non-zero is not this bug: no QSV device, encoder not built
    # in, lavfi missing. Skip rather than fail so the script is safe to run on a
    # host without Intel graphics.
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

    echo "PASS: $name - pool of $((2 + ehf)) surfaces built and encoded"
    pass=$((pass + 1))
}

echo "ffmpeg:  $FFMPEG"
echo "version: $("$FFMPEG" -version 2>/dev/null | head -1)"
echo "device:  $INIT_HW_DEVICE"
echo

for case in $CASES; do
    case "$case" in
        render-target-array) run_pool_case render-target-array "$EHF_AT_LIMIT" ;;
        oversized-pool)      run_pool_case oversized-pool      "$EHF_OVER_LIMIT" ;;
        *) echo "unknown case: $case" >&2; exit 2 ;;
    esac
done

echo
echo "$pass passed, $fail failed, $skip skipped"

[ $fail -gt 0 ] && exit 1
[ $pass -eq 0 ] && exit 77
exit 0
