#!/usr/bin/env bash
#
# Throughput comparison of the QSV padding options, all on the same hardware
# and the same decoded source, encoded with h264_qsv into a real muxer so
# dropped frames show up in the packet count:
#
#   ceiling    vpp_qsv scale only, no pad (upper bound)
#   pad_qsv    vpp_qsv scale, then the standalone pad_qsv filter (patch 0008)
#   vpp_pad    vpp_qsv scale+pad fused in one VPP pass (PR 42 pad_w/pad_h),
#              skipped when the binary has no pad_w option
#   sw_pad     vpp_qsv scale, hwdownload, pad, hwupload (what ErsatzTV does today)
#
# 640x480 4:3 source (generated with libx264 into the log dir) scaled to
# 1440x1080 and letterboxed into 1920x1080, the same geometry PR 42 reported.
#
# Usage: pad-qsv-bench.sh [/path/to/ffmpeg]
#        DURATION=60 RUNS=2 QSV_CHILD_DEVICE=/dev/dri/renderD129 pad-qsv-bench.sh
#
# Prints one line per arm: frames delivered, wall seconds, fps, CPU seconds.

set -uo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"
case "$FFMPEG" in */*) FFMPEG="$(cd "$(dirname "$FFMPEG")" && pwd)/$(basename "$FFMPEG")" ;; esac
FFPROBE="${FFPROBE:-$(dirname "$FFMPEG")/ffprobe}"
[ -x "$FFPROBE" ] || [ -x "$FFPROBE.exe" ] || FFPROBE=ffprobe
DURATION="${DURATION:-60}"
RUNS="${RUNS:-2}"
QSV_CHILD_DEVICE="${QSV_CHILD_DEVICE:-}"

logdir="$(mktemp -d)"
trap 'rm -rf "$logdir"' EXIT

# Git Bash / MSYS2: see vpp-qsv-pad.sh. ffmpeg and ffprobe run inside the log
# dir with relative file names.
command -v cygpath >/dev/null 2>&1 && export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
ff()  { (cd "$logdir" && exec "$FFMPEG" "$@"); }
ffp() { (cd "$logdir" && exec "$FFPROBE" "$@"); }

devspec="qsv=hw:hw_any${QSV_CHILD_DEVICE:+,child_device=$QSV_CHILD_DEVICE}"
common=(-nostdin -hide_banner -nostats -loglevel info -benchmark
        -init_hw_device "$devspec" -filter_hw_device hw
        -hwaccel qsv -hwaccel_device hw -hwaccel_output_format qsv)

src="src.mp4"
echo "generating ${DURATION}s 640x480 h264 source ..."
ff -nostdin -hide_banner -nostats -loglevel error \
    -f lavfi -i "testsrc2=size=640x480:rate=60:duration=$DURATION" \
    -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p "$src" || { echo "cannot generate source"; exit 2; }
expected=$(( DURATION * 60 ))

has_vpp_pad=0
"$FFMPEG" -hide_banner -h filter=vpp_qsv 2>/dev/null | grep '^ *pad_w ' >/dev/null && has_vpp_pad=1
has_pad_qsv=0
"$FFMPEG" -hide_banner -filters 2>/dev/null | grep ' pad_qsv ' >/dev/null && has_pad_qsv=1

run_arm() {
    local name="$1" graph="$2" best_rt="" best_ut="" best_frames="" log out
    for i in $(seq 1 "$RUNS"); do
        log="$logdir/$name.$i.log"; out="$name.$i.mp4"
        ff "${common[@]}" -i "$src" -vf "$graph" -c:v h264_qsv -y "$out" >"$log" 2>&1
        if [ $? -ne 0 ]; then
            echo "$name: FAILED ($(grep -iE 'error|MFX|Invalid' "$log" | tail -1))"
            return
        fi
        local rt ut frames
        rt="$(grep -o 'rtime=[0-9.]*' "$log" | tail -1 | cut -d= -f2)"
        ut="$(grep -o 'utime=[0-9.]*' "$log" | tail -1 | cut -d= -f2)"
        frames="$(ffp -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 "$out" 2>/dev/null)"
        if [ -z "$best_rt" ] || awk -v a="$rt" -v b="$best_rt" 'BEGIN { exit !(a < b) }'; then
            best_rt="$rt"; best_ut="$ut"; best_frames="$frames"
        fi
    done
    local fps; fps="$(awk -v f="$best_frames" -v t="$best_rt" 'BEGIN { if (t > 0) printf "%.0f", f / t; else print "nan" }')"
    local note=""
    [ "$best_frames" != "$expected" ] && note="  <-- expected $expected frames"
    printf "%-8s frames=%-6s wall=%6.2fs  fps=%-5s cpu=%5.2fs%s\n" "$name" "$best_frames" "$best_rt" "$fps" "$best_ut" "$note"
}

echo "ffmpeg:  $FFMPEG"
echo "version: $("$FFMPEG" -version 2>/dev/null | head -1)"
echo "device:  $devspec   runs per arm: $RUNS (best wall time reported)"
echo

run_arm ceiling "vpp_qsv=w=1440:h=1080"
if [ $has_pad_qsv -eq 1 ]; then
    run_arm pad_qsv "vpp_qsv=w=1440:h=1080,pad_qsv=w=1920:h=1080:x=-1:y=-1"
else
    echo "pad_qsv: skipped (filter not in this build)"
fi
if [ $has_vpp_pad -eq 1 ]; then
    run_arm vpp_pad "vpp_qsv=w=1440:h=1080:pad_w=1920:pad_h=1080"
else
    echo "vpp_pad: skipped (vpp_qsv has no pad_w in this build)"
fi
run_arm sw_pad "vpp_qsv=w=1440:h=1080,hwdownload,format=nv12,pad=1920:1080:-1:-1,hwupload=extra_hw_frames=16"
