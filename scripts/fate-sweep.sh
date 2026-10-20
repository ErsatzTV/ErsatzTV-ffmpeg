#!/bin/sh
# Usage: fate-sweep.sh <work dir> [samples dir]
# Runs FFmpeg's FATE suite, samples included, on the release.json tarball with
# and without this repo's patch set, and reports the tests that fail only with
# the patches. Tests that also fail on stock are environment noise and only
# listed.
#
# FATE runs the binaries of a configured source tree, not a release build. Both
# trees use a plain configure (no autodetected host libraries, so results do
# not depend on what the host has installed), so this covers the software-side
# patches; hardware paths need the reproducers in patches/tests/.
#
# <work dir> must not exist yet or be empty, and must be outside any git
# checkout. The samples dir (~1.4 GB) is kept between runs; it defaults to
# ${XDG_CACHE_HOME:-~/.cache}/ersatztv-ffmpeg/fate-suite.
#
# Env: JOBS (default: nproc), FATE_CONFIGURE_EXTRA (extra configure args for
# both trees).
#
# Exit: 0 no new failures, 1 new failures, 2 setup or build error.
set -eu
# comm needs every list in the same byte order
export LC_ALL=C

root=$(cd "$(dirname "$0")/.." && pwd)
work=${1:?usage: fate-sweep.sh <work dir> [samples dir]}
samples=${2:-${XDG_CACHE_HOME:-$HOME/.cache}/ersatztv-ffmpeg/fate-suite}
jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN)}

fail() {
    echo "fate-sweep: $*" >&2
    exit 2
}

if [ -e "$work" ] && [ -n "$(ls -A "$work")" ]; then
    fail "$work is not empty"
fi
mkdir -p "$work" "$samples"
work=$(cd "$work" && pwd)
samples=$(cd "$samples" && pwd)

echo "fate-sweep: verifying upstream and applying $(ls "$root"/patches/*.patch | wc -l) patches"
sh "$root/scripts/check-upstream.sh" "$work" >"$work/check-upstream.log" 2>&1 ||
    { cat "$work/check-upstream.log" >&2; fail "check-upstream failed"; }
version=$(jq -er '.ffmpeg.version' "$root/release.json")
for tree in stock patched; do
    mkdir "$work/$tree"
    tar -jx --strip-components=1 -C "$work/$tree" -f "$work/ffmpeg-$version.tar.bz2"
done
for p in "$root"/patches/*.patch; do
    git -C "$work/patched" apply "$p" || fail "does not apply: patches/$(basename "$p")"
done

echo "fate-sweep: syncing samples into $samples"
rsync -rltLW --timeout=60 --contimeout=60 rsync://fate-suite.ffmpeg.org/fate-suite/ "$samples/" ||
    fail "sample sync failed"

configure_args="--disable-doc --disable-autodetect --samples=$samples"
# zlib covers png, tiff and compressed matroska tests; it is the one host
# library worth having, and both trees get the same answer
if pkg-config --exists zlib 2>/dev/null; then
    configure_args="$configure_args --enable-zlib"
fi
configure_args="$configure_args ${FATE_CONFIGURE_EXTRA:-}"

for tree in stock patched; do
    dir="$work/$tree"
    echo "fate-sweep: $tree: configure and build"
    # shellcheck disable=SC2086 # word splitting is intended
    (cd "$dir" && ./configure $configure_args) >"$work/$tree-configure.log" 2>&1 ||
        fail "$tree: configure failed, see $work/$tree-configure.log"
    make -C "$dir" -j"$jobs" >"$work/$tree-make.log" 2>&1 ||
        fail "$tree: build failed, see $work/$tree-make.log"

    echo "fate-sweep: $tree: running FATE"
    start=$(date +%s)
    # -k: one failing test must not stop the rest; failures are read from the
    # .rep files below, not from make's exit status
    make -C "$dir" -k -j"$jobs" fate >"$work/$tree-fate.log" 2>&1 || true
    echo "fate-sweep: $tree: FATE took $(( $(date +%s) - start ))s"

    make -s --no-print-directory -C "$dir" fate-list | sort >"$work/$tree-expected.txt"
    (cd "$dir/tests/data/fate" && for f in *.rep; do
        [ -e "$f" ] && awk -F: '{ print "fate-" $1, ($2 == 0 ? "pass" : "fail") }' "$f"
    done) | sort >"$work/$tree-reports.txt"
    awk '$2 == "fail" { print $1 }' "$work/$tree-reports.txt" >"$work/$tree-failed.txt"
    # no .rep: the test's setup failed (missing sample, test data that did not
    # build), or make fate never targets it (fate-list includes the fate-hw
    # tests, fate does not)
    cut -d' ' -f1 "$work/$tree-reports.txt" | comm -23 "$work/$tree-expected.txt" - >"$work/$tree-not-run.txt"
    sort -m "$work/$tree-failed.txt" "$work/$tree-not-run.txt" >"$work/$tree-bad.txt"
done

comm -13 "$work/stock-bad.txt" "$work/patched-bad.txt" >"$work/new-failures.txt"
comm -12 "$work/stock-bad.txt" "$work/patched-bad.txt" >"$work/both-bad.txt"
comm -23 "$work/stock-bad.txt" "$work/patched-bad.txt" >"$work/fixed.txt"
comm -3 "$work/stock-expected.txt" "$work/patched-expected.txt" >"$work/test-set-diff.txt"

count() { wc -l <"$1" | tr -d ' '; }

echo
echo "tests:        $(count "$work/stock-expected.txt") stock, $(count "$work/patched-expected.txt") patched"
echo "failed:       $(count "$work/stock-failed.txt") stock, $(count "$work/patched-failed.txt") patched"
echo "not run:      $(count "$work/stock-not-run.txt") stock, $(count "$work/patched-not-run.txt") patched"
echo "both trees:   $(count "$work/both-bad.txt") failed or not run (environment, see both-bad.txt)"
echo "fixed:        $(count "$work/fixed.txt") (bad on stock, pass patched)"
if [ -s "$work/test-set-diff.txt" ]; then
    echo "test set differs between trees (stock-only left, patched-only indented):"
    sed 's/^/    /' "$work/test-set-diff.txt"
fi

if [ -s "$work/new-failures.txt" ]; then
    echo "NEW FAILURES with the patch set:"
    sed 's/^/    /' "$work/new-failures.txt"
    echo "logs: $work/patched/tests/data/fate/<test>.err and .diff"
    exit 1
fi

echo "no new failures with the patch set"
