#!/usr/bin/env bash
#
# Reproducer for 0031-fftools-ffmpeg_sched-schedule-encoder-sync-queues-by-their-head-stream.patch
#
# With -shortest, encoded streams pass through a sync queue before their
# encoders. The scheduler only throttles demuxers by the dts the muxer has
# seen, and an encoder's delay (lookahead, async depth) holds packets back from
# the muxer. With video and audio read from separate inputs, video looks
# behind at the muxer and keeps being decoded while the queue waits for
# audio, whose demuxer is choked as ahead. Video frames pile up in the queue
# until it overflows (-shortest_buf_duration, 10 s by default). With hardware
# frames from a fixed pool (QSV on runtimes before 2.9) the pool runs out first
# and ffmpeg fails with "Can't allocate a surface".
#
# The test reads video and audio of a generated clip from two inputs of the
# same file, encodes with libx264 (default lookahead, so over 100 ms of encoder
# delay) and counts the most video frames held in the sync queue at once, from
# the queue's debug log.
#
#   unpatched: ~300 frames held
#   patched:   < 10 frames held
#
# Usage: sync-queue-separate-inputs.sh [/path/to/ffmpeg]
#        FFMPEG=/path/to/ffmpeg sync-queue-separate-inputs.sh
#
# Exit: 0 pass, 1 fail, 2 cannot run ffmpeg.

set -uo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"

# most video frames held in the sync queue at or above which the test fails
THRESHOLD="${THRESHOLD:-30}"

if ! "$FFMPEG" -version >/dev/null 2>&1; then
    echo "ERROR: cannot run ffmpeg: $FFMPEG" >&2
    exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if ! "$FFMPEG" -nostdin -hide_banner -loglevel error \
    -f lavfi -i "testsrc2=size=320x240:rate=30" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -t 24 -c:v libx264 -g 150 -c:a aac "$work/in.mkv"; then
    echo "ERROR: cannot build the input file" >&2
    exit 2
fi

held() {
    "$FFMPEG" -nostdin -hide_banner -loglevel debug "$@" \
        -c:v libx264 -c:a aac -t 20 -shortest -f null - 2> "$work/log" || return 1
    grep -a -o 'sq: send 0\|sq: receive 0' "$work/log" |
        awk '/send/ { h++ } /receive/ { h-- } h > m { m = h } END { print m + 0 }'
}

one=$(held -i "$work/in.mkv" -map 0:v -map 0:a) || { echo "ERROR: ffmpeg failed" >&2; exit 2; }
two=$(held -i "$work/in.mkv" -i "$work/in.mkv" -map 0:v -map 1:a) || { echo "ERROR: ffmpeg failed" >&2; exit 2; }

echo "ffmpeg:              $FFMPEG"
echo "video frames held:   $two with separate inputs, $one with one input"

if [ "$two" -ge "$THRESHOLD" ]; then
    echo "FAIL: the sync queue holds video while it waits for audio (>= $THRESHOLD frames)"
    exit 1
fi

echo "PASS: the sync queue holds fewer than $THRESHOLD video frames"
