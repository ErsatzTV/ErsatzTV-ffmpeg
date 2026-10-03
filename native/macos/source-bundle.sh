#!/bin/sh
# Usage: source-bundle.sh <out.tar>
# Downloads every native/macos/deps.json tarball, checks its sha256 and packs
# them with deps.json into one uncompressed tar (the tarballs are already
# compressed): the GPL corresponding source of the macOS dependencies. Runs on
# Linux or macOS, so release preflight finds a dead or changed URL before
# anything builds.
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
out=$1
deps="$root/native/macos/deps.json"

if command -v sha256sum >/dev/null; then
    sha256() { sha256sum -c -; }
else
    sha256() { shasum -a 256 -c -; }
fi

top=$(basename "$out" .tar)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/$top"
cp "$deps" "$work/$top/"

jq -c '.deps[]' "$deps" | while read -r dep; do
    name=$(echo "$dep" | jq -er .name)
    version=$(echo "$dep" | jq -er .version)
    url=$(echo "$dep" | jq -er .url)
    sha=$(echo "$dep" | jq -er .sha256)
    echo "$sha" | grep -Eqx '[0-9a-f]{64}' || { echo "source-bundle: $name has no sha256" >&2; exit 1; }
    case "$url" in
        *.tar.gz) ext=tar.gz ;;
        *.tar.xz) ext=tar.xz ;;
        *.tar.bz2) ext=tar.bz2 ;;
        *) echo "source-bundle: $name: unknown archive type: $url" >&2; exit 1 ;;
    esac
    file="$work/$top/$name-$version.$ext"
    curl -fsSL --retry 3 -o "$file" "$url"
    echo "$sha  $file" | sha256
done

tar -cf "$out" -C "$work" "$top"
echo "source-bundle: $out ($(du -h "$out" | cut -f1))"
