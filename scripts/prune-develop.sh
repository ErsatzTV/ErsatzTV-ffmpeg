#!/bin/sh
# Usage: prune-develop.sh releases <repo> <keep>
#        prune-develop.sh images <image> <keep>
# Keeps the newest <keep> develop builds. 'releases' deletes older develop
# releases and their tags, and every draft. 'images' deletes older develop
# indexes from GHCR together with their platform images and the sha256-<digest>
# referrer tags that hold their attestations. Callers must hold the develop
# concurrency group, or an in-flight run's draft gets deleted. DRY_RUN=1 only
# prints. Needs gh with GH_TOKEN, and for images a registry login.
set -eu

kind=${1:?usage: prune-develop.sh releases|images <repo|image> <keep>} target=${2:?} keep=${3:?}
case "$keep" in '' | *[!0-9]*) echo "prune-develop: keep must be a non-negative integer" >&2; exit 1 ;; esac
pattern='^[0-9]+\.[0-9]+\.[0-9]+-[0-9a-f]{8}-develop$'

run() {
    if [ -n "${DRY_RUN:-}" ]; then echo "would run: $*"; else "$@"; fi
}

case "$kind" in
releases)
    releases=$(gh release list --repo "$target" --limit 1000 --json tagName,isDraft,publishedAt |
        jq --arg p "$pattern" '[.[] | select(.tagName | test($p))]')
    drafts=$(printf '%s' "$releases" | jq -r 'map(select(.isDraft)) | .[].tagName')
    expired=$(printf '%s' "$releases" | jq -r --argjson keep "$keep" \
        'map(select(.isDraft | not)) | sort_by(.publishedAt) | reverse | .[$keep:] | .[].tagName')
    # drafts have no tag until published
    for tag in $drafts; do
        echo "deleting draft $tag"
        run gh release delete "$tag" --repo "$target" --yes
    done
    for tag in $expired; do
        echo "deleting $tag"
        run gh release delete "$tag" --repo "$target" --cleanup-tag --yes
    done
    ;;
images)
    # ghcr.io/<owner>/<package>
    owner=$(echo "$target" | cut -d/ -f2) package=$(echo "$target" | cut -d/ -f3-)
    if ! pages=$(gh api --paginate "/orgs/$owner/packages/container/$package/versions" 2>&1); then
        case "$pages" in
            *"Package not found"*) echo "no package $target yet"; exit 0 ;;
            *) echo "$pages" >&2; exit 1 ;;
        esac
    fi
    versions=$(printf '%s' "$pages" | jq -s 'add')
    expired=$(printf '%s' "$versions" | jq -r --argjson keep "$keep" --arg p "$pattern" \
        '[.[] | select(any(.metadata.container.tags[]; test($p)))] | sort_by(.created_at) | reverse | .[$keep:] | .[].name')

    doomed=$(mktemp)
    trap 'rm -f "$doomed"' EXIT
    children() { docker buildx imagetools inspect --raw "$target@$1" | jq -r '.manifests[]?.digest'; }
    for index in $expired; do
        echo "expiring $target@$index"
        for d in $index $(children "$index"); do
            echo "$d"
            referrer=$(printf '%s' "$versions" | jq -r --arg t "sha256-${d#sha256:}" \
                '.[] | select(any(.metadata.container.tags[]; . == $t)) | .name')
            for r in $referrer; do
                echo "$r"
                children "$r"
            done
        done >> "$doomed"
    done

    printf '%s' "$versions" | jq -r --rawfile doomed "$doomed" \
        '($doomed | split("\n") | map(select(. != ""))) as $d | .[] | select(.name as $n | $d | index($n)) | "\(.id) \(.name)"' |
        while read -r id name; do
            echo "deleting $name"
            run gh api -X DELETE "/orgs/$owner/packages/container/$package/versions/$id" --silent
        done
    ;;
*)
    echo "prune-develop: unknown kind '$kind'" >&2
    exit 1
    ;;
esac
