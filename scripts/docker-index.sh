#!/bin/sh
# Usage: docker-index.sh <image> <tag> <digests dir>
# Creates <image>:<tag> from the platform digests that build.yml uploaded (one
# empty file per digest) and prints digest=<index digest> for $GITHUB_OUTPUT.
# A tag left by a partial publication is reused only if it holds exactly these
# platform images; the tag is never moved.
set -eu

image=$1 tag=$2 digests=$3

set --
for f in "$digests"/*; do set -- "$@" "$image@sha256:${f##*/}"; done
[ $# -eq 2 ] || { echo "::error::expected 2 platform digests, got $#" >&2; exit 1; }
want=$(printf '%s\n' "$@" | sed 's/.*@//' | sort)
if ! docker buildx imagetools inspect "$image:$tag" >/dev/null 2>&1; then
    docker buildx imagetools create -t "$image:$tag" "$@" >&2
fi
have=$(docker buildx imagetools inspect --raw "$image:$tag" | jq -r '.manifests[].digest' | sort)
[ "$have" = "$want" ] || { echo "::error::$image:$tag holds other images:" >&2; echo "$have" >&2; exit 1; }
digest=$(docker buildx imagetools inspect "$image:$tag" --format '{{json .Manifest}}' | jq -er .digest)
echo "digest=$digest"
