#!/bin/sh
# Usage: check-docker-lock.sh
# Fails unless images/linux/deps.lock.json pins, for each docker platform, a
# dependency image built from the current images/linux/<arch>/deps.Dockerfile:
# the lock's recipe hash must match the file, and the image's recipe label and
# architecture must match the lock. A recipe change needs a deps.yml run and a
# new lock file. Needs read access to the image registry.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
lock="$root/images/linux/deps.lock.json"
repo=ghcr.io/ersatztv/ersatztv-ffmpeg-deps

fail() {
    echo "check-docker-lock: $*" >&2
    exit 1
}

jq -e --arg repo "$repo" '
    keys == ["amd64", "arm64"]
    and all(.[]; (.recipe | test("^sha256:[0-9a-f]{64}$"))
        and (.image | type == "string" and startswith("\($repo)@sha256:") and test("@sha256:[0-9a-f]{64}$")))
' "$lock" >/dev/null || fail "malformed $lock; run deps.yml and use the lock file it exports"

for arch in amd64 arm64; do
    recipe=$(jq -r --arg a "$arch" '.[$a].recipe' "$lock")
    image=$(jq -r --arg a "$arch" '.[$a].image' "$lock")
    file="images/linux/$arch/deps.Dockerfile"
    have="sha256:$(sha256sum "$root/$file" | cut -d' ' -f1)"
    [ "$recipe" = "$have" ] ||
        fail "$file changed since the locked image was built ($recipe, now $have); run deps.yml and update $lock"

    config=$(docker buildx imagetools inspect "$image" --format '{{json .Image}}') ||
        fail "cannot inspect $image"
    printf '%s' "$config" | jq -e --arg a "$arch" --arg r "$recipe" '
        .os == "linux" and .architecture == $a
        and .config.Labels["org.ersatztv.ffmpeg.deps-recipe"] == $r
    ' >/dev/null || fail "$image is not a linux/$arch image labeled with recipe $recipe"
done

echo "check-docker-lock: ok"
