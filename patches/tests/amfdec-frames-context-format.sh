#!/usr/bin/env bash
#
# Reproducer for
#   0030-avcodec-amfdec-re-create-the-frames-context-for-the-decoded-format.patch
#
# amfdec sets up its frames context before the AMF runtime knows the stream's
# bit depth. For 10-bit AV1 it stays NV12 while the surfaces are P010, so:
#
#   [hwdownload] Failed to download frame: -22.
#   [vf#0:0] Error while filtering: Unknown error occurred      (vpp_amf)
#
# The input is the AV1 HDR10 sample remuxed to IVF, which keeps timestamps but
# has no container HDR metadata, so 0029's bug can't mask this one.
# Needs AV1 hardware decode (RDNA2 or newer); other GPUs skip.
#
# Cases:
#   download    av1_amf decode, hwdownload to P010. Every frame must be
#               bit-exact with libdav1d's decode of the same stream.
#   vpp         vpp_amf to SDR NV12 into hevc_amf, which is how ErsatzTV
#               drives an HDR source.
#
# Point INIT_HW_DEVICE at the AMD adapter on multi-GPU Windows boxes, e.g.
#   INIT_HW_DEVICE="-init_hw_device d3d11va=dx:2 -init_hw_device amf=hw@dx"
#
# Usage: amfdec-frames-context-format.sh [/path/to/ffmpeg]
#        FFMPEG=/path/to/ffmpeg amfdec-frames-context-format.sh
#
# Exit: 0 all runnable cases passed, 1 any case failed, 77 nothing was runnable.

set -uo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"

CASES="${CASES:-download vpp}"
INIT_HW_DEVICE="${INIT_HW_DEVICE:--init_hw_device amf=hw}"
TIMEOUT="${TIMEOUT:-60}"
EXPECTED_FRAMES="${EXPECTED_FRAMES:-48}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sample="$here/../samples/av1-640x360-hdr10-mdcv.mkv"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

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

if command -v timeout >/dev/null 2>&1; then
    BOUND=(timeout "$TIMEOUT")
else
    BOUND=()
fi

ivf="$work/sample.ivf"
if ! "${BOUND[@]}" "$FFMPEG" -nostdin -hide_banner -loglevel error -i "$sample" -map 0:v:0 -c copy -f ivf "$ivf"; then
    echo "ERROR: cannot remux the sample to IVF" >&2
    exit 2
fi

pass=0; fail=0; skip=0

# shellcheck disable=SC2086
run_amf() {
    local log="$1"; shift
    "${BOUND[@]}" "$FFMPEG" -nostdin -hide_banner -nostats -loglevel verbose \
        $INIT_HW_DEVICE -filter_hw_device hw \
        -hwaccel amf -hwaccel_output_format amf \
        -i "$ivf" -map 0:v:0 "$@" >"$log" 2>&1
}

classify() {
    local name="$1" rc="$2" log="$3"
    if [ "$rc" -eq 124 ]; then
        echo "FAIL: $name - ffmpeg did not exit within ${TIMEOUT}s"
        fail=$((fail + 1)); return 1
    fi
    if grep -qE "Failed to download frame|Error while filtering" "$log"; then
        echo "FAIL: $name - $(grep -m1 -oE "Failed to download frame.*|Error while filtering.*" "$log"); 0030 is missing"
        fail=$((fail + 1)); return 1
    fi
    if [ "$rc" -ne 0 ] || ! grep -q "dec:av1_amf" "$log" || grep -q "Error while opening decoder" "$log"; then
        echo "SKIP: $name - ffmpeg exited $rc without an av1_amf decode (no AV1 hardware decode?)"
        sed -n 's/^/       | /p' <<<"$(grep -iE "error|not (supported|available|found)|failed|cannot" "$log" | tail -3)"
        skip=$((skip + 1)); return 1
    fi
    return 0
}

case_download() {
    local log="$work/download.log" rc
    run_amf "$log" -vf "hwdownload,format=p010le" -f framemd5 "$work/amf.md5"
    rc=$?
    classify download "$rc" "$log" || return

    if ! "${BOUND[@]}" "$FFMPEG" -nostdin -hide_banner -loglevel error -c:v libdav1d -i "$ivf" \
            -map 0:v:0 -pix_fmt p010le -f framemd5 "$work/sw.md5"; then
        echo "SKIP: download - no libdav1d reference decode"
        skip=$((skip + 1)); return
    fi

    local amf sw diff
    amf=$(grep -vc '^#' "$work/amf.md5")
    sw=$(grep -vc '^#' "$work/sw.md5")
    diff=$(diff <(grep -v '^#' "$work/amf.md5" | awk -F, '{print $NF}') \
                <(grep -v '^#' "$work/sw.md5" | awk -F, '{print $NF}') | grep -c '^[<>]')
    if [ "$amf" -lt "$EXPECTED_FRAMES" ] || [ "$amf" -ne "$sw" ] || [ "$diff" -ne 0 ]; then
        echo "FAIL: download - $amf frames (libdav1d $sw), $diff differing frame hashes"
        fail=$((fail + 1)); return
    fi
    echo "PASS: download - $amf frames, bit-exact with libdav1d"
    pass=$((pass + 1))
}

case_vpp() {
    local log="$work/vpp.log" rc
    run_amf "$log" -vf "vpp_amf=w=320:h=180:format=nv12:color_profile=bt709:primaries=bt709:trc=bt709" \
        -c:v hevc_amf -f null -
    rc=$?
    classify vpp "$rc" "$log" || return

    local decoded
    decoded=$(grep -o '[0-9]* frames decoded' "$log" | head -1 | cut -d' ' -f1)
    if [ "${decoded:-0}" -lt "$EXPECTED_FRAMES" ]; then
        echo "FAIL: vpp - ${decoded:-0}/$EXPECTED_FRAMES frames decoded"
        fail=$((fail + 1)); return
    fi
    echo "PASS: vpp - $decoded frames decoded"
    pass=$((pass + 1))
}

echo "ffmpeg:  $FFMPEG"
echo "version: $("$FFMPEG" -version 2>/dev/null | head -1)"
echo "device:  $INIT_HW_DEVICE"
echo

for case in $CASES; do
    case "$case" in
        download) case_download ;;
        vpp)      case_vpp ;;
        *) echo "unknown case: $case" >&2; exit 2 ;;
    esac
done

echo
echo "$pass passed, $fail failed, $skip skipped"

[ $fail -gt 0 ] && exit 1
[ $pass -eq 0 ] && exit 77
exit 0
