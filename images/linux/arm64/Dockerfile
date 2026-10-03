# check=skip=InvalidDefaultArgInFrom
# DEPS_IMAGE: the image from images/linux/deps.lock.json
ARG DEPS_IMAGE
ARG BASE_IMAGE=ghcr.io/linuxserver/baseimage-ubuntu
ARG BASE_IMAGE_TAG=arm64v8-noble

FROM ${DEPS_IMAGE} AS devel-base

# ffmpeg (version inputs come from release.json via scripts/release-vars.sh)
ARG FFMPEG_VERSION
ARG FFMPEG_SHA256
COPY patches/*.patch /tmp/ffmpeg-patches/
RUN : "${FFMPEG_VERSION:?build arg required}" "${FFMPEG_SHA256:?build arg required}" && \
    mkdir -p /tmp/ffmpeg && \
    curl -Lf -o /tmp/ffmpeg.tar.bz2 \
    https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.bz2 && \
    echo "${FFMPEG_SHA256}  /tmp/ffmpeg.tar.bz2" | sha256sum -c - && \
    tar -jx --strip-components=1 -C /tmp/ffmpeg -f /tmp/ffmpeg.tar.bz2 && \
    rm /tmp/ffmpeg.tar.bz2 && \
    for p in /tmp/ffmpeg-patches/*.patch; do \
    [ -e "$p" ] || continue; \
    echo "Applying FFmpeg patch: $p"; \
    git -C /tmp/ffmpeg apply --verbose "$p" || exit 1; \
    done
ARG FFMPEG_EXTRA_VERSION
RUN : "${FFMPEG_EXTRA_VERSION:?build arg required}" && \
    cd /tmp/ffmpeg && \
    ./configure \
    --disable-debug \
    --disable-doc \
    --disable-ffplay \
    --enable-ffprobe \
    --enable-fontconfig \
    --enable-gpl \
    --enable-libaom \
    --enable-libdav1d \
    --enable-libass \
    --enable-libfreetype \
    --enable-libharfbuzz \
    --enable-libkvazaar \
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
    --enable-libzimg \
    --enable-openssl \
    --enable-stripping \
    --enable-version3 \
    --extra-version=${FFMPEG_EXTRA_VERSION} \
    --extra-libs=-ldl \
    --extra-libs=-lpthread && \
    make

RUN ldconfig && \
    mkdir -p /buildout/usr/local/bin && \
    cp \
    /tmp/ffmpeg/ffmpeg \
    /buildout/usr/local/bin && \
    cp \
    /tmp/ffmpeg/ffprobe \
    /buildout/usr/local/bin && \
    mkdir -p /buildout/usr/lib && \
    ldd /tmp/ffmpeg/ffmpeg \
    | awk '/local/ {print $3}' \
    | xargs -i cp -L {} /buildout/usr/lib/

FROM ${BASE_IMAGE}:${BASE_IMAGE_TAG} AS runtime-base

ENV MAKEFLAGS="-j4"

RUN apt-get -yqq update && \
    DEBIAN_FRONTEND="noninteractive" apt-get install -yq --no-install-recommends ca-certificates expat libgomp1 libharfbuzz-bin libxml2 libxcb-shape0 libv4l-0 \
    && apt autoremove -y \
    && rm -rf /var/lib/apt/lists/*

COPY --from=devel-base /buildout/ /

RUN apt-get update && \
    apt-get install -y libicu-dev tzdata fontconfig fonts-noto-core fonts-noto-cjk libgdiplus libdrm2 && \
    rm -rf /var/lib/apt/lists/*

ARG FFMPEG_VERSION
ARG FFMPEG_EXTRA_VERSION
RUN --mount=type=bind,source=scripts/verify-ffmpeg.sh,target=/tmp/verify-ffmpeg.sh \
    sh /tmp/verify-ffmpeg.sh /usr/local/bin "${FFMPEG_VERSION}" "${FFMPEG_EXTRA_VERSION}"

CMD         ["--help"]
ENTRYPOINT  ["ffmpeg"]
