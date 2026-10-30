#!/bin/sh
# Usage: check-upstream.sh <work dir>
# Verifies the upstream identity in release.json (tag -> commit, tarball
# checksum), that the upstream-<version> release holds the fallback tarball,
# and that the whole patch set applies, in order, to that tarball.
# Leaves the verified tarball at <work dir>/ffmpeg-<version>.tar.bz2.
# <work dir> must be outside any git checkout: git apply inside a repo
# silently skips paths outside the current directory.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
work=$1

fail() {
    echo "check-upstream: $*" >&2
    exit 1
}

version=$(jq -er '.ffmpeg.version' "$root/release.json")
tag=$(jq -er '.ffmpeg.tag' "$root/release.json")
commit=$(jq -er '.ffmpeg.commit' "$root/release.json")
sha256=$(jq -er '.ffmpeg.tarball_sha256' "$root/release.json")

actual=$(git ls-remote https://github.com/FFmpeg/FFmpeg.git "refs/tags/$tag" "refs/tags/$tag^{}" | tail -n 1 | cut -f1)
[ "$actual" = "$commit" ] || fail "$tag is '$actual', release.json has $commit"

mkdir -p "$work"
work=$(cd "$work" && pwd)
! git -C "$work" rev-parse --git-dir >/dev/null 2>&1 || fail "$work is inside a git checkout"

tarball="$work/ffmpeg-$version.tar.bz2"
sh "$root/scripts/fetch-upstream.sh" "$version" "$sha256" "$tarball" || fail "no tarball matches tarball_sha256"
# the Docker builds fall back to this copy; fetch-upstream.sh checks its bytes
mirror="https://github.com/ErsatzTV/ErsatzTV-ffmpeg/releases/download/upstream-$version/ffmpeg-$version.tar.bz2"
curl -LfsI -o /dev/null "$mirror" || fail "missing $mirror (docs/releasing.md)"

src="$work/ffmpeg"
rm -rf "$src"
mkdir -p "$src"
tar -jx --strip-components=1 -C "$src" -f "$tarball"
for p in "$root"/patches/*.patch; do
    git -C "$src" apply "$p" || fail "does not apply: patches/$(basename "$p")"
done
rm -rf "$src"

echo "check-upstream: ok ($tag = $commit, $(ls "$root"/patches/*.patch | wc -l) patches apply)"
