# Build dependencies of the ffmpeg image. The image built from this file is
# pinned by digest in images/linux/deps.lock.json; a change here needs a
# deps.yml run and a new lock file (docs/building.md).

ARG BASE_IMAGE=ghcr.io/linuxserver/baseimage-ubuntu
ARG BASE_IMAGE_TAG=noble

FROM ${BASE_IMAGE}:${BASE_IMAGE_TAG} AS build

ENV DEBIAN_FRONTEND="noninteractive"
ENV MAKEFLAGS="-j4" \
    PATH="/root/.cargo/bin:${PATH}"

ENV AOM=v3.14.1 \
    FONTCONFIG=2.16.0 \
    FREETYPE=2.14.3 \
    FRIBIDI=1.0.16 \
    GMMLIB=22.10.0 \
    IHD=26.1.5 \
    KVAZAAR=2.3.2 \
    LAME=3.100 \
    LIBASS=0.17.5 \
    LIBDAV1D=1.5.3 \
    LIBDOVI=2.3.2 \
    LIBDRM=2.4.134 \
    LIBGL=1.7.0 \
    LIBPLACEBO=7.360.1 \
    LIBSRT=1.5.5 \
    LIBVA=2.23.0 \
    LIBVDPAU=1.5 \
    LIBWEBP=1.6.0 \
    MESA=26.0.3 \
    NVCODEC=11.1.5.3 \
    OGG=1.3.5 \
    OPENCOREAMR=0.1.6 \
    OPENJPEG=2.5.4 \
    OPUS=1.6 \
    SHADERC=v2026.2 \
    THEORA=1.1.1 \
    VORBIS=1.3.7 \
    VPX=1.16.0 \
    VULKANSDK=vulkan-sdk-1.4.350.1 \
    X265=4.2 \
    XVID=1.3.7 \
    ZIMG=3.0.6

RUN apt-get -yqq update && \
    apt-get install -y gpg-agent wget && \
    wget -qO - https://repositories.intel.com/gpu/intel-graphics.key | \
    gpg --dearmor --output /usr/share/keyrings/intel-graphics.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/intel-graphics.gpg] https://repositories.intel.com/gpu/ubuntu noble unified" | \
    tee  /etc/apt/sources.list.d/intel.gpu.noble.list && \
    apt-get -yqq update && \
    apt-get install -yq \
    libmfx-dev \
    libegl1-mesa-dev \
    libgl1-mesa-dev \
    libgles2-mesa-dev \
    libigc-dev \
    intel-igc-cm \
    libigdfcl-dev \
    libigfxcmrt-dev \
    level-zero-dev \
    libvpl-dev && \
    apt-get -yq --no-install-recommends install -y \
    autoconf \
    automake \
    autopoint \
    bison \
    bzip2 \
    ca-certificates \
    clang \
    cmake \
    curl \
    diffutils \
    doxygen \
    expat \
    flex \
    g++ \
    gcc \
    gettext \
    git \
    gperf \
    jq \
    libelf-dev \
    libexpat1-dev \
    libxext-dev \
    libgcc-9-dev \
    libgomp1 \
    libharfbuzz-dev \
    libpciaccess-dev \
    libssl-dev \
    libtool \
    libv4l-dev \
    libwayland-dev \
    libwayland-egl-backend-dev \
    libx11-dev \
    libx11-xcb-dev \
    libxcb-dri2-0-dev \
    libxcb-dri3-dev \
    libxcb-glx0-dev \
    libxcb-present-dev \
    libxcb-shape0-dev \
    libxml2-dev \
    libxrandr-dev \
    libzstd-dev \
    make \
    nasm \
    ocl-icd-opencl-dev \
    patch \
    perl \
    pkg-config \
    python3-venv \
    x11proto-xext-dev \
    xserver-xorg-dev \
    xz-utils \
    yasm \
    zlib1g-dev && \
    apt-get autoremove -y && \
    apt-get clean -y && \
    mkdir -p /tmp/rust && \
    RUST_VERSION=$(curl -fsX GET https://api.github.com/repos/rust-lang/rust/releases/latest | jq -r '.tag_name') && \
    curl -fo /tmp/rust.tar.gz -L "https://static.rust-lang.org/dist/rust-${RUST_VERSION}-x86_64-unknown-linux-gnu.tar.gz" && \
    tar xf /tmp/rust.tar.gz -C /tmp/rust --strip-components=1 && \
    cd /tmp/rust && \
    ./install.sh && \
    cargo install cargo-c cbindgen --locked && \
    python3 -m venv /lsiopy && \
    pip install -U --no-cache-dir \
    pip \
    setuptools \
    wheel && \
    pip install --no-cache-dir cmake==3.31.6 mako meson ninja packaging ply pyyaml

# cuda
RUN mkdir -p /tmp/cuda && \
    cd /tmp/cuda && \
    wget -q https://developer.download.nvidia.com/compute/cuda/11.4.4/local_installers/cuda_11.4.4_470.82.01_linux.run && \
    sh cuda_11.4.4_470.82.01_linux.run --silent --toolkit --override && \
    rm cuda_11.4.4_470.82.01_linux.run

# aom
RUN mkdir -p /tmp/aom && \
    git clone \
    --branch ${AOM} \
    --depth 1 https://aomedia.googlesource.com/aom \
    /tmp/aom
RUN cd /tmp/aom && \
    rm -rf \
    CMakeCache.txt \
    CMakeFiles && \
    mkdir -p \
    aom_build && \
    cd aom_build && \
    cmake \
    -DBUILD_STATIC_LIBS=0 .. && \
    make && \
    make install

# ffnvcodec
RUN mkdir -p /tmp/ffnvcodec && \
    git clone \
    --branch n${NVCODEC} \
    --depth 1 https://github.com/FFmpeg/nv-codec-headers \
    /tmp/ffnvcodec
RUN cd /tmp/ffnvcodec && \
    make install

# freetype
RUN mkdir -p /tmp/freetype && \
    { curl -Lf -o /tmp/freetype.tar.gz \
    https://downloads.sourceforge.net/project/freetype/freetype2/${FREETYPE}/freetype-${FREETYPE}.tar.gz || \
    curl -Lf -o /tmp/freetype.tar.gz \
    https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE}.tar.gz ; } && \
    tar -zxf /tmp/freetype.tar.gz --strip-components=1 -C /tmp/freetype && \
    rm /tmp/freetype.tar.gz
RUN cd /tmp/freetype && \
    ./configure \
    --disable-static \
    --enable-shared && \
    make && \
    make install && \
    strip -d /usr/local/lib/libfreetype.so

# fontconfig
RUN mkdir -p /tmp/fontconfig && \
    curl -Lf \
    https://github.com/fontconfig/fontconfig/archive/refs/tags/${FONTCONFIG}.tar.gz | \
    tar -zx --strip-components=1 -C /tmp/fontconfig
RUN cd /tmp/fontconfig && \
    ./autogen.sh \
    --disable-cache-build \
    --disable-static \
    --enable-shared && \
    make && \
    make install && \
    strip -d /usr/local/lib/libfontconfig.so

# fribidi
RUN mkdir -p /tmp/fribidi && \
    curl -Lf \
    https://github.com/fribidi/fribidi/archive/v${FRIBIDI}.tar.gz | \
    tar -zx --strip-components=1 -C /tmp/fribidi
RUN cd /tmp/fribidi && \
    ./autogen.sh && \
    ./configure \
    --disable-static \
    --enable-shared && \
    make -j 1 && \
    make install && \
    strip -d /usr/local/lib/libfribidi.so

# kvazaar
RUN mkdir -p /tmp/kvazaar && \
    curl -Lf \
    https://github.com/ultravideo/kvazaar/archive/v${KVAZAAR}.tar.gz | \
    tar -zx --strip-components=1 -C /tmp/kvazaar
RUN cd /tmp/kvazaar && \
    ./autogen.sh && \
    ./configure \
    --disable-static \
    --enable-shared && \
    make && \
    make install && \
    strip -d /usr/local/lib/libkvazaar.so

# lame
RUN mkdir -p /tmp/lame && \
    curl -Lf \
    http://downloads.sourceforge.net/project/lame/lame/3.100/lame-${LAME}.tar.gz | \
    tar -zx --strip-components=1 -C /tmp/lame
RUN cd /tmp/lame && \
    cp \
    /usr/share/automake-1.16/config.guess \
    config.guess && \
    cp \
    /usr/share/automake-1.16/config.sub \
    config.sub && \
    ./configure \
    --disable-frontend \
    --disable-static \
    --enable-nasm \
    --enable-shared && \
    make && \
    make install

# libass
RUN mkdir -p /tmp/libass && \
    curl -Lf \
    https://github.com/libass/libass/archive/${LIBASS}.tar.gz | \
    tar -zx --strip-components=1 -C /tmp/libass
RUN cd /tmp/libass && \
    ./autogen.sh && \
    ./configure \
    --disable-static \
    --enable-shared && \
    make && \
    make install && \
    strip -d /usr/local/lib/libass.so

# libdav1d
RUN mkdir -p /tmp/libdav1d && \
    git clone \
    --branch ${LIBDAV1D} \
    --depth 1 https://github.com/videolan/dav1d.git \
    /tmp/libdav1d
RUN mkdir /tmp/libdav1d/build && cd /tmp/libdav1d/build && \
    meson setup -Denable_tools=false -Denable_tests=false --libdir /usr/local/lib .. && \
    ninja install

# libgl
# prefix=/usr so the EGL vendor dir is /usr/share/glvnd/egl_vendor.d, where the
# nvidia container runtime and mesa put their vendor json; a /usr/local prefix
# hides them, which breaks the nvidia vulkan icd (it enumerates devices via EGL)
RUN mkdir -p /tmp/libgl && \
    curl -Lf \
    https://gitlab.freedesktop.org/glvnd/libglvnd/-/archive/v${LIBGL}/libglvnd-v${LIBGL}.tar.gz | \
    tar -xz --strip-components=1 -C /tmp/libgl
RUN cd /tmp/libgl && \
    meson setup \
    --buildtype=release \
    --prefix=/usr \
    --libdir=/usr/local/lib/x86_64-linux-gnu \
    build && \
    ninja -C build install && \
    strip -d \
    /usr/local/lib/x86_64-linux-gnu/libEGL.so \
    /usr/local/lib/x86_64-linux-gnu/libGLdispatch.so \
    /usr/local/lib/x86_64-linux-gnu/libGLESv1_CM.so \
    /usr/local/lib/x86_64-linux-gnu/libGLESv2.so \
    /usr/local/lib/x86_64-linux-gnu/libGL.so \
    /usr/local/lib/x86_64-linux-gnu/libGLX.so \
    /usr/local/lib/x86_64-linux-gnu/libOpenGL.so

# libdrm
RUN mkdir -p /tmp/libdrm && \
    curl -Lf \
    https://dri.freedesktop.org/libdrm/libdrm-${LIBDRM}.tar.xz | \
    tar -Jx --strip-components=1 -C /tmp/libdrm
RUN cd /tmp/libdrm && \
    meson setup \
    --prefix=/usr --libdir=/usr/local/lib/x86_64-linux-gnu \
    -Dvalgrind=disabled \
    . build && \
    ninja -C build && \
    ninja -C build install && \
    strip -d /usr/local/lib/x86_64-linux-gnu/libdrm*.so

# libdovi
RUN mkdir -p /tmp/libdovi && \
    git clone \
    --branch ${LIBDOVI} \
    https://github.com/quietvoid/dovi_tool.git \
    /tmp/libdovi
RUN cd /tmp/libdovi/dolby_vision && \
    cargo cinstall --release --libdir=/usr/local/lib/x86_64-linux-gnu && \
    strip -d /usr/local/lib/x86_64-linux-gnu/libdovi.so

# libsrt
RUN mkdir -p /tmp/libsrt && \
    curl -Lf \
    https://github.com/Haivision/srt/archive/v${LIBSRT}.tar.gz | \
    tar -zx --strip-components=1 -C /tmp/libsrt
RUN cd /tmp/libsrt && \
    cmake . && \
    make && \
    make install

# libva
RUN mkdir -p /tmp/libva && \
    curl -Lf \
    https://github.com/intel/libva/archive/${LIBVA}.tar.gz | \
    tar -zx --strip-components=1 -C /tmp/libva
RUN cd /tmp/libva && \
    ./autogen.sh && \
    ./configure \
    --libdir=/usr/local/lib/x86_64-linux-gnu \
    --disable-static \
    --enable-shared && \
    make && \
    make install && \
    strip -d \
    /usr/local/lib/x86_64-linux-gnu/libva.so \
    /usr/local/lib/x86_64-linux-gnu/libva-drm.so \
    /usr/local/lib/x86_64-linux-gnu/libva-wayland.so

# libvdpau
RUN mkdir -p /tmp/libvdpau && \
    git clone \
    --branch ${LIBVDPAU} \
    --depth 1 https://gitlab.freedesktop.org/vdpau/libvdpau.git \
    /tmp/libvdpau
RUN cd /tmp/libvdpau && \
    meson setup \
    --prefix=/usr --libdir=/usr/local/lib \
    -Ddocumentation=false \
    build && \
    ninja -C build install && \
    strip -d /usr/local/lib/libvdpau.so

# gmm
RUN mkdir -p /tmp/gmmlib && \
    curl -Lf \
    https://github.com/intel/gmmlib/archive/refs/tags/intel-gmmlib-${GMMLIB}.tar.gz | \
    tar -zx --strip-components=1 -C /tmp/gmmlib
RUN mkdir -p /tmp/gmmlib/build && \
    cd /tmp/gmmlib/build && \
    cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_LIBDIR=lib/x86_64-linux-gnu \
    .. && \
    make && \
    make install && \
    strip -d /usr/local/lib/x86_64-linux-gnu/libigdgmm.so

# iHD
RUN mkdir -p /tmp/ihd && \
    curl -Lf \
    https://github.com/intel/media-driver/archive/refs/tags/intel-media-${IHD}.tar.gz | \
    tar -zx --strip-components=1 -C /tmp/ihd
RUN mkdir -p /tmp/ihd/build && \
    cd /tmp/ihd/build && \
    cmake \
    -DLIBVA_DRIVERS_PATH=/usr/local/lib/x86_64-linux-gnu/dri/ \
    .. && \
    make && \
    make install && \
    strip -d /usr/local/lib/x86_64-linux-gnu/dri/iHD_drv_video.so

# mesa gallium va drivers
# must be built against the libva above: the va frontend gates
# VASurfaceAttribAlignmentSize behind a compile-time VA_CHECK_VERSION(1, 21, 0),
# so distro mesa built against an older libva reports no encode alignment
RUN mkdir -p /tmp/mesa && \
    curl -Lf \
    https://archive.mesa3d.org/mesa-${MESA}.tar.xz | \
    tar -Jx --strip-components=1 -C /tmp/mesa
RUN cd /tmp/mesa && \
    meson setup build \
    --prefix=/usr/local \
    --libdir=lib/x86_64-linux-gnu \
    --buildtype=release \
    -Dgallium-drivers=radeonsi,r600,nouveau,virgl \
    -Dvulkan-drivers= \
    -Dplatforms= \
    -Dgallium-va=enabled \
    -Dva-libs-path=/usr/local/lib/x86_64-linux-gnu/dri \
    -Dvideo-codecs=all \
    -Dllvm=disabled \
    -Damd-use-llvm=false \
    -Dopengl=false \
    -Dgles1=disabled \
    -Dgles2=disabled \
    -Dglx=disabled \
    -Degl=disabled \
    -Dgbm=disabled \
    -Dshared-glapi=disabled \
    -Dgallium-rusticl=false \
    -Dbuild-tests=false && \
    ninja -C build install && \
    strip -d /usr/local/lib/x86_64-linux-gnu/dri/libgallium_drv_video.so

# shaderc
RUN mkdir -p /tmp/shaderc && \
    git clone \
    --branch ${SHADERC} \
    --depth 1 https://github.com/google/shaderc.git \
    /tmp/shaderc
RUN cd /tmp/shaderc && \
    ./utils/git-sync-deps && \
    mkdir -p build && \
    cd build && \
    cmake -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    .. && \
    ninja install

# libwebp
RUN mkdir -p /tmp/libwebp && \
    curl -Lf \
    https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${LIBWEBP}.tar.gz | \
    tar -zx --strip-components=1 -C /tmp/libwebp
RUN cd /tmp/libwebp && \
    ./configure \
    --disable-static \
    --enable-shared && \
    make && \
    make install

# ogg
RUN mkdir -p /tmp/ogg && \
    curl -Lf \
    http://downloads.xiph.org/releases/ogg/libogg-${OGG}.tar.gz | \
    tar -zx --strip-components=1 -C /tmp/ogg
RUN cd /tmp/ogg && \
    ./configure \
    --disable-static \
    --enable-shared && \
    make && \
    make install

# opencore-amr
RUN mkdir -p /tmp/opencore-amr && \
    curl -Lf \
    http://downloads.sourceforge.net/project/opencore-amr/opencore-amr/opencore-amr-${OPENCOREAMR}.tar.gz | \
    tar -zx --strip-components=1 -C /tmp/opencore-amr
RUN cd /tmp/opencore-amr && \
    ./configure \
    --disable-static \
    --enable-shared  && \
    make && \
    make install && \
    strip -d /usr/local/lib/libopencore-amr*.so

# openjpeg
RUN mkdir -p /tmp/openjpeg && \
    curl -Lf \
    https://github.com/uclouvain/openjpeg/archive/v${OPENJPEG}.tar.gz | \
    tar -zx --strip-components=1 -C /tmp/openjpeg
RUN cd /tmp/openjpeg && \
    rm -Rf \
    thirdparty/libpng/* && \
    curl -Lf \
    https://download.sourceforge.net/libpng/libpng-1.6.37.tar.gz | \
    tar -zx --strip-components=1 -C thirdparty/libpng/ && \
    cmake \
    -DBUILD_STATIC_LIBS=0 \
    -DBUILD_THIRDPARTY:BOOL=ON . && \
    make && \
    make install

# opus
RUN mkdir -p /tmp/opus && \
    curl -Lf \
    https://downloads.xiph.org/releases/opus/opus-${OPUS}.tar.gz | \
    tar -zx --strip-components=1 -C /tmp/opus
RUN cd /tmp/opus && \
    autoreconf -fiv && \
    ./configure \
    --disable-static \
    --enable-shared && \
    make && \
    make install && \
    strip -d /usr/local/lib/libopus.so

# theora
RUN mkdir -p /tmp/theora && \
    curl -Lf \
    http://downloads.xiph.org/releases/theora/libtheora-${THEORA}.tar.gz | \
    tar -zx --strip-components=1 -C /tmp/theora
RUN cd /tmp/theora && \
    cp \
    /usr/share/automake-1.16/config.guess \
    config.guess && \
    cp \
    /usr/share/automake-1.16/config.sub \
    config.sub && \
    curl -fL \
    'https://gitlab.xiph.org/xiph/theora/-/commit/7288b539c52e99168488dc3a343845c9365617c8.diff' \
    > png.patch && \
    patch ./examples/png2theora.c < png.patch && \
    ./configure \
    --disable-static \
    --enable-shared && \
    make && \
    make install

# vorbis
RUN mkdir -p /tmp/vorbis && \
    curl -Lf \
    http://downloads.xiph.org/releases/vorbis/libvorbis-${VORBIS}.tar.gz | \
    tar -zx --strip-components=1 -C /tmp/vorbis
RUN cd /tmp/vorbis && \
    ./configure \
    --disable-static \
    --enable-shared && \
    make && \
    make install

# vpx
RUN mkdir -p /tmp/vpx && \
    curl -Lf \
    https://github.com/webmproject/libvpx/archive/v${VPX}.tar.gz | \
    tar -zx --strip-components=1 -C /tmp/vpx
RUN cd /tmp/vpx && \
    ./configure \
    --disable-debug \
    --disable-docs \
    --disable-examples \
    --disable-install-bins \
    --disable-static \
    --disable-unit-tests \
    --enable-pic \
    --enable-shared \
    --enable-vp8 \
    --enable-vp9 \
    --enable-vp9-highbitdepth && \
    make && \
    make install

# vulkan
RUN mkdir -p /tmp/vulkan-headers && \
    git clone \
    --branch ${VULKANSDK} \
    --depth 1 https://github.com/KhronosGroup/Vulkan-Headers.git \
    /tmp/vulkan-headers
RUN cd /tmp/vulkan-headers && \
    cmake -S . -B build/ && \
    cmake --install build --prefix /usr/local

RUN mkdir -p /tmp/vulkan-loader && \
    git clone \
    --branch ${VULKANSDK} \
    --depth 1 https://github.com/KhronosGroup/Vulkan-Loader.git \
    /tmp/vulkan-loader
RUN cd /tmp/vulkan-loader && \
    mkdir -p build && \
    cd build && \
    cmake \
    -D CMAKE_BUILD_TYPE=Release \
    -D VULKAN_HEADERS_INSTALL_DIR=/usr/local/lib/x86_64-linux-gnu \
    -D CMAKE_INSTALL_PREFIX=/usr/local \
    .. && \
    make && \
    make install

# libplacebo
# must build after shaderc and vulkan; meson defaults both to 'auto', so building
# earlier silently produces a libplacebo with no spir-v compiler, which fails at
# runtime with "Failed initializing any SPIR-V compiler"
RUN mkdir -p /tmp/libplacebo && \
    git clone \
    --branch v${LIBPLACEBO} \
    --recursive https://code.videolan.org/videolan/libplacebo \
    /tmp/libplacebo
RUN cd /tmp/libplacebo && \
    meson setup \
    --prefix=/usr --libdir=/usr/local/lib/x86_64-linux-gnu \
    -Dvulkan=enabled \
    -Dshaderc=enabled \
    . build --buildtype release && \
    ninja -C build install

# x264
RUN mkdir -p /tmp/x264 && \
    git clone --branch stable --depth 1 https://github.com/mirror/x264 /tmp/x264
RUN cd /tmp/x264 && \
    ./configure \
    --disable-cli \
    --disable-static \
    --enable-pic \
    --enable-shared && \
    make && \
    make install

# x265
RUN mkdir -p /tmp/x265 && \
    curl -Lf \
    https://bitbucket.org/multicoreware/x265_git/downloads/x265_${X265}.tar.gz | \
    tar -zx --strip-components=1 -C /tmp/x265
RUN cd /tmp/x265/build/linux && \
    ./multilib.sh && \
    make -C 8bit install

# xvid
RUN mkdir -p /tmp/xvid && \
    curl -Lf \
    https://downloads.xvid.com/downloads/xvidcore-${XVID}.tar.gz | \
    tar -zx --strip-components=1 -C /tmp/xvid
RUN cd /tmp/xvid/build/generic && \
    ./configure && \ 
    make && \
    make install

# zimg
RUN mkdir -p /tmp/zimg && \
    git clone \
    --branch release-${ZIMG} --depth 1 \
    https://github.com/sekrit-twc/zimg.git \
    /tmp/zimg
RUN cd /tmp/zimg && \
    ./autogen.sh && \
    ./configure \
    --disable-static \
    --enable-shared && \
    make && \
    make install

# rust's own shared libraries would otherwise land in /usr/local/lib next to the
# ones the ffmpeg image copies out
RUN /usr/local/lib/rustlib/uninstall.sh && \
    rm -rf /tmp/* /root/.cargo/registry /root/.cargo/git

# one layer without the source and build trees the steps above leave in /tmp
FROM ${BASE_IMAGE}:${BASE_IMAGE_TAG}
COPY --from=build / /
ENV DEBIAN_FRONTEND="noninteractive" \
    MAKEFLAGS="-j4"
