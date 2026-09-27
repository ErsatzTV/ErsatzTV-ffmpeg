#!/bin/sh
# Usage: build-native.sh <target> <ErsatzTV-ffmpeg commit> [dev|release]
# Builds one native target with the fork's release mode, using the locked
# dependency image and this repo's patch set. The archive lands in
# native/FFmpeg-Builds/artifacts/.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
target=$1 commit=$2 mode=${3:-dev}

vars=$(sh "$root/scripts/release-vars.sh" "$commit" "$mode")
var() { printf '%s\n' "$vars" | sed -n "s/^$1=//p"; }

cd "$root/native/FFmpeg-Builds"
FFBUILD_RELEASE=1 \
IMAGE_OVERRIDE=$(jq -er --arg t "$target" '.images[$t]' "$root/native/images.lock.json") \
FFMPEG_COMMIT=$(var FFMPEG_COMMIT) \
GIT_BRANCH_OVERRIDE=$(var FFMPEG_TAG) \
FFBUILD_VERSION_SUFFIX=$(var FFMPEG_EXTRA_VERSION) \
FFMPEG_PATCHES_DIR="$root/patches" \
    exec ./build.sh "$target" gpl 8.1
