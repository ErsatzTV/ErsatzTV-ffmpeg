#!/bin/sh
# Usage: needs-build.sh <base commit> <head commit>
# Prints build=true or build=false for $GITHUB_OUTPUT. A change needs no build
# when it only touches docs, release notes, or the revision in release.json:
# dev builds take their version from the commit, not the revision, so the
# build inputs are those of the base. Needs the history of both commits.
set -eu

base=$1 head=$2

if [ -z "$base" ] || [ "$base" = 0000000000000000000000000000000000000000 ]; then
    echo build=true
    exit 0
fi

# a PR's own changes, not what main gained since it branched
base=$(git merge-base "$base" "$head")
for file in $(git diff --name-only "$base" "$head"); do
    case "$file" in
        README.md | docs/* | release-notes/*) ;;
        release.json)
            old=$(git show "$base:release.json" | jq -S 'del(.revision)')
            new=$(git show "$head:release.json" | jq -S 'del(.revision)')
            if [ "$old" != "$new" ]; then
                echo "needs-build: release.json changes more than the revision" >&2
                echo build=true
                exit 0
            fi
            ;;
        *)
            echo "needs-build: $file is a build input" >&2
            echo build=true
            exit 0
            ;;
    esac
done
echo "needs-build: only docs, release notes or the revision changed" >&2
echo build=false
