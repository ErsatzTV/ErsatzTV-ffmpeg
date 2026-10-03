#!/bin/sh
# Usage: build-deps.sh <macos64|macosarm64>
# Builds every native/macos/deps.json entry, in order, as a static library into
# native/macos/work/<target>/prefix, then writes prefix/.complete. CI caches
# that prefix, keyed on this script, env.sh, deps.json and the Xcode build.
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
target=$1
. "$root/native/macos/env.sh"

if [ "$cross" = 1 ]; then
    echo "build-deps: cross-compiling $target is not implemented yet" >&2
    exit 1
fi

deps="$root/native/macos/deps.json"
aux=$(automake --print-libdir)
sdk=$(xcrun --show-sdk-path)

group() { [ -z "${GITHUB_ACTIONS:-}" ] || echo "::group::$*"; }
endgroup() { [ -z "${GITHUB_ACTIONS:-}" ] || echo "::endgroup::"; }

fetch() {
    url=$(jq -er --arg n "$1" '.deps[] | select(.name == $n) | .url' "$deps")
    sha=$(jq -er --arg n "$1" '.deps[] | select(.name == $n) | .sha256' "$deps")
    file="$work/deps/$1.tar"
    curl -fsSL --retry 3 -o "$file" "$url"
    echo "$sha  $file" | shasum -a 256 -c -
    mkdir "$work/deps/$1"
    tar -xf "$file" -C "$work/deps/$1" --strip-components=1
    rm "$file"
    cd "$work/deps/$1"
}

# config.guess and config.sub that predate Apple Silicon detect arm64 as 32-bit arm
refresh_aux() {
    find . -name config.guess -o -name config.sub | while read -r f; do
        cp "$aux/$(basename "$f")" "$f"
    done
}

autotools() {
    refresh_aux
    ./configure --prefix="$prefix" --enable-static --disable-shared "$@"
    make -j"$jobs"
    make install
}

# cmake_configure <source dir> <build dir> [args]
cmake_configure() {
    src=$1 build=$2
    shift 2
    cmake -S "$src" -B "$build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_PREFIX_PATH="$prefix" \
        -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DBUILD_SHARED_LIBS=OFF \
        "$@"
}

cmake_build() {
    cmake_configure . _build "$@"
    cmake --build _build
    cmake --install _build
}

meson_build() {
    meson setup _build --prefix="$prefix" --libdir=lib --buildtype=release --default-library=static "$@"
    meson compile -C _build
    meson install -C _build
}

build_openssl() {
    # OpenSSL's own optimisation flags; MACOSX_DEPLOYMENT_TARGET still sets minos.
    # openssldir makes it read macOS's /etc/ssl/cert.pem for verification.
    unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
    ./Configure "darwin64-$arch-cc" no-shared no-docs no-tests \
        --prefix="$prefix" --libdir=lib --openssldir=/private/etc/ssl
    make -j"$jobs" build_libs
    make install_dev
}

build_freetype() {
    autotools --without-png --without-harfbuzz --without-brotli --without-bzip2 --with-zlib=yes
}

build_fribidi() {
    meson_build -Ddocs=false -Dbin=false -Dtests=false
}

build_harfbuzz() {
    meson_build -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled \
        -Dchafa=disabled -Dpng=disabled -Dzlib=disabled -Dicu=disabled \
        -Draster=disabled -Dvector=disabled -Dgpu=disabled -Dgpu_demo=disabled \
        -Dsubset=disabled -Dtests=disabled -Dintrospection=disabled -Ddocs=disabled \
        -Dutilities=disabled
}

build_libass() {
    autotools --disable-fontconfig --enable-coretext
}

build_aom() {
    cmake_build -DENABLE_TESTS=0 -DENABLE_EXAMPLES=0 -DENABLE_DOCS=0 -DENABLE_TOOLS=0 \
        -DCONFIG_RUNTIME_CPU_DETECT=1
}

build_dav1d() {
    meson_build -Denable_tools=false -Denable_tests=false
}

build_kvazaar() {
    autotools
}

build_lame() {
    autotools --disable-frontend --disable-gtktest
}

build_ogg() {
    autotools
}

build_vorbis() {
    # a PowerPC-era flag that Xcode 16's linker rejects
    sed -i '' 's/ -force_cpusubtype_ALL//' configure
    autotools --disable-oggtest --disable-docs --disable-examples
}

build_theora() {
    autotools --disable-oggtest --disable-vorbistest --disable-examples --disable-doc --disable-spec
}

build_opus() {
    autotools --disable-doc --disable-extra-programs
}

build_opencore_amr() {
    autotools
}

build_openjpeg() {
    cmake_build -DBUILD_CODEC=OFF -DBUILD_TESTING=OFF
}

build_srt() {
    cmake_build -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DENABLE_APPS=OFF \
        -DENABLE_ENCRYPTION=ON -DUSE_ENCLIB=openssl-evp \
        -DOPENSSL_ROOT_DIR="$prefix" -DOPENSSL_USE_STATIC_LIBS=ON
}

build_libwebp() {
    autotools --disable-png --disable-jpeg --disable-tiff --disable-gif --disable-wic \
        --disable-sdl --disable-gl --enable-libwebpmux --enable-libwebpdemux
}

build_vidstab() {
    # as docker: the SSE2 path doesn't build position-independent
    : > CMakeModules/FindSSE.cmake
    cmake_build -DUSE_OMP=OFF
}

build_vpx() {
    ./configure --prefix="$prefix" --target="$arch-darwin24-gcc" \
        --disable-shared --enable-static --enable-pic --enable-runtime-cpu-detect \
        --disable-examples --disable-tools --disable-docs --disable-unit-tests \
        --enable-vp8 --enable-vp9 --enable-vp9-highbitdepth
    make -j"$jobs"
    make install
}

build_x264() {
    refresh_aux
    ./configure --prefix="$prefix" --host="$host" --enable-static --enable-pic --disable-cli
    make -j"$jobs"
    make install
}

build_x265() {
    # 10- and 12-bit encoding comes from extra bit-depth libraries merged into
    # the 8-bit one, as x265's multilib.sh does for shared builds
    set -- -DENABLE_SHARED=OFF -DENABLE_CLI=OFF
    if [ "$arch" = arm64 ]; then
        # otherwise x265 compiles in whatever Neon/SVE extensions the build machine has
        set -- "$@" -DAARCH64_RUNTIME_CPU_DETECT=ON
    fi
    cmake_configure source _12 "$@" -DHIGH_BIT_DEPTH=ON -DMAIN12=ON -DEXPORT_C_API=OFF
    cmake --build _12
    cmake_configure source _10 "$@" -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF
    cmake --build _10
    mkdir _8
    cp _12/libx265.a _8/libx265_main12.a
    cp _10/libx265.a _8/libx265_main10.a
    cmake_configure source _8 "$@" -DLINKED_10BIT=ON -DLINKED_12BIT=ON \
        -DEXTRA_LIB="x265_main10.a;x265_main12.a" -DEXTRA_LINK_FLAGS=-L.
    cmake --build _8
    mv _8/libx265.a _8/libx265_main.a
    libtool -static -o _8/libx265.a _8/libx265_main.a _8/libx265_main10.a _8/libx265_main12.a
    cmake --install _8
}

build_xvid() {
    cd build/generic
    autotools --disable-assembly
}

build_zimg() {
    ./autogen.sh
    autotools
}

rm -rf "$work/deps" "$prefix"
mkdir -p "$work/deps" "$prefix/lib/pkgconfig"

# freetype and ffmpeg look for zlib and libxml2 through pkg-config, which can't see the SDK
cat > "$prefix/lib/pkgconfig/zlib.pc" <<EOF
Name: zlib
Description: zlib from the macOS SDK
Version: $(sed -n 's/^#define ZLIB_VERSION "\(.*\)".*/\1/p' "$sdk/usr/include/zlib.h")
Libs: -lz
EOF
cat > "$prefix/lib/pkgconfig/libxml-2.0.pc" <<EOF
Name: libXML
Description: libxml2 from the macOS SDK
Version: $(sed -n 's/^#define LIBXML_DOTTED_VERSION "\(.*\)".*/\1/p' "$sdk/usr/include/libxml2/libxml/xmlversion.h")
Cflags: -I$sdk/usr/include/libxml2
Libs: -lxml2
EOF

for name in $(jq -r '.deps[].name' "$deps"); do
    group "$name"
    (
        fetch "$name"
        "build_$(echo "$name" | tr - _)"
    )
    endgroup
done

# ld64 prefers a .dylib over a .a of the same name; nothing may link dynamically
find "$prefix/lib" \( -name '*.dylib' -o -name '*.la' \) -delete
touch "$prefix/.complete"
