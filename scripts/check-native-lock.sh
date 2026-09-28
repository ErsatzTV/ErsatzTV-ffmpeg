#!/bin/sh
# Usage: check-native-lock.sh
# Fails unless native/images.lock.json still describes the dependency images for
# the pinned native/FFmpeg-Builds commit: the lock's fork_commit must be an
# ancestor of the submodule HEAD, and nothing that feeds deps.yml may differ
# between them. A build-glue-only bump passes and reuses the locked digests; a
# recipe change needs a deps.yml run and a new lock file.
# Needs the submodule's full history (not a depth-1 checkout).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
lock="$root/native/images.lock.json"
fork="$root/native/FFmpeg-Builds"

fail() {
    echo "check-native-lock: $*" >&2
    exit 1
}

jq -e '
    .variant == "gpl 8.1"
    and (.fork_commit | test("^[0-9a-f]{40}$"))
    and (.images | keys == ["linux64", "linuxarm64", "win64"])
    and (.images | to_entries | all(.value == "ghcr.io/ersatztv/ffmpeg-builds/\(.key)-gpl-8.1@\(.value | split("@")[1])"
        and (.value | test("@sha256:[0-9a-f]{64}$"))))
' "$lock" >/dev/null || fail "malformed $lock"

locked=$(jq -r '.fork_commit' "$lock")
head=$(git -C "$fork" rev-parse HEAD)

git -C "$fork" cat-file -e "$locked^{commit}" 2>/dev/null ||
    fail "lock fork_commit $locked not found in the submodule (shallow clone?)"
git -C "$fork" merge-base --is-ancestor "$locked" "$head" ||
    fail "lock fork_commit $locked is not an ancestor of submodule HEAD $head"

# exactly the paths that trigger deps.yml in the fork
recipes="scripts.d patches images variants addins util generate.sh download.sh
    .github/buildkit.toml .github/workflows/deps.yml"
# shellcheck disable=SC2086
if ! git -C "$fork" diff --quiet "$locked" "$head" -- $recipes; then
    # shellcheck disable=SC2086
    git -C "$fork" diff --stat "$locked" "$head" -- $recipes >&2
    fail "dependency recipes changed since $locked; run deps.yml and update $lock"
fi

echo "check-native-lock: ok (lock $locked, submodule $head)"
