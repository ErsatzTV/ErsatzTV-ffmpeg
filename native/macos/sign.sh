#!/bin/sh
# Usage: sign.sh <archive>
# Signs bin/ffmpeg and bin/ffprobe in a build.sh archive with the Developer ID
# in the keychain (hardened runtime, secure timestamp), notarizes them, and
# rewrites the archive in place. Needs AC_USERNAME and AC_PASSWORD (an
# app-specific password). A bare Mach-O can't be stapled: Gatekeeper fetches
# the ticket online.
set -eu

archive=$1
team=32MB98Q32R
: "${AC_USERNAME:?}" "${AC_PASSWORD:?}"

name=$(basename "$archive" .tar.xz)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar -xJf "$archive" -C "$work"

for bin in "$work/$name"/bin/*; do
    codesign --force --timestamp --options=runtime --sign "Developer ID Application" "$bin"
    codesign --verify --strict --verbose=2 "$bin"
    codesign -dv --verbose=2 "$bin" 2>&1 | grep -qx "TeamIdentifier=$team" ||
        { echo "sign: $bin is not signed by team $team" >&2; exit 1; }
done

ditto -c -k --keepParent "$work/$name/bin" "$work/notarize.zip"
result=$(xcrun notarytool submit "$work/notarize.zip" \
    --apple-id "$AC_USERNAME" --password "$AC_PASSWORD" --team-id "$team" \
    --wait --timeout 30m --output-format json)
echo "$result"
id=$(echo "$result" | jq -r .id)
if [ "$(echo "$result" | jq -r .status)" != Accepted ]; then
    xcrun notarytool log "$id" --apple-id "$AC_USERNAME" --password "$AC_PASSWORD" --team-id "$team" || true
    echo "sign: notarization $id was not accepted" >&2
    exit 1
fi

# no AppleDouble ._ entries for extended attributes
COPYFILE_DISABLE=1 tar -cJf "$archive" -C "$work" "$name"
echo "sign: $archive signed and notarized ($id)"
