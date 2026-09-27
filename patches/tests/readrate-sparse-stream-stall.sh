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

result=$(
    "$FFMPEG" -nostdin -hide_banner -nostats -loglevel error -progress - \
        -readrate 1.05 -i "$sample" \
        -filter_complex "[0:0][0:1]overlay[v]" -map "[v]" \
        -t "$DURATION" -c:v rawvideo -f null - 2>/dev/null \
    | awk -v start="$(date +%s.%N)" '
        /^out_time_(ms|us)=/ {
            "date +%s.%N" | getline now; close("date +%s.%N")
            split($0, kv, "=")
            wall = now - start
            media = kv[2] / 1000000       # both keys are microseconds
            if (media > last_media) {
                gap = wall - last_wall
                if (gap > max_gap) { max_gap = gap; at = last_media }
                last_media = media
                last_wall  = wall
            }
        }
        END { printf "%.2f %.2f\n", max_gap, at }'
)

stall=${result% *}
at=${result#* }

echo "max stall: ${stall}s (output frozen at media ${at}s)"

if awk -v s="$stall" -v t="$THRESHOLD" 'BEGIN { exit !(s >= t) }'; then
    echo "FAIL: demuxer stalled ${stall}s (>= ${THRESHOLD}s) - readrate is pacing on the sparse subtitle stream"
    exit 1
fi

echo "PASS: no stall beyond ${THRESHOLD}s"
