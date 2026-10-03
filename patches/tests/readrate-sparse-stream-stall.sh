#!/usr/bin/env bash
#
# Reproducer for 0007-ffmpeg_demux-do-not-pace-readrate-on-sparse-streams.patch
#
# The sample (samples/make-dvdsub-sparse-gaps.py) is a synthetic dvd_subtitle
# track on a synthetic video: cues every 2s, one 15s gap (7.0 -> 22.0), then
# more cues. Burning the subtitle in under -readrate makes the demuxer pick the
# subtitle as the "slowest" stream; its dts is frozen between packets and then
# jumps by the whole gap, which readrate_sleep() turns into a single
# av_usleep() of very nearly that gap.
#
# Measured signal is the largest wallclock interval over which output media
# time does not advance at all.
#
#   unpatched: ~15s stall at media ~21.4
#   patched:   no stall beyond normal frame pacing
#
# Usage: readrate-sparse-stream-stall.sh [/path/to/ffmpeg]
#        FFMPEG=/path/to/ffmpeg readrate-sparse-stream-stall.sh

set -euo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sample="$here/../samples/dvdsub-sparse-gaps-h264.mkv"

# stall (seconds) at or above which the test fails; unpatched ~14, patched ~0
THRESHOLD="${THRESHOLD:-5.0}"
DURATION="${DURATION:-30}"

if [ ! -f "$sample" ]; then
    echo "SKIP: sample not found: $sample" >&2
    exit 77
fi

echo "ffmpeg:   $FFMPEG"
echo "sample:   $sample"
echo "measuring largest output stall over ${DURATION}s of media at -readrate 1.05 ..."

# timestamps are taken in bash because mawk (the docker images' awk) block-
# buffers piped stdin, so awk would see every progress line only at exit.
# EPOCHREALTIME needs bash 5; macOS ships bash 3.2, where perl stands in.
if [ -n "${EPOCHREALTIME:-}" ]; then
    now_us() { local t=${EPOCHREALTIME//[.,]/}; echo $((10#$t)); }
else
    now_us() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1e6'; }
fi

result=$(
    "$FFMPEG" -nostdin -hide_banner -nostats -loglevel error -progress - \
        -readrate 1.05 -i "$sample" \
        -filter_complex "[0:0][0:1]overlay[v]" -map "[v]" \
        -t "$DURATION" -c:v rawvideo -f null - 2>/dev/null \
    | {
        start=$(now_us)
        last_media=0 last_wall=0 max_gap=0 at=0
        # both out_time_ms and out_time_us are microseconds
        while IFS='=' read -r key value; do
            # not a case statement: bash 3.2 ends $( ) at a case pattern's ")"
            [[ "$key" == out_time_ms || "$key" == out_time_us ]] || continue
            [[ "$value" =~ ^[0-9]+$ ]] || continue
            media=$((10#$value))
            if (( media > last_media )); then
                wall=$(( $(now_us) - start ))
                gap=$(( wall - last_wall ))
                if (( gap > max_gap )); then max_gap=$gap; at=$last_media; fi
                last_media=$media
                last_wall=$wall
            fi
        done
        awk -v g="$max_gap" -v a="$at" 'BEGIN { printf "%.2f %.2f\n", g / 1e6, a / 1e6 }'
    }
)

stall=${result% *}
at=${result#* }

echo "max stall: ${stall}s (output frozen at media ${at}s)"

if awk -v s="$stall" -v t="$THRESHOLD" 'BEGIN { exit !(s >= t) }'; then
    echo "FAIL: demuxer stalled ${stall}s (>= ${THRESHOLD}s) - readrate is pacing on the sparse subtitle stream"
    exit 1
fi

echo "PASS: no stall beyond ${THRESHOLD}s"
