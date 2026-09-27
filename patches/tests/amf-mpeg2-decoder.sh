#!/usr/bin/env bash
#
# Reproducer for
#   0011-lavc-amfdec-add-mpeg2_amf-and-vc1_amf-decoders.patch
#
# Needs an AMD GPU whose AMF runtime has the MPEG-2 (and, for the optional vc1
# case, VC-1) decoder component. On a Windows laptop with an APU and a discrete
# card the runtime picks the APU by default, and current APUs have no MPEG-2
# hardware, so point the run at the discrete adapter with INIT_HW_DEVICE (see
# usage). ErsatzTV next's `probe_capabilities amf --adapter N` shows which
# adapter reports MPEG2/VC1.
#
# Cases:
#
#   decoder-listed     `ffmpeg -decoders` contains mpeg2_amf and vc1_amf.
#                      Fails on any build without the patch, regardless of GPU.
#
#   mpeg2-progressive  Synthetic 1080p MPEG-2 TS, decoded with -hwaccel amf and
#                      kept on the device through vpp_amf into h264_amf. Passes
#                      only if the verbose log shows the mpeg2_amf decoder being
#                      selected AND every frame was decoded. Without the patch
#                      ffmpeg silently decodes in software and still exits 0, so
#                      exit status alone proves nothing - hence the log check.
#
#   mpeg2-interlaced   Synthetic 1080i MPEG-2, downloaded straight after decode
#                      and deinterlaced in software (bwdif). This is deliberately
#                      NOT kept on the device: AMF stamps interlaced surfaces as
#                      field pairs and h264_amf then stalls, the same issue
#                      ErsatzTV works around for interlaced H.264. Same checks.
#
#   vc1                Only when VC1_SAMPLE is set (ffmpeg cannot encode VC-1).
#                      Advanced Profile stream expected. Same checks as
#                      mpeg2-progressive with vc1_amf, plus a timestamp check on
#                      the first 10 s: output pts must be monotonic. KNOWN TO
#                      FAIL on VC-1 in MKV as of the g6a8e4827 build: the runtime
#                      stamps each picture with its own packet's pts and MKV
#                      carries VC-1 timestamps in decode order, so pts swap in
#                      pairs and a cfr encode dups/drops a third of the frames.
#                      The pictures themselves are correct. ErsatzTV does not
#                      use vc1_amf until this is solved; see the manifest.
#
#   unsupported-gpu    Only when UNSUPPORTED_INIT_HW_DEVICE names an AMD adapter
#                      WITHOUT MPEG-2 hardware (an APU such as the Radeon 680M).
#                      The runtime still creates the component there, then
#                      SubmitInput() returns AMF_NOT_SUPPORTED (10) and ffmpeg
#                      crashes with a segfault on the way out. Passes when ffmpeg
#                      exits non-zero WITHOUT a signal and logs that the device
#                      has no decoder for the codec. Never claims software
#                      fallback: -hwaccel amf has none once the wrapper decoder
#                      has been selected.
#
# Usage: amf-mpeg2-decoder.sh [/path/to/ffmpeg]
#        FFMPEG=/path/to/ffmpeg amf-mpeg2-decoder.sh
#        CASES="decoder-listed mpeg2-progressive" amf-mpeg2-decoder.sh
#        INIT_HW_DEVICE="-init_hw_device d3d11va=dx:1 -init_hw_device amf=hw@dx" amf-mpeg2-decoder.sh
#        VC1_SAMPLE=/path/to/vc1.mkv amf-mpeg2-decoder.sh
#        UNSUPPORTED_INIT_HW_DEVICE="-init_hw_device d3d11va=dx:0 -init_hw_device amf=hw@dx" amf-mpeg2-decoder.sh
#
# Exit: 0 all runnable cases passed, 1 any case failed, 77 nothing was runnable.

set -uo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"
CASES="${CASES:-decoder-listed mpeg2-progressive mpeg2-interlaced vc1 unsupported-gpu}"
INIT_HW_DEVICE="${INIT_HW_DEVICE:--init_hw_device amf=hw}"
VC1_SAMPLE="${VC1_SAMPLE:-}"
UNSUPPORTED_INIT_HW_DEVICE="${UNSUPPORTED_INIT_HW_DEVICE:-}"
TIMEOUT_S="${TIMEOUT_S:-60}"

FRAMES=60   # 2 s at 30 fps for the synthetic sources

if ! "$FFMPEG" -hide_banner -version >/dev/null 2>&1; then
    echo "ffmpeg not runnable: $FFMPEG" >&2
    exit 77
fi
if ! "$FFMPEG" -hide_banner -hwaccels 2>/dev/null | grep -qx 'amf'; then
    echo "this ffmpeg has no amf hwaccel; nothing to test" >&2
    exit 77
fi

if command -v timeout >/dev/null 2>&1; then
    BOUND=(timeout "$TIMEOUT_S")
else
    BOUND=()
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ran=0

report() {
    local name="$1" ok="$2" detail="$3"
    ran=$((ran + 1))
    if [ "$ok" = 1 ]; then
        pass=$((pass + 1))
        echo "PASS  $name  $detail"
    else
        fail=$((fail + 1))
        echo "FAIL  $name  $detail"
    fi
}

# make_mpeg2 <out.ts> <interlaced 0|1>
make_mpeg2() {
    local out="$1" interlaced="$2"
    local -a flags=()
    if [ "$interlaced" = 1 ]; then
        flags=(-flags +ilme+ildct -top 1)
    fi
    "$FFMPEG" -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=s=1920x1080:r=30:d=2" \
        -c:v mpeg2video "${flags[@]}" -b:v 8M -pix_fmt yuv420p "$out"
}

# run_decode <name> <source> <decoder-name> <vf>
# Passes when ffmpeg exits 0, the AMF wrapper decoder was selected, and every
# source frame was decoded.
run_decode() {
    local name="$1" src="$2" decoder="$3" vf="$4"
    local log="$WORK/$name.log"
    # shellcheck disable=SC2086
    "${BOUND[@]}" "$FFMPEG" -hide_banner -v verbose \
        $INIT_HW_DEVICE -filter_hw_device hw \
        -hwaccel amf -hwaccel_output_format amf \
        -i "$src" -an -vf "$vf" -c:v h264_amf -f null - >"$log" 2>&1
    local rc=$?

    local selected=0 decoded
    grep -q "Selecting decoder '$decoder'" "$log" && selected=1
    decoded="$(sed -n 's/.* \([0-9]\+\) frames decoded;.*/\1/p' "$log" | tail -1)"
    decoded="${decoded:-0}"

    local expect="$FRAMES"
    [ -n "${5:-}" ] && expect="$5"

    if [ "$rc" -eq 0 ] && [ "$selected" = 1 ] && { [ "$expect" = any ] && [ "$decoded" -gt 0 ] || [ "$decoded" = "$expect" ]; }; then
        report "$name" 1 "$decoder selected, $decoded frames decoded"
    else
        local why="rc=$rc"
        [ "$selected" = 1 ] || why="$why, '$decoder' never selected (software decode)"
        why="$why, $decoded frames decoded"
        report "$name" 0 "$why"
        grep -iE "amf|error|fail" "$log" | grep -v "Selecting decoder 'h264" | head -8 | sed 's/^/      /'
    fi
}

for c in $CASES; do
    case "$c" in
        decoder-listed)
            listing="$("$FFMPEG" -hide_banner -decoders 2>/dev/null)"
            have=""
            for d in mpeg2_amf vc1_amf; do
                if echo "$listing" | grep -qE "^ V[^ ]* +$d "; then
                    have="$have $d"
                fi
            done
            if [ "$have" = " mpeg2_amf vc1_amf" ]; then
                report "$c" 1 "mpeg2_amf and vc1_amf present"
            else
                report "$c" 0 "present:${have:- none} (patch not applied?)"
            fi
            ;;
        mpeg2-progressive)
            src="$WORK/1080p_mpeg2.ts"
            if make_mpeg2 "$src" 0; then
                run_decode "$c" "$src" mpeg2_amf "vpp_amf=w=1280:h=720:format=nv12,setsar=1"
            else
                report "$c" 0 "could not encode the synthetic source"
            fi
            ;;
        mpeg2-interlaced)
            src="$WORK/1080i_mpeg2.ts"
            if make_mpeg2 "$src" 1; then
                run_decode "$c" "$src" mpeg2_amf "hwdownload,format=nv12,bwdif=mode=send_frame,hwupload,vpp_amf=w=1280:h=720:format=nv12,setsar=1"
            else
                report "$c" 0 "could not encode the synthetic source"
            fi
            ;;
        vc1)
            if [ -z "$VC1_SAMPLE" ]; then
                echo "SKIP  vc1  set VC1_SAMPLE to an Advanced Profile VC-1 file to run this case"
                continue
            fi
            if [ ! -f "$VC1_SAMPLE" ]; then
                report "$c" 0 "VC1_SAMPLE not found: $VC1_SAMPLE"
                continue
            fi
            run_decode "$c" "$VC1_SAMPLE" vc1_amf "vpp_amf=w=1280:h=720:format=nv12,setsar=1" any
            # decode order vs display order: pts out of the wrapper must not go backwards
            ptslog="$WORK/$c.pts"
            # shellcheck disable=SC2086
            "${BOUND[@]}" "$FFMPEG" -hide_banner -v info \
                $INIT_HW_DEVICE -hwaccel amf -hwaccel_output_format amf \
                -t 10 -i "$VC1_SAMPLE" -an -sn -vf "hwdownload,format=nv12,showinfo" -f null - 2>&1 \
                | sed -n 's/.*n: *[0-9]* pts: *\([0-9]*\) pts_time.*/\1/p' >"$ptslog"
            backwards="$(awk 'NR>1 && $1<=p {c++} {p=$1} END {print c+0}' "$ptslog")"
            if [ -s "$ptslog" ] && [ "$backwards" -eq 0 ]; then
                report "$c-timestamps" 1 "$(wc -l <"$ptslog") frames, pts monotonic"
            else
                report "$c-timestamps" 0 "$backwards backwards pts steps in $(wc -l <"$ptslog") frames (head: $(head -6 "$ptslog" | tr '\n' ' '))"
            fi
            ;;
        unsupported-gpu)
            if [ -z "$UNSUPPORTED_INIT_HW_DEVICE" ]; then
                echo "SKIP  $c  set UNSUPPORTED_INIT_HW_DEVICE to an AMD adapter without MPEG-2 hardware to run this case"
                continue
            fi
            src="$WORK/1080p_mpeg2_unsupported.ts"
            if ! make_mpeg2 "$src" 0; then
                report "$c" 0 "could not encode the synthetic source"
                continue
            fi
            log="$WORK/$c.log"
            # shellcheck disable=SC2086
            "${BOUND[@]}" "$FFMPEG" -hide_banner -v verbose \
                $UNSUPPORTED_INIT_HW_DEVICE -filter_hw_device hw \
                -hwaccel amf -hwaccel_output_format amf \
                -i "$src" -an -vf "vpp_amf=w=1280:h=720:format=nv12,setsar=1" -c:v h264_amf -f null - >"$log" 2>&1
            rc=$?
            if [ "$rc" -eq 0 ]; then
                report "$c" 0 "decoded successfully; this adapter is not an unsupported one"
            elif [ "$rc" -ge 128 ]; then
                report "$c" 0 "ffmpeg died with signal $((rc - 128)) instead of failing cleanly"
                grep -iE "amf|error" "$log" | tail -4 | sed 's/^/      /'
            elif grep -q "no hardware decoder for" "$log"; then
                report "$c" 1 "rejected cleanly (rc=$rc)"
            else
                report "$c" 0 "exited $rc without the expected 'no hardware decoder' message"
                grep -iE "amf|error" "$log" | tail -4 | sed 's/^/      /'
            fi
            ;;
        *)
            echo "unknown case: $c" >&2
            ;;
    esac
done

echo "---- $pass passed, $fail failed, $ran ran"
if [ "$ran" -eq 0 ]; then
    exit 77
fi
[ "$fail" -eq 0 ]
