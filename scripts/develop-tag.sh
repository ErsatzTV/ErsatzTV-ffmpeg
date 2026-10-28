#!/bin/sh
# Usage: develop-tag.sh <ErsatzTV-ffmpeg commit>
# Prints tag=<ffmpeg version>-<short commit>-develop and last_release=<the
# newest revision tag the commit contains> for $GITHUB_OUTPUT. The tag carries
# no revision: the commit may sit before or after the release.json bump.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
commit=$(git -C "$root" rev-parse --verify "${1:?usage: develop-tag.sh <commit>}^{commit}")
version=$(jq -er '.ffmpeg.version' "$root/release.json" | tr -d '\r')

# revision tags compare numerically, not as SemVer
last_release=$(git -C "$root" tag -l --merged "$commit" | grep -Ex '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+' |
    awk -F'[.-]' '{ printf "%d %d %d %d %s\n", $1, $2, $3, $4, $0 }' |
    sort -k1,1n -k2,2n -k3,3n -k4,4n | tail -n 1 | cut -d' ' -f5)

echo "tag=$version-$(printf '%s' "$commit" | cut -c1-8)-develop"
echo "last_release=$last_release"
