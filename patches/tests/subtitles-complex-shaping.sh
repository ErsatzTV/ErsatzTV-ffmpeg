#!/usr/bin/env bash
#
# Reproducer for 0034-lavfi-vf_subtitles-expose-shaping-option.patch
#
# Without the patch the subtitles filter always uses libass simple shaping
# (FriBidi presentation forms), never HarfBuzz. Arabic lam-alef then renders as
# a box next to the ligature in fonts without a U+FEFF glyph, such as Arial.
# The ass filter has always defaulted to auto, which picks complex shaping.
#
# The test renders one Arabic line in samples/etv-test-arabic.ttf three ways
# and compares one frame of each:
#
#   subtitles (default)          the filter ErsatzTV uses
#   ass, shaping=complex         HarfBuzz
#   ass, shaping=simple          FriBidi
#
# The font has no presentation forms, so the simple and complex renders always
# differ, whatever fallback fonts the system has.
#
#   unpatched: subtitles matches the simple render (boxes)
#   patched:   subtitles matches the complex render (lam-alef ligature)
#
# Usage: subtitles-complex-shaping.sh [/path/to/ffmpeg]
#        FFMPEG=/path/to/ffmpeg subtitles-complex-shaping.sh
#
# Exit: 0 pass, 1 fail, 2 cannot run ffmpeg, 77 libass cannot shape with HarfBuzz.

set -uo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
font="$here/../samples/etv-test-arabic.ttf"

if ! "$FFMPEG" -version >/dev/null 2>&1; then
    echo "ERROR: cannot run ffmpeg: $FFMPEG" >&2
    exit 2
fi
if [ ! -f "$font" ]; then
    echo "ERROR: missing $font" >&2
    exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/fonts"
cp "$font" "$work/fonts/"

# Relative paths keep Windows drive letters out of the filtergraph.
cd "$work" || exit 2
cat > t.ass <<'EOF'
[Script Info]
ScriptType: v4.00+
PlayResX: 320
PlayResY: 120

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,ETV Test Arabic,48,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,5,0,0,0,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:05.00,Default,,0,0,0,,بلا لا بل
EOF

render() { # filter
    "$FFMPEG" -nostdin -hide_banner -loglevel error \
        -f lavfi -i color=black:size=320x120:duration=1 -vf "$1" \
        -frames:v 1 -f md5 - 2>"$work/err" | sed -n 's/^MD5=//p'
}

default=$(render "subtitles=t.ass:fontsdir=fonts")
complex=$(render "ass=t.ass:fontsdir=fonts:shaping=complex")
simple=$(render "ass=t.ass:fontsdir=fonts:shaping=simple")

echo "ffmpeg:    $FFMPEG"
echo "default:   ${default:-none}"
echo "complex:   ${complex:-none}"
echo "simple:    ${simple:-none}"

if [ -z "$default" ] || [ -z "$complex" ] || [ -z "$simple" ]; then
    sed 's/^/  /' "$work/err"
    echo "ERROR: a render failed" >&2
    exit 2
fi
if [ "$complex" = "$simple" ]; then
    echo "SKIP: complex and simple shaping render the same; libass has no HarfBuzz shaping"
    exit 77
fi
if [ "$default" = "$simple" ]; then
    echo "FAIL: the subtitles filter uses simple shaping"
    exit 1
fi
if [ "$default" != "$complex" ]; then
    echo "FAIL: the subtitles filter matches neither shaping mode"
    exit 1
fi

echo "PASS: the subtitles filter uses complex shaping"
