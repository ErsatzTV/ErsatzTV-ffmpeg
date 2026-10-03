# Sourced by build-deps.sh and build.sh with $root and $target set. Everything
# here feeds the dependency cache key, so keep ffmpeg-only settings out of it.

case "$target" in
    macosarm64) arch=arm64 host=aarch64-apple-darwin ;;
    macos64) arch=x86_64 host=x86_64-apple-darwin ;;
    *) echo "macos: unknown target '$target'" >&2; exit 1 ;;
esac

[ "$(uname -s)" = Darwin ] || { echo "macos: must run on macOS" >&2; exit 1; }

cross=0
[ "$(uname -m)" = "$arch" ] || cross=1

work="$root/native/macos/work/$target"
prefix="$work/prefix"
jobs=$(sysctl -n hw.ncpu)

MACOSX_DEPLOYMENT_TARGET=$(jq -er '.deployment_target' "$root/native/macos/deps.json")
export MACOSX_DEPLOYMENT_TARGET

archflags="-arch $arch -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
export CC=clang CXX=clang++
export CFLAGS="$archflags -O2" CXXFLAGS="$archflags -O2"
export CPPFLAGS="-I$prefix/include"
export LDFLAGS="$archflags -L$prefix/lib"

# LIBDIR, not PATH: replaces pkg-config's default search path, so Homebrew's
# .pc files on the runner can't satisfy a dependency
export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
unset PKG_CONFIG_PATH
