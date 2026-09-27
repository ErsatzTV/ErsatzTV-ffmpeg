#!/bin/sh
# Usage: release-notes.sh <docker index digest>
# Prints GitHub release notes for the revision in release.json: the
# hand-written release-notes/<tag>.md, then what changed since the previous
# revision tag (compared numerically, not as SemVer), pins, and verification.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
index=$1

version=$(jq -er '.ffmpeg.version' release.json)
upstream_tag=$(jq -er '.ffmpeg.tag' release.json)
upstream_commit=$(jq -er '.ffmpeg.commit' release.json)
revision=$(jq -er '.revision' release.json)
tag="$version-$revision"
image=ghcr.io/ersatztv/ersatztv-ffmpeg

[ -f "release-notes/$tag.md" ] || { echo "release-notes: missing release-notes/$tag.md" >&2; exit 1; }

key() { echo "$1" | awk -F'[.-]' '{ printf "%d %d %d %d\n", $1, $2, $3, $4 }'; }
current=$(key "$tag")
prev=$(git tag -l | grep -Ex '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+' | while read -r t; do
    echo "$(key "$t") $t"
done | sort -k1,1n -k2,2n -k3,3n -k4,4n | awk -v cur="$current" '
    { split(cur, c, " "); less = 0
      for (i = 1; i <= 4; i++) if ($i != c[i]) { less = $i < c[i]; break }
      if (less) prev = $5 }
    END { print prev }')

cat "release-notes/$tag.md"
echo
echo "## Build"
echo
echo "- FFmpeg \`$upstream_tag\` (\`$upstream_commit\`), ETV revision $revision"
echo "- \`ffmpeg -version\`: \`n$version-etv.$revision\` (native), \`$version-etv.$revision\` (docker)"
echo "- Docker: \`$image:$tag@$index\`"
echo "- Native toolchain: [ErsatzTV/FFmpeg-Builds@$(git -C native/FFmpeg-Builds rev-parse --short=12 HEAD)](https://github.com/ErsatzTV/FFmpeg-Builds/commit/$(git -C native/FFmpeg-Builds rev-parse HEAD)), dependency images:"
jq -r '.images | to_entries[] | "  - \(.key): `\(.value)`"' native/images.lock.json
echo
echo "## Patches"
echo
if [ -n "$prev" ]; then
    changes=$(git diff --name-status "$prev" HEAD -- 'patches/*.patch' | sed 's/^/    /')
    echo "Changes since \`$prev\`:"
    echo
    if [ -n "$changes" ]; then echo "$changes"; else echo "    (none)"; fi
    echo
    other=$(git diff --stat "$prev" HEAD -- images native release.json scripts | sed 's/^/    /')
    if [ -n "$other" ]; then
        echo "Build input changes since \`$prev\`:"
        echo
        echo "$other"
        echo
    fi
fi
echo "Applied in order to every platform:"
echo
for p in patches/*.patch; do echo "- [\`$(basename "$p")\`](https://github.com/ErsatzTV/ErsatzTV-ffmpeg/blob/$tag/$p)"; done
echo
echo "## Verify"
echo
echo '```sh'
echo "sha256sum -c --ignore-missing SHA256SUMS"
echo "gh attestation verify <archive> --repo ErsatzTV/ErsatzTV-ffmpeg"
echo "gh attestation verify oci://$image@$index --repo ErsatzTV/ErsatzTV-ffmpeg"
echo '```'
echo
echo "Source: \`ffmpeg-$version.tar.bz2\` is the upstream release (sha256 \`$(jq -r '.ffmpeg.tarball_sha256' release.json)\`); \`ersatztv-ffmpeg-$tag-src.tar.xz\` is this repo and the native toolchain submodule at \`$tag\`."
if [ -n "${GITHUB_RUN_ID:-}" ]; then
    echo
    echo "Built and tested by [run $GITHUB_RUN_ID]($GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID)."
fi
