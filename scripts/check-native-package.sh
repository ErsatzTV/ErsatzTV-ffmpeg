#!/bin/sh
# Usage: check-native-package.sh <archive> <target> <upstream version> <extra version> <dest> [unsigned|signed]
# Checks a native build archive's name and layout, extracts it into <dest>, and
# runs verify-ffmpeg.sh on it. The name must keep ending in
# -<target>-gpl-8.1.tar.xz: the Proxmox install script globs for it.
# macOS targets must be checked on macOS: they add otool/lipo/vtool checks, and
# with 'signed' the Developer ID signature and notarization (online).
set -eu

archive=$1 target=$2 version=$3 extra=$4 dest=$5 signing=${6:-unsigned}
here=$(cd "$(dirname "$0")" && pwd)

fail() {
    echo "check-native-package: $*" >&2
    exit 1
}

case "$target" in
    win64) ext=zip exe=.exe tools="ffmpeg ffprobe" ;;
    linux64 | linuxarm64) ext=tar.xz exe='' tools="ffmpeg ffprobe" ;;
    macos64) ext=tar.xz exe='' tools="ffmpeg ffprobe" arch=x86_64 ;;
    macosarm64) ext=tar.xz exe='' tools="ffmpeg ffprobe" arch=arm64 ;;
    *) fail "unknown target '$target'" ;;
esac
case "$signing" in
    unsigned) ;;
    signed) case "$target" in macos*) ;; *) fail "only macOS targets are signed" ;; esac ;;
    *) fail "expected unsigned or signed, got '$signing'" ;;
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
for tool in $tools; do
    [ -f "$root/bin/$tool$exe" ] || fail "missing bin/$tool$exe"
    [ -n "$exe" ] || [ -x "$root/bin/$tool" ] || fail "bin/$tool is not executable"
done
# the fork ignores an unknown FF_CONFIGURE_EXTRA, so a lost --disable-ffplay would only show here
[ ! -e "$root/bin/ffplay$exe" ] || fail "unexpected bin/ffplay$exe"

sh "$here/verify-ffmpeg.sh" "$root/bin" "$version" "$extra"

case "$target" in
    macos*) ;;
    *) exit 0 ;;
esac

minos=$(jq -er '.deployment_target' "$here/../native/macos/deps.json")
for tool in $tools; do
    bin="$root/bin/$tool"
    [ "$(lipo -archs "$bin")" = "$arch" ] || fail "$tool is $(lipo -archs "$bin"), expected $arch"
    # everything else is statically linked; Homebrew or @rpath here means a leak
    foreign=$(otool -L "$bin" | tail -n +2 | awk '{ print $1 }' |
        grep -v -E '^(/usr/lib/|/System/Library/Frameworks/)' || true)
    [ -z "$foreign" ] || fail "$tool links outside the OS: $(echo "$foreign" | tr '\n' ' ')"
    got=$(vtool -show-build "$bin" | awk '$1 == "minos" { print $2 }')
    [ "$got" = "$minos" ] || fail "$tool minos is '$got', expected $minos"
    [ "$signing" = signed ] || continue
    # the linker ad-hoc signs every arm64 binary, so a valid signature alone proves nothing
    codesign --verify --strict "$bin" || fail "$tool has an invalid signature"
    info=$(codesign -dv --verbose=2 "$bin" 2>&1)
    echo "$info" | grep -qx 'TeamIdentifier=32MB98Q32R' || fail "$tool is not signed by the ErsatzTV Developer ID"
    echo "$info" | grep -Eq '^CodeDirectory .*flags=.*\(runtime\)' || fail "$tool has no hardened runtime"
    echo "$info" | grep -q '^Timestamp=' || fail "$tool has no secure timestamp"
    expected=''
    [ "$target/$tool" != macos64/ffmpeg ] ||
        expected='{"com.apple.security.cs.allow-unsigned-executable-memory":true}'
    xml=$(codesign -d --entitlements - --xml "$bin" 2>/dev/null || true)
    got=''
    [ -z "$xml" ] || got=$(echo "$xml" | plutil -convert json -o - -)
    [ "$got" = "$expected" ] || fail "$tool has entitlements '$got', expected '$expected'"
    # spctl rejects every bare executable as "not an app"; codesign can ask for the ticket
    codesign --verify --strict --check-notarization -R=notarized "$bin" || fail "$tool is not notarized"
done

# features the build only gets by autodetection or that ErsatzTV depends on
has() {
    "$root/bin/ffmpeg" -hide_banner "$1" 2>/dev/null | grep -Eq "$2" || fail "ffmpeg $1 lacks $3"
}
has -hwaccels '^videotoolbox$' videotoolbox
has -encoders ' h264_videotoolbox ' h264_videotoolbox
has -encoders ' hevc_videotoolbox ' hevc_videotoolbox
has -encoders ' aac_at ' aac_at
has -filters ' scale_vt ' scale_vt
for proto in https tls srt; do
    has -protocols "^ +$proto\$" "$proto"
done
echo "check-native-package: macOS checks ok ($target, minos $minos, $signing)"
