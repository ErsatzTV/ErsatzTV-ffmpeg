#!/bin/sh
# Usage: check-native-package.sh <archive> <target> <upstream version> <extra version> <dest>
# Checks a native build archive's name and layout, extracts it into <dest>, and
# runs verify-ffmpeg.sh on it. The name must keep ending in
# -<target>-gpl-8.1.tar.xz: the Proxmox install script globs for it.
set -eu

archive=$1 target=$2 version=$3 extra=$4 dest=$5
here=$(cd "$(dirname "$0")" && pwd)

fail() {
    echo "check-native-package: $*" >&2
    exit 1
}

case "$target" in
    win64) ext=zip exe=.exe ;;
    linux64 | linuxarm64) ext=tar.xz exe= ;;
    *) fail "unknown target '$target'" ;;
esac

name="ffmpeg-n$version-$extra-$target-gpl-8.1"
[ "$(basename "$archive")" = "$name.$ext" ] ||
    fail "expected $name.$ext, got $(basename "$archive")"

mkdir -p "$dest"
case "$ext" in
    tar.xz)
        top=$(tar -tJf "$archive" | cut -d/ -f1 | sort -u)
        tar -xJf "$archive" -C "$dest"
        ;;
    zip)
        top=$(7z l -slt "$archive" | sed -n 's/^Path = //p' | tail -n +2 | tr '\\' / | cut -d/ -f1 | sort -u)
        7z x -y -bso0 -o"$dest" "$archive"
        ;;
esac
[ "$top" = "$name" ] || fail "expected a single top-level $name/, got: $(echo "$top" | tr '\n' ' ')"

root="$dest/$name"
[ -f "$root/LICENSE.txt" ] || fail "missing LICENSE.txt"
grep -q 'GNU GENERAL PUBLIC LICENSE' "$root/LICENSE.txt" || fail "LICENSE.txt is not the GPL"
for tool in ffmpeg ffprobe ffplay; do
    [ -f "$root/bin/$tool$exe" ] || fail "missing bin/$tool$exe"
    [ -n "$exe" ] || [ -x "$root/bin/$tool" ] || fail "bin/$tool is not executable"
done

sh "$here/verify-ffmpeg.sh" "$root/bin" "$version" "$extra"
