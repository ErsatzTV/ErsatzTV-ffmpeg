#!/usr/bin/env bash
#
# Reproducer for
#   0005-vulkan-cuda-export-fix.patch
#
# Windows/NVIDIA only. The bug is in platform-neutral code, but stock n8.1.2
# passes on Linux NVIDIA - the Linux driver tolerates the non-exportable memory
# described below - so a Linux run passes with or without the patch and proves
# nothing. It self-skips without an NVIDIA device, but not on Linux.
#
# Vulkan frames handed to CUDA (hwupload_cuda from a Vulkan frames
# context) are imported with cuImportExternalMemory(). That only works if the
# VkDeviceMemory was allocated exportable, and hwcontext_vulkan decides that in
# try_export_flags() by asking GetPhysicalDeviceImageFormatProperties2() whether
# the image can be exported. Upstream n8.1.2 asks about the wrong image:
#
#   - it queries the sw_format's multiplane VkFormat (G8_B8R8_2PLANE_420_UNORM
#     for nv12), but vulkan_frames_init() has already picked the per-plane
#     fallback (R8_UNORM + R8G8_UNORM) into hwctx->format[] because the
#     multiplane format cannot be a STORAGE image on NVIDIA;
#   - it queries with VK_IMAGE_CREATE_ALIAS_BIT instead of hwctx->img_flags.
#
# The query for the multiplane format fails, no export handle type is set, the
# memory is allocated non-exportable, and CUDA rejects the handle:
#
#   cu->cuImportExternalMemory(...) failed -> CUDA_ERROR_INVALID_VALUE
#
# after which ffmpeg crashes on the error path (0xc0000005 on Windows).
#
# Cases:
#
#   nv12        format=nv12,hwupload,hwupload_cuda,hwdownload - the 8-bit layout
#               ErsatzTV feeds nvenc after libplacebo. Output must be bit-exact
#               with the software frames.
#   p010        same, 10-bit.
#   libplacebo  p010 -> libplacebo=format=nv12 -> hwupload_cuda: the shape of
#               ErsatzTV's CUDA HDR tonemap pipeline (ffpipeline cuda.rs
#               tonemap_hdr). Self-skips if libplacebo is not built in.
#
# The hash comparison is there because upstream's fix (0baa71b53c) describes
# the same bug as "broken CUDA hwaccel output", not an error. A driver that
# lets non-exportable memory through must still fail this reproducer.
#
# Deliberately NOT a case: packed formats (bgra, ...). They fail on the patched
# build too, at cuMemcpy2DAsync, because vulkan_export_to_cuda() computes
# NumChannels only for planar/semi-planar layouts. That is a separate upstream
# fix (927f205eb8 + b4b30ff8fd) which ErsatzTV does not need.
#
# No sample file: a synthetic lavfi source uploaded to Vulkan reaches the same
# export path as the decoder in ErsatzTV's pipeline.
#
# Usage: vulkan-cuda-export.sh [/path/to/ffmpeg]
#        FFMPEG=/path/to/ffmpeg vulkan-cuda-export.sh
#        CASES="nv12 libplacebo" vulkan-cuda-export.sh /path/to/ffmpeg
#
# Exit: 0 all runnable cases passed, 1 any case failed, 77 nothing was runnable.

set -uo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"

CASES="${CASES:-nv12 p010 libplacebo}"
# vk@nv derives the Vulkan device from the CUDA one, so both land on the same
# GPU even on a multi-GPU host.
HW_DEVICES="${HW_DEVICES:--init_hw_device cuda=nv -init_hw_device vulkan=vk@nv -filter_hw_device vk}"
SIZE="${SIZE:-1920x1080}"
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
    "$@"
}

# $1 case name, $2 filter chain, $3 software-only filter chain to compare
# against (empty to skip the comparison).
run_export_case() {
    local name="$1" vf="$2" ref_vf="$3"
    local log="$logdir/$name.log"
    local rc hw_md5 sw_md5

    # shellcheck disable=SC2086
    run_bounded "$TIMEOUT" \
        "$FFMPEG" -nostdin -hide_banner -nostats -loglevel error \
        $HW_DEVICES \
        -f lavfi -i "testsrc2=size=$SIZE:rate=24:duration=1" \
        -vf "$vf" -f md5 - >"$log" 2>&1
    rc=$?

    if grep -q "cuImportExternalMemory" "$log"; then
        echo "FAIL: $name - CUDA rejected the Vulkan memory handle; frames were allocated non-exportable (0005 is missing)"
        sed -n 's/^/       | /p' <<<"$(grep cuImportExternalMemory "$log" | head -1)"
        fail=$((fail + 1))
        return
    fi

    if grep -q "Unable to export the image" "$log"; then
        echo "FAIL: $name - Vulkan refused to export the frame memory (0005 is missing)"
        fail=$((fail + 1))
        return
    fi

    if [ $rc -eq 124 ]; then
        echo "FAIL: $name - ffmpeg did not exit within ${TIMEOUT}s"
        fail=$((fail + 1))
        return
    fi

    # Anything else non-zero is not this bug: no NVIDIA GPU, no Vulkan driver,
    # CUDA or libplacebo not built in. Skip rather than fail so the script is
    # safe to run anywhere.
    if [ $rc -ne 0 ]; then
        echo "SKIP: $name - ffmpeg exited $rc for an unrelated reason"
        sed -n 's/^/       | /p' <<<"$(tail -3 "$log")"
        skip=$((skip + 1))
        return
    fi

    hw_md5="$(grep -o 'MD5=[0-9a-f]*' "$log")"
    if [ -z "$hw_md5" ]; then
        echo "SKIP: $name - ffmpeg produced no output"
        skip=$((skip + 1))
        return
    fi

    if [ -n "$ref_vf" ]; then
        sw_md5="$("$FFMPEG" -nostdin -hide_banner -nostats -loglevel error \
            -f lavfi -i "testsrc2=size=$SIZE:rate=24:duration=1" \
            -vf "$ref_vf" -f md5 - 2>/dev/null)"
        if [ "$hw_md5" != "$sw_md5" ]; then
            echo "FAIL: $name - Vulkan -> CUDA round trip is not bit-exact ($hw_md5, software $sw_md5)"
            fail=$((fail + 1))
            return
        fi
        echo "PASS: $name - imported into CUDA, bit-exact with software"
    else
        echo "PASS: $name - imported into CUDA"
    fi
    pass=$((pass + 1))
}

echo "ffmpeg:  $FFMPEG"
echo "version: $("$FFMPEG" -version 2>/dev/null | head -1)"
echo "devices: $HW_DEVICES"
echo

for case in $CASES; do
    case "$case" in
        nv12)
            run_export_case nv12 \
                "format=nv12,hwupload,hwupload_cuda,hwdownload,format=nv12" \
                "format=nv12" ;;
        p010)
            run_export_case p010 \
                "format=p010,hwupload,hwupload_cuda,hwdownload,format=p010" \
                "format=p010" ;;
        libplacebo)
            if ! "$FFMPEG" -hide_banner -filters 2>/dev/null | grep -q " libplacebo "; then
                echo "SKIP: libplacebo - filter not built in"
                skip=$((skip + 1))
                continue
            fi
            # libplacebo converts on the GPU, so there is no software
            # reference to compare against; the import is what matters.
            run_export_case libplacebo \
                "format=p010,hwupload,libplacebo=format=nv12,hwupload_cuda,hwdownload,format=nv12" \
                "" ;;
        *) echo "unknown case: $case" >&2; exit 2 ;;
    esac
done

echo
echo "$pass passed, $fail failed, $skip skipped"

[ $fail -gt 0 ] && exit 1
[ $pass -eq 0 ] && exit 77
exit 0
