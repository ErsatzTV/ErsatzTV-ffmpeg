#!/bin/sh
# Usage: release-vars.sh <ErsatzTV-ffmpeg commit>
# Prints the build variables derived from release.json as KEY=VALUE lines,
# suitable for $GITHUB_ENV or docker --build-arg.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
commit=${1:-}

if ! printf '%s' "$commit" | grep -Eqx '[0-9a-f]{40}'; then
    echo "release-vars: expected a full commit SHA, got '$commit'" >&2
    exit 1
fi

jq -r --arg short "$(printf '%s' "$commit" | cut -c1-8)" '
    "FFMPEG_VERSION=\(.ffmpeg.version)",
    "FFMPEG_TAG=\(.ffmpeg.tag)",
    "FFMPEG_COMMIT=\(.ffmpeg.commit)",
    "FFMPEG_SHA256=\(.ffmpeg.tarball_sha256)",
    "ETV_REVISION=\(.revision)",
    "RELEASE_TAG=\(.ffmpeg.version)-\(.revision)",
    "FFMPEG_EXTRA_VERSION=etv.\(.revision)-g\($short)"
' "$root/release.json"
