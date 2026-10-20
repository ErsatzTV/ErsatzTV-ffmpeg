#!/usr/bin/env bash
#
# Reproducer for 0017-fftools-ffmpeg_filter-keep-sub2video-last_pts-monotonic.patch
#
# ffmpeg sends a sub2video heartbeat for every packet demuxed from the
# subtitle's input file, audio included. sub2video_heartbeat() skips heartbeats
# at or below last_pts and re-pushes the canvas for the rest. Pushing a cue (or
# the blank canvas at its end) set last_pts to the cue's own pts, which is
# behind the B-frame video pts lead, so last_pts went backwards. Every audio
# packet up to the old value then pushed another full canvas. With
# TrueHD-like audio (1200 packets/s) that is hundreds of extra frames per cue,
# each one scaled, uploaded and overlaid.
#
# The input is samples/dvdsub-sparse-gaps-h264.mkv (h264 with B-frames, 8 dvdsub
# cues) remuxed with 40-sample PCM packets (1200/s). The test counts frames out
# of the sub2video branch with and without the audio stream demuxed.
#
#   unpatched: video+audio ~913 frames vs ~250 video only (ratio ~3.6)
#   patched:   video+audio ~273 frames vs ~234 video only (ratio ~1.2)
#
# Usage: sub2video-heartbeat-burst.sh [/path/to/ffmpeg]
#        FFMPEG=/path/to/ffmpeg sub2video-heartbeat-burst.sh
#
# Exit: 0 pass, 1 fail, 2 cannot run ffmpeg, 77 sample missing.

set -uo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sample="$here/../samples/dvdsub-sparse-gaps-h264.mkv"

# ratio of sub2video frames (video+audio / video only) at or above which the test fails
THRESHOLD="${THRESHOLD:-2.0}"

if [ ! -f "$sample" ]; then
    echo "SKIP: sample not found: $sample" >&2
    exit 77
fi

if ! "$FFMPEG" -version >/dev/null 2>&1; then
    echo "ERROR: cannot run ffmpeg: $FFMPEG" >&2
    exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if ! "$FFMPEG" -nostdin -hide_banner -loglevel error \
    -i "$sample" -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=30" \
    -map 0:v -map 0:s -map 1:a -c:v copy -c:s copy \
    -af asetnsamples=n=40 -c:a pcm_s16le -t 30 "$work/in.mkv"; then
    echo "ERROR: cannot build the input file" >&2
    exit 2
fi

# frames out of the sub2video branch; extra args pick which other streams are
# demuxed (unmapped streams are discarded and send no heartbeats)
count() {
    "$FFMPEG" -nostdin -hide_banner -loglevel fatal -i "$work/in.mkv" \
        -filter_complex "[0:s:0]null[s]" -map "[s]" "$@" \
        -c:v:0 rawvideo -fps_mode:0 passthrough -progress "$work/progress" \
        -f null - || return 1
    sed -n 's/^frame=//p' "$work/progress" | tail -n 1
}

with_audio=$(count -map 0:v -map 0:a -c:v:1 copy -c:a pcm_s16le) || { echo "ERROR: ffmpeg failed" >&2; exit 2; }
video_only=$(count -map 0:v -c:v:1 copy) || { echo "ERROR: ffmpeg failed" >&2; exit 2; }

if [ -z "$with_audio" ] || [ -z "$video_only" ] || [ "$video_only" -eq 0 ]; then
    echo "ERROR: no sub2video frames counted" >&2
    exit 2
fi

ratio=$(awk -v a="$with_audio" -v v="$video_only" 'BEGIN { printf "%.2f", a / v }')
echo "ffmpeg:            $FFMPEG"
echo "sub2video frames:  $with_audio with audio, $video_only video only (ratio $ratio)"

if awk -v r="$ratio" -v t="$THRESHOLD" 'BEGIN { exit !(r >= t) }'; then
    echo "FAIL: audio heartbeats re-push the sub2video canvas (ratio >= $THRESHOLD)"
    exit 1
fi

echo "PASS: audio heartbeats add no burst (ratio < $THRESHOLD)"
