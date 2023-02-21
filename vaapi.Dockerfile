FROM ghcr.io/linuxserver/baseimage-ubuntu:jammy as devel-base

ENV DEBIAN_FRONTEND="noninteractive"
ENV MAKEFLAGS="-j4"

ARG GMMLIB=22.3.3 \
    LIBVA=2.17.0 \
    LIBVA_UTILS=2.17.1 \
    MEDIA_DRIVER=23.1.0

ENV AOM=v1.0.0 \
    FDKAAC=2.0.1 \
    FFMPEG_HARD=5.1.2 \
    FONTCONFIG=2.13.92 \
    FREETYPE=2.10.4 \
    FRIBIDI=1.0.8 \
    KVAZAAR=2.0.0 \
    LAME=3.100 \
    LIBASS=0.14.0 \
    LIBDRM=2.4.100 \
    LIBSRT=1.4.1 \
    LIBVA=$LIBVA \
    LIBVDPAU=1.2 \
    LIBVIDSTAB=1.1.0 \
    LIBWEBP=1.0.2 \
    OGG=1.3.4 \
    OPENCOREAMR=0.1.5 \
    OPENJPEG=2.3.1 \
    OPUS=1.3 \
    THEORA=1.1.1 \
    VORBIS=1.3.7 \
    VPX=1.10.0 \
    X265=3.4 \
    XVID=1.3.7 

RUN apt-get -yqq update && \ 
    apt-get -yq --no-install-recommends install -y \
    autoconf \
    automake \
    bzip2 \
    ca-certificates \
    cmake \
    curl \
    diffutils \
    doxygen \
    expat \
    g++ \
    gcc \
    git \
    gperf \
    libexpat1-dev \
    libxext-dev \
    libgcc-9-dev \
    libgomp1 \
    libmfx-dev \
    libpciaccess-dev \
    libssl-dev \
    libtool \
    libv4l-dev \
    libx11-dev \
    libxcb-shape0-dev \
    libxml2-dev \
    make \
    nasm \
    ninja-build \
    ocl-icd-opencl-dev \
    patch \
    perl \
    pkg-config \
    python3 \
    python3-pip\
    python3-setuptools \
    python3-wheel \
    x11proto-xext-dev \
    xserver-xorg-dev \
    yasm \
    zlib1g-dev && \
    apt-get autoremove -y && \
    apt-get clean -y && \
    pip3 install meson

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

# fdk-aac
RUN mkdir -p /tmp/fdk-aac && \
    curl -Lf \
    https://github.com/mstorsjo/fdk-aac/archive/v${FDKAAC}.tar.gz | \
    tar -zx --strip-components=1 -C /tmp/fdk-aac
RUN cd /tmp/fdk-aac && \
    autoreconf -fiv && \
    ./configure \
    --disable-static \
    --enable-shared && \
    make && \
    make install

# freetype
RUN mkdir -p /tmp/freetype && \
    curl -Lf \
    https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE}.tar.gz | \
    tar -zx --strip-components=1 -C /tmp/freetype
RUN cd /tmp/freetype && \
    ./configure \
    --disable-static \
    --enable-shared && \
    make && \
    make install

# fontconfig
RUN mkdir -p /tmp/fontconfig && \
    curl -Lf \
    https://www.freedesktop.org/software/fontconfig/release/fontconfig-${FONTCONFIG}.tar.gz | \
    tar -zx --strip-components=1 -C /tmp/fontconfig
RUN cd /tmp/fontconfig && \
    ./configure \
    --disable-static \
    --enable-shared && \
    make && \
    make install

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
    make install

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
    make install

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
    make install

# libdrm
RUN mkdir -p /tmp/libdrm && \
    curl -Lf \
    https://dri.freedesktop.org/libdrm/libdrm-${LIBDRM}.tar.gz | \
    tar -zx --strip-components=1 -C /tmp/libdrm
RUN cd /tmp/libdrm && \
    ./configure \
    --disable-nouveau \
    --disable-static \
    --enable-shared && \
    make && \
    make install

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
    --disable-static \
    --enable-shared && \
    make && \
    make install

# libvdpau
RUN mkdir -p /tmp/libvdpau && \
    git clone \
    --branch libvdpau-${LIBVDPAU} \
    --depth 1 https://gitlab.freedesktop.org/vdpau/libvdpau.git \
    /tmp/libvdpau
RUN cd /tmp/libvdpau && \
    ./autogen.sh && \
    ./configure \
    --disable-static \
    --enable-shared && \
    make && \
    make install

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
    make install

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
    https://archive.mozilla.org/pub/opus/opus-${OPUS}.tar.gz | \
    tar -zx --strip-components=1 -C /tmp/opus
RUN cd /tmp/opus && \
    autoreconf -fiv && \
    ./configure \
    --disable-static \
    --enable-shared && \
    make && \
    make install

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

# vid.stab
RUN mkdir -p /tmp/vid.stab && \
    curl -Lf \
    https://github.com/georgmartius/vid.stab/archive/v${LIBVIDSTAB}.tar.gz | \
    tar -zx --strip-components=1 -C /tmp/vid.stab
RUN cd /tmp/vid.stab && \
    cmake \
    -DBUILD_STATIC_LIBS=0 . && \
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

# x264
RUN mkdir -p /tmp/x264 && \
    curl -Lf \
    https://code.videolan.org/videolan/x264/-/archive/master/x264-stable.tar.bz2 | \
    tar -jx --strip-components=1 -C /tmp/x264
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
    http://anduin.linuxfromscratch.org/BLFS/x265/x265_${X265}.tar.gz | \
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

# ffmpeg
RUN if [ -z ${FFMPEG_VERSION+x} ]; then \
    FFMPEG=${FFMPEG_HARD}; \
    else \
    FFMPEG=${FFMPEG_VERSION}; \
    fi && \
    mkdir -p /tmp/ffmpeg && \
    echo "https://ffmpeg.org/releases/ffmpeg-${FFMPEG}.tar.bz2" && \
    curl -Lf \
    https://ffmpeg.org/releases/ffmpeg-${FFMPEG}.tar.bz2 | \
    tar -jx --strip-components=1 -C /tmp/ffmpeg
RUN cd /tmp/ffmpeg && \
    ./configure \
    --disable-debug \
    --disable-doc \
    --disable-ffplay \
    --enable-ffprobe \
    --enable-fontconfig \
    --enable-gpl \
    --enable-libaom \
    --enable-libass \
    --enable-libfdk_aac \
    --enable-libfreetype \
    --enable-libkvazaar \
    --enable-libmfx \
    --enable-libmp3lame \
    --enable-libopencore-amrnb \
    --enable-libopencore-amrwb \
    --enable-libopenjpeg \
    --enable-libopus \
    --enable-libsrt \
    --enable-libtheora \
    --enable-libv4l2 \
    --enable-libvidstab \
    --enable-libvorbis \
    --enable-libvpx \
    --enable-libwebp \
    --enable-libxml2 \
    --enable-libx264 \
    --enable-libx265 \
    --enable-libxvid \
    --enable-nonfree \
    --enable-opencl \
    --enable-openssl \
    --enable-small \
    --enable-stripping \
    --enable-vaapi \
    --enable-vdpau \
    --enable-version3 \
    --extra-libs=-ldl \
    --extra-libs=-lpthread && \
    make

RUN ldconfig && \
    mkdir -p \
    /buildout/usr/local/bin \
    /buildout/usr/lib && \
    cp \
    /tmp/ffmpeg/ffmpeg \
    /buildout/usr/local/bin && \
    cp \
    /tmp/ffmpeg/ffprobe \
    /buildout/usr/local/bin && \
    ldd /tmp/ffmpeg/ffmpeg \
    | awk '/local/ {print $3}' \
    | xargs -i cp -L {} /buildout/usr/lib/ && \
    cp -a \
    /usr/local/lib/libdrm_* \
    /buildout/usr/lib/

FROM mcr.microsoft.com/dotnet/aspnet:7.0-jammy-amd64 AS dotnet-runtime
FROM ghcr.io/linuxserver/baseimage-ubuntu:jammy as runtime-base

ARG GMMLIB=22.3.3 \
    LIBVA=2.17.0 \
    LIBVA_UTILS=2.17.1 \
    MEDIA_DRIVER=23.1.0

ENV MAKEFLAGS="-j4"

RUN apt-get -yqq update && \
    DEBIAN_FRONTEND="noninteractive" apt-get install -yq --no-install-recommends ca-certificates expat libgomp1 libxcb-shape0 libv4l-0 \
    && apt autoremove -y \
    && rm -rf /var/lib/apt/lists/*

COPY --from=devel-base /buildout/ /
COPY --from=dotnet-runtime /usr/share/dotnet /usr/share/dotnet

RUN apt-get -yqq update && DEBIAN_FRONTEND="noninteractive" apt-get install --no-install-recommends -y \
    libicu-dev \
    tzdata \
    fontconfig \
    fonts-dejavu \
    libgdiplus \
    autoconf \
    automake \
    libtool \
    libdrm-dev \
    libmfx-dev \
    ocl-icd-opencl-dev \
    git \
    pkg-config \
    build-essential \
    cmake \
    wget \
    mesa-va-drivers \
    i965-va-driver-shaders \
    && mkdir /tmp/intel && cd /tmp/intel \
    && git clone --depth 1 --branch "${LIBVA}" https://github.com/intel/libva \
    && cd libva \
    && ./autogen.sh \
    && ./configure \
    && make \
    && make install \
    && cd /tmp/intel \
    && git clone --depth 1 --branch "${LIBVA_UTILS}" https://github.com/intel/libva-utils \
    && cd libva-utils \
    && ./autogen.sh \
    && ./configure \
    && make \
    && make install \
    && cd /tmp/intel \
    && wget -O - "https://github.com/intel/gmmlib/archive/refs/tags/intel-gmmlib-${GMMLIB}.tar.gz" | tar zxf - \
    && mv "gmmlib-intel-gmmlib-${GMMLIB}" gmmlib \
    && cd gmmlib \
    && mkdir build && cd build \
    && cmake .. \
    && make \
    && make install \
    && cd /tmp/intel \
    && git clone --depth 1 --branch "intel-media-${MEDIA_DRIVER}" https://github.com/intel/media-driver \
    && mkdir build_media && cd build_media \
    && cmake ../media-driver \
    && make \
    && make install \
    && apt-get purge -y autoconf automake libtool git build-essential cmake wget \
    && apt autoremove -y \
    && rm -rf /tmp/intel \
    && rm -rf /var/lib/apt/lists/* \
    && mv /usr/lib/x86_64-linux-gnu/dri/* /usr/local/lib/dri/

CMD         ["--help"]
ENTRYPOINT  ["ffmpeg"]
