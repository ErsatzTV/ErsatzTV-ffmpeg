# ErsatzTV FFmpeg

This repo contains docker images that are used by [ErsatzTV](https://github.com/jasongdove/ErsatzTV).

Uses [`ghcr.io/linuxserver/baseimage-ubuntu`](https://ghcr.io/linuxserver/baseimage-ubuntu) as base image.

Builds `ffmpeg` from scratch along with required libraries like `Intel Media Driver`, `VAAPI Drivers`, `NVIDIA Drivers`, etc. 

The published image [`jasongdove/ersatztv-ffmpeg`](https://hub.docker.com/r/jasongdove/ersatztv-ffmpeg) comes with all necessary drivers and libraries pre-installed to use hardware acceleration with `ffmpeg`.

## Multi-Platform Builds

This repository supports multi-platform builds for the following architectures:

- `linux/amd64`
- `linux/arm64`
- `linux/arm/v7`

## Hardware Accelerations Supported

The images built from this repository support various hardware accelerations, including:

| Platform/Drivers | Intel Media Driver | VAAPI Drivers      | NVIDIA Drivers     |
|-----------------:|:------------------:|:------------------:|:------------------:|
| linux/amd64      | :white_check_mark: | :white_check_mark: | :white_check_mark: |
| linux/arm64      | :x:                | :white_check_mark: | :white_check_mark: |
| linux/arm/v7     | :x:                | :x:                | :x:                |

## Usage
To use the `ffmpeg` image in your Dockerfile, you can specify it as follows:

```dockerfile
FROM jasongdove/ersatztv-ffmpeg:latest

# Your additional Dockerfile instructions here
```

## DISCLAIMER

Images are modified versions of those found at [jrottenberg/ffmpeg](https://github.com/jrottenberg/ffmpeg) and [linuxserver/docker-ffmpeg](https://github.com/linuxserver/docker-ffmpeg).