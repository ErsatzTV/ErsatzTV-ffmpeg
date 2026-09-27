#!/bin/sh
# Usage: release-vars.sh <ErsatzTV-ffmpeg commit> [dev|release]
# Prints the build variables derived from release.json as KEY=VALUE lines,
# suitable for $GITHUB_ENV or docker --build-arg.
#
# The extra version is etv.<revision> for release builds: the immutable tag
# already maps that to one commit, and a commit hash in the banner reads like
# FFmpeg's own git-describe output. Dev builds (PR/main) are never published
# and carry the commit instead: etv.dev.<short commit>.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
commit=${1:-}
mode=${2:-dev}

if ! printf '%s' "$commit" | grep -Eqx '[0-9a-f]{40}'; then
    echo "release-vars: expected a full commit SHA, got '$commit'" >&2
    exit 1
fi

case "$mode" in
    dev) extra="etv.dev.$(printf '%s' "$commit" | cut -c1-8)" ;;
    release) extra="etv.$(jq -r '.revision' "$root/release.json" | tr -d '\r')" ;;
    *) echo "release-vars: mode must be dev or release, got '$mode'" >&2; exit 1 ;;
esac

jq -r --arg extra "$extra" '
    "FFMPEG_VERSION=\(.ffmpeg.version)",
    "FFMPEG_TAG=\(.ffmpeg.tag)",
    "FFMPEG_COMMIT=\(.ffmpeg.commit)",
    "FFMPEG_SHA256=\(.ffmpeg.tarball_sha256)",
    "ETV_REVISION=\(.revision)",
    "RELEASE_TAG=\(.ffmpeg.version)-\(.revision)",
    "FFMPEG_EXTRA_VERSION=\($extra)"
' "$root/release.json" | tr -d '\r' # native jq.exe on Windows writes CRLF
