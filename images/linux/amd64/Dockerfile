# check=skip=InvalidDefaultArgInFrom
# DEPS_IMAGE: the image from images/linux/deps.lock.json
ARG DEPS_IMAGE
ARG BASE_IMAGE=ghcr.io/linuxserver/baseimage-ubuntu
ARG BASE_IMAGE_TAG=noble

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
    --ld=clang++ \
    --disable-debug \
    --disable-doc \
    --disable-ffplay \
    --enable-cuda \
    --enable-cuda-llvm \
    --enable-cuvid \
    --enable-ffprobe \
    --enable-fontconfig \
    --enable-gpl \
    --enable-libaom \
    --enable-libdav1d \
    --enable-libass \
    --enable-libfontconfig \
    --enable-libfreetype \
    --enable-libfribidi \
    --enable-libharfbuzz \
    --enable-libkvazaar \
    --enable-libmp3lame \
    --enable-libopencore-amrnb \
    --enable-libopencore-amrwb \
    --enable-libopenjpeg \
    --enable-libopus \
    --enable-libplacebo \
    --enable-libshaderc \
    --enable-libsrt \
    --enable-libtheora \
    --enable-libv4l2 \
    --enable-libvorbis \
    --enable-libvpl \
    --enable-libvpx \
    --enable-libwebp \
    --enable-libxml2 \
    --enable-libx264 \
    --enable-libx265 \
    --enable-libxvid \
    --enable-libzimg \
    --enable-nvdec \
    --enable-nvenc \
    --enable-opencl \
    --enable-openssl \
    --enable-stripping \
    --enable-vaapi \
    --enable-vdpau \
    --enable-version3 \
    --enable-vulkan \
    --extra-version=${FFMPEG_EXTRA_VERSION} \
    --extra-libs=-ldl \
    --extra-libs=-lpthread && \
    make

RUN ldconfig && \
    mkdir -p \
    /buildout/usr/local/bin \
    /buildout/usr/lib \
    /buildout/usr/local/lib/x86_64-linux-gnu/dri \
    /buildout/usr/local/lib/x86_64-linux-gnu/vdpau \
    /buildout/usr/local/share/vulkan \
    /buildout/usr/share/libdrm \
    /buildout/etc/OpenCL/vendors && \
    cp \
    /tmp/ffmpeg/ffmpeg \
    /buildout/usr/local/bin && \
    cp \
    /tmp/ffmpeg/ffprobe \
    /buildout/usr/local/bin && \
    cp -a \
    /usr/local/lib/lib*so* \
    /buildout/usr/local/lib/ && \
    cp -a \
    /usr/local/lib/x86_64-linux-gnu/lib*so* \
    /buildout/usr/local/lib/x86_64-linux-gnu/ && \
    cp -a \
    /usr/local/lib/x86_64-linux-gnu/dri/*.so \
    /buildout/usr/local/lib/x86_64-linux-gnu/dri/ && \
    cp -a \
    /usr/share/libdrm/amdgpu.ids \
    /buildout/usr/share/libdrm/ && \
    cp -a \
    /usr/local/share/vulkan/* \
    /buildout/usr/local/share/vulkan/ && \
    echo \
    'libnvidia-opencl.so.1' > \
    /buildout/etc/OpenCL/vendors/nvidia.icd

FROM ${BASE_IMAGE}:${BASE_IMAGE_TAG} AS runtime-base

COPY --from=devel-base /buildout/ /

ARG DEBIAN_FRONTEND="noninteractive"

ENV MAKEFLAGS="-j4" \
    LD_LIBRARY_PATH="/usr/local/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu" \
    LIBVA_MESSAGING_LEVEL=0 \
    LIBVA_DRIVERS_PATH="/usr/local/lib/x86_64-linux-gnu/dri:/usr/lib/x86_64-linux-gnu/dri" \
    LIBVA_DISPLAY=drm \
    NVIDIA_DRIVER_CAPABILITIES="compute,video,utility" \
    NVIDIA_VISIBLE_DEVICES="all"

RUN apt-get -yqq update && \
    apt-get install -y gpg-agent wget && \
    wget -qO - https://repositories.intel.com/gpu/intel-graphics.key | \
    gpg --dearmor --output /usr/share/keyrings/intel-graphics.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/intel-graphics.gpg] https://repositories.intel.com/gpu/ubuntu noble unified" | \
    tee  /etc/apt/sources.list.d/intel.gpu.noble.list && \
    apt-get -yqq update && \
    apt-get install -yq --no-install-recommends \
    tzdata \
    fontconfig \
    fonts-noto-core \
    fonts-noto-cjk \
    libgdiplus \
    libicu-dev \
    level-zero libze1 \
    libmfx1 libmfxgen1 libvpl2 \
    libegl-mesa0 libegl1-mesa-dev libgbm1 libgl1-mesa-dev libgl1-mesa-dri \
    libglapi-mesa libgles2-mesa-dev libglx-mesa0 libigdgmm12 libxatracker2 mesa-va-drivers \
    mesa-vdpau-drivers mesa-vulkan-drivers va-driver-all vainfo hwinfo clinfo \
    i965-va-driver-shaders \
    ca-certificates \
    expat \
    libgomp1 \
    libllvm15 \
    libharfbuzz-bin \
    libv4l-0 \
    libwayland-client0 \
    libx11-6 \
    libx11-xcb1 \
    libxcb-dri2-0 \
    libxcb-dri3-0 \
    libxcb-present0 \
    libxcb-randr0 \
    libxcb-shape0 \
    libxcb-shm0 \
    libxcb-sync1 \
    libxcb-xfixes0 \
    libxcb1 \
    libxext6 \
    libxfixes3 \
    libxshmfence1 \
    libxml2 \
    ocl-icd-libopencl1 \
    wget && \
    mkdir -p /tmp/intel && cd /tmp/intel && \
    wget -q https://github.com/intel/intel-graphics-compiler/releases/download/igc-1.0.17537.20/intel-igc-core_1.0.17537.20_amd64.deb && \
    wget -q https://github.com/intel/intel-graphics-compiler/releases/download/igc-1.0.17537.20/intel-igc-opencl_1.0.17537.20_amd64.deb && \
    wget -q https://github.com/intel/compute-runtime/releases/download/24.35.30872.22/intel-level-zero-gpu-legacy1_1.3.30872.22_amd64.deb && \
    wget -q https://github.com/intel/compute-runtime/releases/download/24.35.30872.22/intel-opencl-icd-legacy1_24.35.30872.22_amd64.deb && \
    wget -q https://github.com/intel/compute-runtime/releases/download/24.35.30872.22/ww35.sum && \
    sha256sum --ignore-missing -c ww35.sum && \
    wget -q https://github.com/intel/intel-graphics-compiler/releases/download/v2.12.5/intel-igc-core-2_2.12.5+19302_amd64.deb && \
    wget -q https://github.com/intel/intel-graphics-compiler/releases/download/v2.12.5/intel-igc-opencl-2_2.12.5+19302_amd64.deb && \
    wget -q https://github.com/intel/compute-runtime/releases/download/25.22.33944.8/intel-ocloc_25.22.33944.8-0_amd64.deb && \
    wget -q https://github.com/intel/compute-runtime/releases/download/25.22.33944.8/intel-opencl-icd_25.22.33944.8-0_amd64.deb && \
    wget -q https://github.com/intel/compute-runtime/releases/download/25.22.33944.8/libze-intel-gpu1_25.22.33944.8-0_amd64.deb && \
    wget -q https://github.com/intel/compute-runtime/releases/download/25.22.33944.8/ww22.sum && \
    sha256sum --ignore-missing -c ww22.sum && \
    dpkg -i /tmp/intel/*.deb && \
    rm -rf /tmp/intel && \
    apt-get autoremove -y && \
    apt-get clean -y && \
    rm /usr/lib/x86_64-linux-gnu/dri/iHD_drv_video.so && \
    ln -s /usr/local/lib/x86_64-linux-gnu/dri/iHD_drv_video.so /usr/lib/x86_64-linux-gnu/dri/iHD_drv_video.so && \
    for d in radeonsi r600 nouveau virtio_gpu; do \
    rm -f /usr/lib/x86_64-linux-gnu/dri/${d}_drv_video.so && \
    ln -s /usr/local/lib/x86_64-linux-gnu/dri/${d}_drv_video.so /usr/lib/x86_64-linux-gnu/dri/${d}_drv_video.so; \
    done

ARG FFMPEG_VERSION
ARG FFMPEG_EXTRA_VERSION
RUN --mount=type=bind,source=scripts/verify-ffmpeg.sh,target=/tmp/verify-ffmpeg.sh \
    sh /tmp/verify-ffmpeg.sh /usr/local/bin "${FFMPEG_VERSION}" "${FFMPEG_EXTRA_VERSION}"

CMD         ["--help"]
ENTRYPOINT  ["ffmpeg"]
